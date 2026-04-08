<#
.SYNOPSIS
    Domain-join the Azure Storage Account to the on-premises AD DS domain.
    Runs on the DC via 'az vm run-command invoke'.

.DESCRIPTION
    Creates a computer account in AD representing the storage account,
    sets up Kerberos keys and SPN, and configures the storage account
    for AD DS authentication. This removes the need for AADKERB/Entra admin.

    Requires: Az.Storage PowerShell module on the VM, Azure login context.

.PARAMETER StorageAccountName
    Name of the Azure storage account.

.PARAMETER ResourceGroupName
    Resource group containing the storage account.

.PARAMETER SubscriptionId
    Azure subscription ID.
#>
param(
    [Parameter(Mandatory)]
    [string]$StorageAccountName,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$SubscriptionId
)

$ErrorActionPreference = "Stop"

Write-Host "========================================"
Write-Host "  Domain-Join Storage Account to AD DS"
Write-Host "========================================"

# Verify we're on a DC
$dcCheck = Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty DomainRole
if ($dcCheck -lt 4) {
    throw "This VM is not a domain controller."
}

$domain = Get-ADDomain
$domainDns = $domain.DNSRoot
$domainNetbios = $domain.NetBIOSName
$domainSid = $domain.DomainSID.Value
$forestName = (Get-ADForest).Name
$domainGuid = $domain.ObjectGUID.ToString()

Write-Host "Domain     : $domainDns"
Write-Host "NetBIOS    : $domainNetbios"
Write-Host "Forest     : $forestName"
Write-Host "Domain SID : $domainSid"
Write-Host "Domain GUID: $domainGuid"

###############################################################################
# Step 1 - Install Az.Storage module if not present
###############################################################################
Write-Host "`n[1/5] Ensuring Az.Storage module..."
if (-not (Get-Module -ListAvailable -Name Az.Storage)) {
    Install-PackageProvider -Name NuGet -Force | Out-Null
    Install-Module -Name Az.Accounts -Force -AllowClobber -Scope AllUsers | Out-Null
    Install-Module -Name Az.Storage -Force -AllowClobber -Scope AllUsers | Out-Null
    Write-Host "  Az.Storage installed."
} else {
    Write-Host "  Already installed."
}

Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Storage -ErrorAction Stop

###############################################################################
# Step 2 - Login to Azure using VM managed identity
###############################################################################
Write-Host "`n[2/5] Connecting to Azure..."
Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
Select-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
Write-Host "  Connected."

###############################################################################
# Step 3 - Create Kerberos key and computer account in AD
###############################################################################
Write-Host "`n[3/5] Creating AD computer account for storage account..."

$samAccountName = $StorageAccountName
if ($samAccountName.Length -gt 15) {
    $samAccountName = $samAccountName.Substring(0, 15)
}

$spn = "cifs/${StorageAccountName}.file.core.windows.net"

# Check if computer account already exists
$existingAccount = Get-ADComputer -Filter "SamAccountName -eq '${samAccountName}$'" -ErrorAction SilentlyContinue
if ($existingAccount) {
    Write-Host "  Computer account '$samAccountName' already exists. SID: $($existingAccount.SID)"
    $storageSid = $existingAccount.SID.Value

    # Always regenerate and sync kerb1 key to ensure AD password matches Azure
    Write-Host "  Syncing Kerberos key..."
    New-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -KeyName kerb1 | Out-Null
    $kerbKey = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ListKerbKey | Where-Object { $_.KeyName -eq 'kerb1' }).Value
    $securePassword = ConvertTo-SecureString -String $kerbKey -AsPlainText -Force
    Set-ADAccountPassword -Identity "${samAccountName}$" -NewPassword $securePassword -Reset
    Write-Host "  Kerberos key synced."
} else {
    # Generate kerb1 key
    Write-Host "  Generating Kerberos key..."
    New-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -KeyName kerb1 | Out-Null
    $kerbKey = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ListKerbKey | Where-Object { $_.KeyName -eq 'kerb1' }).Value
    $securePassword = ConvertTo-SecureString -String $kerbKey -AsPlainText -Force

    # Create computer account
    Write-Host "  Creating computer account '$samAccountName'..."
    New-ADComputer -Name $samAccountName `
        -SAMAccountName "${samAccountName}$" `
        -ServicePrincipalNames $spn `
        -AccountPassword $securePassword `
        -KerberosEncryptionType AES256 `
        -PasswordNeverExpires $true `
        -Enabled $true `
        -ErrorAction Stop

    $newAccount = Get-ADComputer -Identity $samAccountName
    $storageSid = $newAccount.SID.Value
    Write-Host "  Created. SID: $storageSid"
}

# Ensure SPN is set
$currentSpns = (Get-ADComputer -Identity $samAccountName -Properties ServicePrincipalNames).ServicePrincipalNames
if ($spn -notin $currentSpns) {
    Set-ADComputer -Identity $samAccountName -ServicePrincipalNames @{Add=$spn}
    Write-Host "  SPN set: $spn"
}

###############################################################################
# Step 4 - Enable AD DS auth on the storage account
###############################################################################
Write-Host "`n[4/5] Enabling AD DS authentication on storage account..."

# Disable AADKERB first if it was previously enabled
$currentAuth = (Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName).AzureFilesIdentityBasedAuth
if ($currentAuth.DirectoryServiceOptions -eq 'AADKERB') {
    Write-Host "  Disabling AADKERB first..."
    Set-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName `
        -EnableAzureActiveDirectoryKerberosForFile $false | Out-Null
}

Set-AzStorageAccount `
    -ResourceGroupName $ResourceGroupName `
    -Name $StorageAccountName `
    -EnableActiveDirectoryDomainServicesForFile $true `
    -ActiveDirectoryDomainName $domainDns `
    -ActiveDirectoryNetBiosDomainName $domainNetbios `
    -ActiveDirectoryForestName $forestName `
    -ActiveDirectoryDomainGuid $domainGuid `
    -ActiveDirectoryDomainSid $domainSid `
    -ActiveDirectoryAzureStorageSid $storageSid `
    -ActiveDirectorySamAccountName $samAccountName `
    -ActiveDirectoryAccountType "Computer" `
    -ErrorAction Stop

Write-Host "  AD DS authentication enabled."

# Set default share-level permission for all authenticated AD identities
Write-Host "  Setting default share permission..."
Set-AzStorageAccount `
    -ResourceGroupName $ResourceGroupName `
    -Name $StorageAccountName `
    -DefaultSharePermission StorageFileDataSmbShareElevatedContributor `
    -ErrorAction Stop
Write-Host "  Default share permission set to StorageFileDataSmbShareElevatedContributor."

###############################################################################
# Step 5 - Verify
###############################################################################
Write-Host "`n[5/5] Verifying configuration..."
$sa = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
Write-Host "  DirectoryServiceOptions: $($sa.AzureFilesIdentityBasedAuth.DirectoryServiceOptions)"
Write-Host "  DomainName: $($sa.AzureFilesIdentityBasedAuth.ActiveDirectoryProperties.DomainName)"
Write-Host "  AzureStorageSid: $($sa.AzureFilesIdentityBasedAuth.ActiveDirectoryProperties.AzureStorageSid)"

Write-Host "`n========================================"
Write-Host "  Domain-join complete!"
Write-Host "  Storage account '$StorageAccountName' is now"
Write-Host "  joined to domain '$domainDns'"
Write-Host "========================================"
