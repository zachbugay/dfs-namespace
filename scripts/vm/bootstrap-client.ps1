<#
.SYNOPSIS
    Domain-join the client VM to the AD DS domain and install DFS diagnostic tools.
    Runs on the client VM via 'az vm run-command invoke'.

.DESCRIPTION
    1. Join the domain (VNet DNS must already point at the DC)
    2. Install RSAT DFS tools for demo diagnostics (dfsutil, Get-DfsnRoot, etc.)

.PARAMETER DomainName
    FQDN of the domain to join (default: dfslab.local).

.PARAMETER AdminUser
    Domain admin username (default: azureadmin).

.PARAMETER AdminPass
    Domain admin password.

.NOTES
    VNet DNS must be updated to point at the DC before running this script.
    The client VM must be restarted after the VNet DNS change so it
    picks up the new DNS server via DHCP.
    Requires reboot after domain join.
#>
param(
    [string]$DomainName = "dfslab.local",
    [string]$AdminUser  = "azureadmin",
    [string]$AdminPass  = ""
)

if ([string]::IsNullOrEmpty($AdminPass)) {
    throw "AdminPass is required."
}

$ErrorActionPreference = "Stop"

Write-Host "========================================"
Write-Host "  Client VM Setup"
Write-Host "========================================"
Write-Host "Server   : $env:COMPUTERNAME"
Write-Host "Domain   : $DomainName"
Write-Host "========================================"

###############################################################################
# Step 1 - Domain join
###############################################################################
Write-Host "`n[1/2] Joining domain '$DomainName'..."
$domainCheck = (Get-WmiObject -Class Win32_ComputerSystem).Domain
if ($domainCheck -eq $DomainName) {
    Write-Host "  Already joined to $DomainName."
} else {
    $secPass = ConvertTo-SecureString $AdminPass -AsPlainText -Force
    $cred = New-Object PSCredential("$DomainName\$AdminUser", $secPass)
    Add-Computer -DomainName $DomainName -Credential $cred -Force -ErrorAction Stop
    Write-Host "  Joined to $DomainName. Reboot required."
}

###############################################################################
# Step 2 - Install RSAT DFS tools for demo diagnostics
###############################################################################
Write-Host "`n[2/2] Installing RSAT DFS diagnostic tools..."
$osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
if ($osInfo.ProductType -eq 1) {
    # Workstation (Windows 11) — use Add-WindowsCapability
    $cap = Get-WindowsCapability -Online -Name 'Rsat.FileServices.Tools*' | Select-Object -First 1
    if ($cap -and $cap.State -ne 'Installed') {
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
        Write-Host "  Installed: $($cap.Name)"
    } elseif ($cap) {
        Write-Host "  Already installed: $($cap.Name)"
    } else {
        Write-Host "  RSAT File Services capability not found (may need Windows Update access)."
    }
} else {
    # Server — use Install-WindowsFeature
    $feat = Get-WindowsFeature -Name 'RSAT-DFS-Mgmt-Con' -ErrorAction SilentlyContinue
    if ($feat -and -not $feat.Installed) {
        Install-WindowsFeature -Name 'RSAT-DFS-Mgmt-Con' -IncludeManagementTools | Out-Null
        Write-Host "  Installed: RSAT-DFS-Mgmt-Con"
    } elseif ($feat) {
        Write-Host "  Already installed: RSAT-DFS-Mgmt-Con"
    }
}

Write-Host "`n========================================"
Write-Host "  Client VM Setup Complete!"
Write-Host "  Computer: $env:COMPUTERNAME"
Write-Host "  Domain:   $DomainName"
Write-Host "  Reboot if domain join was performed."
Write-Host "========================================"
