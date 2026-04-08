<#
.SYNOPSIS
    Adds a Kerberos realm mapping for the Azure Files storage endpoint.
    Runs on the client VM via az vm run-command.
#>
param(
    [Parameter(Mandatory)][string]$StorageAccountFqdn,
    [Parameter(Mandatory)][string]$RealmName
)

ksetup /addhosttorealmmap $StorageAccountFqdn $RealmName 2>$null
Write-Host "  Realm mapping: $StorageAccountFqdn -> $RealmName"
