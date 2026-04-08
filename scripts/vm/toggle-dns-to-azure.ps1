<#
.SYNOPSIS
    Replaces the file server DNS A record with a CNAME to the DFS-N server,
    adjusts SPNs, and syncs the storage account Kerberos key to AD.
    Runs on the DC VM via az vm run-command.
#>
param(
    [Parameter(Mandatory)][string]$DomainName,
    [Parameter(Mandatory)][string]$FileServerName,
    [Parameter(Mandatory)][string]$DfsnHostFqdn,
    [Parameter(Mandatory)][string]$StorageAccount,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [string]$DfsnAccount = "DFSN01"
)

$ErrorActionPreference = 'Stop'

Write-Host '--- DNS: Replace A record with CNAME ---'
$existing = Get-DnsServerResourceRecord -ZoneName $DomainName -Name $FileServerName -ErrorAction SilentlyContinue
if ($existing) {
    foreach ($rec in $existing) {
        Remove-DnsServerResourceRecord -ZoneName $DomainName -InputObject $rec -Force
        Write-Host "  Removed $($rec.RecordType) record for $FileServerName"
    }
}
Add-DnsServerResourceRecordCName -ZoneName $DomainName -Name $FileServerName -HostNameAlias $DfsnHostFqdn -TimeToLive 00:00:01
Write-Host "  CNAME created: $FileServerName.$DomainName -> $DfsnHostFqdn"

$check = Get-DnsServerResourceRecord -ZoneName $DomainName -Name $FileServerName -ErrorAction SilentlyContinue
$check | ForEach-Object { Write-Host "  Verified: $($_.RecordType) $($_.HostName)" }

Write-Host ''
Write-Host '--- AD: Disable dynamic DNS on FILESVR01 ---'
$fsAcct = Get-ADComputer -Filter "Name -eq '$FileServerName'" -ErrorAction SilentlyContinue
if ($fsAcct) {
    try { Set-ADComputer -Identity $fsAcct -Clear 'ms-DS-DnsHostName'; Write-Host '  Cleared ms-DS-DnsHostName' }
    catch { Write-Host "  ms-DS-DnsHostName already clear (non-fatal)" }
}

Write-Host ''
Write-Host '--- SPNs: Remove HOST from FILESVR01, add cifs to DFSN01 ---'
# Remove HOST/RestrictedKrbHost SPNs from FILESVR01 (HOST aliases cifs, causes error 1396)
@("HOST/$FileServerName", "HOST/$FileServerName.$DomainName", "RestrictedKrbHost/$FileServerName", "RestrictedKrbHost/$FileServerName.$DomainName") | ForEach-Object {
    $q = setspn -Q $_ 2>&1 | Out-String
    if ($q -match $FileServerName) {
        setspn -D $_ $FileServerName 2>&1 | Out-Null
        Write-Host "  Removed from ${FileServerName}: $_"
    }
}
# Add cifs/FILESVR01 SPNs to DFSN01
@("cifs/$FileServerName", "cifs/$FileServerName.$DomainName") | ForEach-Object {
    $q = setspn -Q $_ 2>&1 | Out-String
    if ($q -match $DfsnAccount) {
        Write-Host "  Already on ${DfsnAccount}: $_"
    } else {
        setspn -S $_ $DfsnAccount 2>&1 | Out-Null
        Write-Host "  Added to ${DfsnAccount}: $_"
    }
}

Write-Host ''
Write-Host '--- Kerb1 Key: Sync storage account Kerberos key to AD ---'
$sam = $StorageAccount
if ($sam.Length -gt 15) { $sam = $sam.Substring(0, 15) }

Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Storage -ErrorAction Stop
Connect-AzAccount -Identity -ErrorAction Stop | Out-Null

New-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccount -KeyName kerb1 | Out-Null
$kerbKey = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccount -ListKerbKey | Where-Object { $_.KeyName -eq 'kerb1' }).Value
$secPw = ConvertTo-SecureString -String $kerbKey -AsPlainText -Force
Set-ADAccountPassword -Identity "${sam}$" -NewPassword $secPw -Reset
Write-Host "  kerb1 key regenerated and synced to AD for $StorageAccount"
