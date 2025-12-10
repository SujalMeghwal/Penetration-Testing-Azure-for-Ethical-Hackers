# reader-scenario-ps1-fixed-for-powershell.ps1
# Run in Azure Cloud Shell (PowerShell). Tested for modern Az CLI + Az PowerShell modules.
# WARNING: This creates resources and users. Use a disposable/test subscription.

# ---- Helper / Safety ----
function Require-Owner {
    $role = az role assignment list --assignee $(az account show --query user.name -o tsv) --query "[].roleDefinitionName" -o tsv 2>$null
    if (-not ($role -match "Owner")) {
        Write-Host "Warning: You may not be Owner of the subscription. Ensure you have Owner or sufficient privileges." -ForegroundColor Yellow
    }
}

function Ensure-ProviderRegistered {
    param($namespace)
    Write-Host "Registering provider $namespace (if needed)..." -ForegroundColor Cyan
    az provider register --namespace $namespace | Out-Null
    for ($i=0; $i -lt 30; $i++) {
        $state = az provider show --namespace $namespace --query registrationState -o tsv
        Write-Host "Provider $namespace state: $state"
        if ($state -eq "Registered") { return }
        Start-Sleep -Seconds 5
    }
    throw "Provider $namespace did not register in time."
}

# ---- Start ----
$starttime = Get-Date
Write-Host "Deployment Started $starttime" -ForegroundColor Green

Require-Owner

# 1) Ask for a strong password (enforce complexity)
while ($true) {
    $password = Read-Host "Please enter a strong password (min 12 chars, upper, lower, digit, symbol)" -AsSecureString
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))
    if ($plain.Length -lt 12 -or $plain -notmatch '[A-Z]' -or $plain -notmatch '[a-z]' -or $plain -notmatch '\d' -or $plain -notmatch '[^A-Za-z0-9]') {
        Write-Host "Password too weak. Must be ≥12 chars, include upper+lower+digit+symbol." -ForegroundColor Yellow
        continue
    }
    break
}
$securepassword = ConvertTo-SecureString -String $plain -AsPlainText -Force

# 2) Build user principal name based on signed in user domain
$upnsuffix = az ad signed-in-user show --query userPrincipalName -o tsv 2>$null
if (-not $upnsuffix) {
    Write-Host "Could not query signed-in user. Make sure you are logged in with 'az login'." -ForegroundColor Red
    exit 1
}
# extract domain part
if ($upnsuffix -match '@(.+)$') { $domain = $Matches[1] } else { $domain = $upnsuffix }
$user = "readeruser@$domain"
$displayname = "readeruser"

Write-Host "###########################################################################"
Write-Host "# Creating new test user $user in Azure AD #"
Write-Host "###########################################################################"

try {
    # Use Az PowerShell if available, otherwise fallback to MSGraph via Az module
    if (Get-Command -Name New-AzADUser -ErrorAction SilentlyContinue) {
        New-AzADUser -DisplayName $displayname -UserPrincipalName $user -Password $securepassword -MailNickname $displayname -AccountEnabled $true
    } else {
        # fallback to az CLI
        $pwPlain = $plain
        $createUserJson = @{
            accountEnabled = $true
            displayName = $displayname
            mailNickname = $displayname
            userPrincipalName = $user
            passwordProfile = @{
                forceChangePasswordNextSignIn = $false
                password = $pwPlain
            }
        } | ConvertTo-Json -Depth 6
        az rest --method POST --uri "https://graph.microsoft.com/v1.0/users" --body $createUserJson | Out-Null
    }
}
catch {
    Write-Host "Error creating user: $($_.Exception.Message)" -ForegroundColor Red
    throw $_
}

# 3) Get subscription ID & ensure scope usage
$subid = az account show --query id -o tsv
if (-not $subid) { throw "No subscription found. Run 'az account show' to confirm." }

Write-Host "####################################################################"
Write-Host "# Assigning the Reader role to $user #"
Write-Host "####################################################################"

# Use explicit --scope parameter
try {
    az role assignment create --role Reader --assignee $user --scope "/subscriptions/$subid" | Out-Null
    Write-Host "Role assignment created." -ForegroundColor Green
} catch {
    Write-Host "Role assignment failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

# 4) Create resource group
$group = "pentest-rg"
$location = "uksouth"
az group create --name $group --location $location | Out-Null
Write-Host "Resource Group created: $group"

# 5) Create service principals using az CLI and parse JSON properly
$customappname = "customapp"
$containerappname = "containerapp"

Write-Host "Creating service principal $customappname ..."
$customappRaw = az ad sp create-for-rbac -n $customappname --role Contributor --scopes "/subscriptions/$subid" -o json 2>$null
if (-not $customappRaw) { Write-Host "Warning: custom app creation may have failed." -ForegroundColor Yellow }
$customapp = $customappRaw | ConvertFrom-Json

Write-Host "Creating service principal $containerappname ..."
$containerappRaw = az ad sp create-for-rbac -n $containerappname --role Contributor --scopes "/subscriptions/$subid" -o json
$containerapp = $containerappRaw | ConvertFrom-Json

$customappid = if ($customapp.appId) { $customapp.appId } else {
    # try to query appId by display name
    az ad app list --display-name $customappname --query "[0].appId" -o tsv
}
$containerappid = $containerapp.appId
$containerappsecret = $containerapp.password
$tenantid = $containerapp.tenant

Write-Host "custom app id: $customappid"
Write-Host "container app id: $containerappid"

# 6) Get created user object id (use az ad user show)
$userid = az ad user show --id $user --query id -o tsv
if (-not $userid) { Write-Host "Failed to resolve user object id. $user" -ForegroundColor Yellow }

# 7) Download Dockerfile (raw) into workspace
$dockerUrl = "https://raw.githubusercontent.com/PacktPublishing/Penetration-Testing-Azure-for-Ethical-Hackers/main/chapter-4/resources/Dockerfile"
Invoke-WebRequest -Uri $dockerUrl -OutFile "Dockerfile" -UseBasicParsing

# 8) Replace placeholders in Dockerfile using PowerShell string replace
# The original Dockerfile used literal placeholders like "$containerappid" "$containerappsecret" "$tenantid"
$dockerText = Get-Content -Raw -Path "Dockerfile"
$dockerText = $dockerText -replace '\$containerappid', $containerappid
$dockerText = $dockerText -replace '\$containerappsecret', $containerappsecret
$dockerText = $dockerText -replace '\$tenantid', $tenantid
Set-Content -Path "Dockerfile" -Value $dockerText
Write-Host "Dockerfile placeholders replaced."

# 9) Ensure ACR provider registered and create ACR
Ensure-ProviderRegistered -namespace "Microsoft.ContainerRegistry"
$random = Get-Random -Minimum 10000 -Maximum 99999
$acrname = "acr$random"

az acr create --resource-group $group --location $location --name $acrname --sku Standard -o json
Write-Host "ACR create requested: $acrname"

# wait for registry to be available (simple loop)
for ($i=0; $i -lt 20; $i++) {
    $exists = az acr show --name $acrname -g $group --query "name" -o tsv 2>$null
    if ($exists) { break }
    Start-Sleep -Seconds 6
}
if (-not $exists) { throw "ACR $acrname not found after creation." }

# 10) Build image in ACR (az acr build is server-side and should work from Cloud Shell)
az acr build --resource-group $group --registry $acrname --image nodeapp-web:v1 . | Out-Null
Write-Host "ACR build invoked."

# 11) Assign reader user as owner of the custom app registration (owner-object-id requires user object id)
if ($customappid -and $userid) {
    az ad app owner add --id $customappid --owner-object-id $userid | Out-Null
    Write-Host "Assigned $user as owner of app $customappid"
} else {
    Write-Host "Skipping app owner add (missing $customappid or $userid)" -ForegroundColor Yellow
}

# 12) Deploy ARM template (badtemplate.json) into RG (original template)
$templateUri = "https://raw.githubusercontent.com/PacktPublishing/Penetration-Testing-Azure-for-Ethical-Hackers/main/chapter-4/resources/badtemplate.json"
az deployment group create --name TemplateDeployment --resource-group $group --template-uri $templateUri -o json | Out-Null
Write-Host "ARM template deployment requested."

# 13) Assign VM identity contributor role (assumes LinuxVM exists in RG after template)
try {
    az vm identity assign -g $group -n LinuxVM --role Contributor --scope "/subscriptions/$subid" | Out-Null
    Write-Host "Assigned identity to VM (LinuxVM)."
} catch {
    Write-Host "Failed to assign identity to LinuxVM (it may not exist yet): $($_.Exception.Message)" -ForegroundColor Yellow
}

# 14) Transcript & output
Start-Transcript -Path reader-account-output.txt -Force
Write-Host "#################"
Write-Host "# Script Output #"
Write-Host "#################"
Write-Host "Azure Reader User:" $user
Write-Host "Azure Reader User Password (stored in memory): <hidden for safety>"
Write-Host "ACR Name: $acrname"
Stop-Transcript

$endtime = Get-Date
Write-Host "Deployment Ended $endtime" -ForegroundColor Green
