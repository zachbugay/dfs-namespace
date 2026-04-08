<#
.SYNOPSIS
    Domain-join the file server VM to the AD DS domain and create a local file share.
    Runs on the file server VM via 'az vm run-command invoke'.

.DESCRIPTION
    1. Join the domain (VNet DNS must already point at the DC)
    2. Create a local SMB share
    3. Enable SMB firewall rules

.PARAMETER DomainName
    FQDN of the domain to join (default: dfslab.local).

.PARAMETER AdminUser
    Domain admin username (default: azureadmin).

.PARAMETER AdminPass
    Domain admin password.

.PARAMETER FileShareName
    Name of the SMB share to create (default: share).

.NOTES
    VNet DNS must be updated to point at the DC before running this script.
    The file server VM must be restarted after the VNet DNS change so it
    picks up the new DNS server via DHCP.
    Requires reboot after domain join.
#>
param(
    [string]$DomainName    = "dfslab.local",
    [string]$AdminUser     = "azureadmin",
    [string]$AdminPass     = "",
    [string]$FileShareName = "share"
)

if ([string]::IsNullOrEmpty($AdminPass)) {
    throw "AdminPass is required."
}

$ErrorActionPreference = "Stop"

Write-Host "========================================"
Write-Host "  File Server Setup"
Write-Host "========================================"
Write-Host "Server   : $env:COMPUTERNAME"
Write-Host "Domain   : $DomainName"
Write-Host "========================================"

###############################################################################
# Step 1 - Domain join
###############################################################################
Write-Host "`n[1/3] Joining domain '$DomainName'..."
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
# Step 2 - Create local SMB share
###############################################################################
Write-Host "`n[2/3] Creating local SMB share '$FileShareName'..."
$sharePath = "C:\Shares\${FileShareName}"

if (-not (Test-Path $sharePath)) {
    New-Item -Path $sharePath -ItemType Directory -Force | Out-Null
    Write-Host "  Created folder '$sharePath'."
}

if (-not (Get-SmbShare -Name $FileShareName -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name $FileShareName -Path $sharePath -FullAccess "Everyone" | Out-Null
    Write-Host "  SMB share created."
} else {
    Write-Host "  SMB share already exists."
}

# Relax SMB security for non-domain-joined clients (lab only)
Set-SmbServerConfiguration -RejectUnencryptedAccess $false -Force
Set-SmbServerConfiguration -RequireSecuritySignature $false -Force

# Create a marker file
$markerFile = Join-Path $sharePath "README-fileserver.txt"
if (-not (Test-Path $markerFile)) {
    "This file is hosted on the Azure VM file server ($env:COMPUTERNAME)." | Out-File $markerFile
    "If you see this, you are accessing the VM-hosted file share directly." | Out-File $markerFile -Append
}

###############################################################################
# Step 3 - Enable Windows Firewall rules for SMB and NetBIOS (all profiles)
###############################################################################
Write-Host "`n[3/3] Enabling firewall rules..."
# Enable File and Printer Sharing for all profiles (SMB 445, NetBIOS 137-139)
netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes | Out-Null
Write-Host "  File and Printer Sharing firewall rules enabled."

# Ensure RPC Endpoint Mapper and NetBIOS are explicitly open
$fwRules = @(
    @{ Name='Allow-RPC-EPM';     Port='135'; Protocol='TCP'; Desc='RPC Endpoint Mapper' },
    @{ Name='Allow-NetBIOS-NS';  Port='137'; Protocol='UDP'; Desc='NetBIOS Name Service' },
    @{ Name='Allow-NetBIOS-DGM'; Port='138'; Protocol='UDP'; Desc='NetBIOS Datagram' },
    @{ Name='Allow-NetBIOS-SSN'; Port='139'; Protocol='TCP'; Desc='NetBIOS Session' },
    @{ Name='Allow-SMB';         Port='445'; Protocol='TCP'; Desc='SMB' }
)
foreach ($r in $fwRules) {
    $existing = Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Action Allow `
            -Protocol $r.Protocol -LocalPort $r.Port -Profile Any `
            -Description $r.Desc | Out-Null
        Write-Host "  Created: $($r.Name) ($($r.Protocol)/$($r.Port))"
    } else {
        Write-Host "  Exists:  $($r.Name)"
    }
}
Write-Host "  Firewall rules configured."

Write-Host "`n========================================"
Write-Host "  File Server Setup Complete!"
Write-Host "  Share: \\$env:COMPUTERNAME\$FileShareName"
Write-Host "  Path:  $sharePath"
Write-Host "  Reboot if domain join was performed."
Write-Host "========================================"
