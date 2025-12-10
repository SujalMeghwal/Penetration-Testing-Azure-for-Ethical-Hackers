# ===============================
# FIXED PowerShell Azure Lab Script
# Compatible with Cloud Shell PowerShell (2025)
# ===============================

Write-Host "Starting Deployment..." -ForegroundColor Green
$starttime = Get-Date

# -------------------------------
# Helper: Register Providers
# -------------------------------
function Register-Provider {
    param($namespace)
    Write-Host "Checking provider: $namespace" -ForegroundColor Cyan
    $state = az provider show --namespace $namespace --query registrationState -o tsv 2>$null

    if ($state -ne "Registered") {
        Write-Host "Registering provider $namespace..." -ForegroundColor Yellow
        az provider register --namespace $namespace | Out-Null
        Start-Sleep -Seconds 5
    }

    for ($i=0; $i -lt 20; $i++) {
        $state = az provider show --namespace $namespace --query registrationState -o tsv
        if ($state -eq "Registered") {
            Write-Host "$namespace registered." -ForegroundColor Green
            return
        }
        Start-Sleep -Seconds 5
    }

    throw "Provider $namespace could not be registered."
}

# -------------------------------
# Ask for password (secure + compliant)
# -------------------------------
while ($true) {
    $pw = Read-Host "Enter a strong password for the reader user (min 12 chars, upper, lower, digit, symbol)"
    if (
        ($pw.Length -ge 12) -and
        ($pw -match "[A-Z]") -and
        ($pw -match "[a-z]") -and
        ($pw -match "\d")   -and
        ($pw -match "[^A-Za-z0-9]")
    ) {
        break
    }
    Write-Host "Password does not meet complexity requirements!" -ForegroundColor Red
}

# -------------------------------
# Determine user suffix
# -------------------------------
$upn = az ad signed-in-user show --query userPrincipalName -o tsv
$domain = $upn.Split("@")[1]
$user = "readeruser@$domain"

Write-Host "Creating Azure AD User: $user"

# -------------------------------
# CREATE USER using Microsoft Graph (New-AzADUser fails in Cloud Shell often)
# -------------------------------
$userJson = @{
    accountEnabled = $true
    displayName    = "readeruser"
    mailNickname   = "readeruser"
    userPrincipalName = $user
    passwordProfile = @{
        forceChangePasswordNextSignIn = $false
        password = $pw
    }
} | ConvertTo-Json -Depth 5

az rest `
  --method POST `
  --uri "https://graph.microsoft.com/v1.0/users" `
  --headers "Content-Type=application/json" `
  --body $userJson | Out-Null

Write-Host "User created." -ForegroundColor Green

# -------------------------------
# Subscription & Role Assignment
# -------------------------------
$subid = az account show --query id -o tsv

Write-Host "Assigning Reader role to $user"
az role assignment create `
    --role Reader `
    --assignee $user `
    --scope "/subscriptions/$subid" | Out-Null

# -------------------------------
# Create Resource Group
# -------------------------------
$group = "pentest-rg"
$location = "uksouth"

az group create --name $group --location $location | Out-Null
Write-Host "Created resource group: $group" -ForegroundColor Green

# -------------------------------
# Create Service Principals
# -------------------------------
Write-Host "Creating service principals..." -ForegroundColor Yellow

$customapp = az ad sp create-for-rbac -n "customapp" --role Contributor --scopes "/subscriptions/$subid" -o json | ConvertFrom-Json
$containerapp = az ad sp create-for-rbac -n "containerapp" --role Contributor --scopes "/subscriptions/$subid" -o json | ConvertFrom-Json

$customappid = $customapp.appId
$containerappid = $containerapp.appId
$containerappsecret = $containerapp.password
$tenantid = $containerapp.tenant

Write-Host "Service Principals created." -ForegroundColor Green

# -------------------------------
# Download Dockerfile
# -------------------------------
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/PacktPublishing/Penetration-Testing-Azure-for-Ethical-Hackers/main/chapter-4/resources/Dockerfile" -OutFile "Dockerfile"

# -------------------------------
# Replace variables in Dockerfile
# -------------------------------
$df = Get-Content Dockerfile -Raw
$df = $df.Replace('$containerappid', $containerappid)
$df = $df.Replace('$containerappsecret', $containerappsecret)
$df = $df.Replace('$tenantid', $tenantid)
Set-Content Dockerfile $df

Write-Host "Dockerfile updated." -ForegroundColor Green

# -------------------------------
# Register ACR provider & create ACR
# -------------------------------
Register-Provider "Microsoft.ContainerRegistry"

$acrname = "acr$((Get-Random -Minimum 10000 -Maximum 99999))"

Write-Host "Creating ACR: $acrname"
az acr create --resource-group $group --name $acrname --location $location --sku Standard -o none

# -------------------------------
# Build image in ACR
# -------------------------------
Write-Host "Building container image..."
az acr build --resource-group $group --registry $acrname --image nodeapp-web:v1 . | Out-Null

# -------------------------------
# Assign owner to custom app
# -------------------------------
$userid = az ad user show --id $user --query id -o tsv

if ($customappid -and $userid) {
    az ad app owner add --id $customappid --owner-object-id $userid
    Write-Host "Assigned owner for custom app." -ForegroundColor Green
}

# -------------------------------
# Deploy ARM template
# -------------------------------
Write-Host "Deploying ARM template..."
az deployment group create `
  --name LabDeployment `
  --resource-group $group `
  --template-uri "https://raw.githubusercontent.com/PacktPublishing/Penetration-Testing-Azure-for-Ethical-Hackers/main/chapter-4/resources/badtemplate.json" | Out-Null

# -------------------------------
# Assign VM Identity
# -------------------------------
Write-Host "Assigning VM identity (Contributor)..."
az vm identity assign `
    -g $group `
    -n LinuxVM `
    --role Contributor `
    --scope "/subscriptions/$subid" 2>$null

# -------------------------------
# END / OUTPUT
# -------------------------------
Write-Host "============================="
Write-Host " USER CREATED:"
Write-Host "   $user"
Write-Host " PASSWORD:"
Write-Host "   $pw" -ForegroundColor Yellow
Write-Host " ACR NAME:"
Write-Host "   $acrname"
Write-Host "============================="

$endtime = Get-Date
Write-Host "Deployment Completed at $endtime" -ForegroundColor Green
