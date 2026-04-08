<#
.SYNOPSIS
    Delete all resources created by deploy.ps1.
    Reminds you to clean up client-side hosts file and credential entries.
#>
[CmdletBinding()]
param(
    [string]$RG = "rg-dfs-azurefiles-demo"
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "[WARN]  This will DELETE resource group '$RG' and ALL resources inside it." -ForegroundColor Yellow
Write-Host "        This includes the domain controller, storage account, and all data." -ForegroundColor Yellow
$confirm = Read-Host "Are you sure? (y/N)"
if ($confirm -ne 'y') {
    Write-Host "[INFO]  Aborted." -ForegroundColor Cyan
    exit 0
}

Write-Host "[INFO]  Deleting resource group '$RG'..." -ForegroundColor Cyan
az group delete --name $RG --yes --no-wait
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to delete resource group." -ForegroundColor Red
    exit 1
}
Write-Host "[INFO]  Deletion initiated (--no-wait). Monitor in the Azure portal." -ForegroundColor Cyan
Write-Host ""
Write-Host "[INFO]  Client cleanup:" -ForegroundColor Yellow
Write-Host "  1. Disconnect the P2S VPN connection."
Write-Host ""
Write-Host "  2. Remove DNS suffix (requires elevated PowerShell):"
Write-Host "     `$s = @((Get-DnsClientGlobalSetting).SuffixSearchList) | Where-Object { `$_ -ne 'dfslab.local' }"
Write-Host "     Set-DnsClientGlobalSetting -SuffixSearchList `$s"
Write-Host ""
Write-Host "  3. Remove stored credentials:"
Write-Host "     cmdkey /delete:FILESVR01"
Write-Host "     cmdkey /delete:DFSN01"
Write-Host ""
Write-Host "  4. Optional: Remove VPN certificates from Cert:\CurrentUser\My"
Write-Host "     Get-ChildItem Cert:\CurrentUser\My | Where-Object { `$_.Subject -like '*DFSLab*' } | Remove-Item"
Write-Host ""
Write-Host "[INFO]  Done." -ForegroundColor Cyan
