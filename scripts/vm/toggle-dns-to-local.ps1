<#
.SYNOPSIS
    Restores the file server DNS A record and SPNs to their original state.
    Runs on the DC VM via az vm run-command.
#>
param(
    [Parameter(Mandatory)][string]$DomainName,
    [Parameter(Mandatory)][string]$FileServerName,
    [Parameter(Mandatory)][string]$FileServerIp,
    [string]$DfsnAccount = "DFSN01"
)

$ErrorActionPreference = 'Stop'

Write-Host '--- DNS: Restore A record ---'
$existing = Get-DnsServerResourceRecord -ZoneName $DomainName -Name $FileServerName -ErrorAction SilentlyContinue
if ($existing) {
    foreach ($rec in $existing) {
        Remove-DnsServerResourceRecord -ZoneName $DomainName -InputObject $rec -Force
        Write-Host "  Removed $($rec.RecordType) record for $FileServerName"
    }
}
Add-DnsServerResourceRecordA -ZoneName $DomainName -Name $FileServerName -IPv4Address $FileServerIp -TimeToLive 00:00:01
Write-Host "  A record created: $FileServerName.$DomainName -> $FileServerIp"

$check = Get-DnsServerResourceRecord -ZoneName $DomainName -Name $FileServerName -ErrorAction SilentlyContinue
$check | ForEach-Object { Write-Host "  Verified: $($_.RecordType) $($_.HostName)" }

Write-Host ''
Write-Host '--- SPNs: Remove cifs from DFSN01, restore HOST on FILESVR01 ---'
# Remove cifs/FILESVR01 SPNs from DFSN01
@("cifs/$FileServerName", "cifs/$FileServerName.$DomainName") | ForEach-Object {
    $q = setspn -Q $_ 2>&1 | Out-String
    if ($q -match $DfsnAccount) {
        setspn -D $_ $DfsnAccount 2>&1 | Out-Null
        Write-Host "  Removed from ${DfsnAccount}: $_"
    }
}
# Restore HOST/RestrictedKrbHost SPNs on FILESVR01
@("HOST/$FileServerName", "HOST/$FileServerName.$DomainName", "RestrictedKrbHost/$FileServerName", "RestrictedKrbHost/$FileServerName.$DomainName") | ForEach-Object {
    $q = setspn -Q $_ 2>&1 | Out-String
    if ($q -notmatch 'Existing SPN found') {
        setspn -S $_ $FileServerName 2>&1 | Out-Null
        Write-Host "  Restored on ${FileServerName}: $_"
    } else {
        Write-Host "  Already on ${FileServerName}: $_"
    }
}
