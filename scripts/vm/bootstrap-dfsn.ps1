<#
.SYNOPSIS
    Domain-join the DFS-N server VM and install the DFS Namespace role with
    root consolidation registry keys.
    Runs on the DFS-N VM via 'az vm run-command invoke'.

.DESCRIPTION
    1. Join the domain (VNet DNS must already point at the DC)
    2. Install FS-DFS-Namespace + RSAT tools
    3. Enable root consolidation registry keys (ServerConsolidationRetry)
    4. Install Az PowerShell modules + Azure CLI
    5. Configure Windows Firewall rules

.PARAMETER DomainName
    FQDN of the domain to join (default: dfslab.local).

.PARAMETER AdminUser
    Domain admin username (default: azureadmin).

.PARAMETER AdminPass
    Domain admin password.

.NOTES
    VNet DNS must be updated to point at the DC before running this script.
    The DFS-N VM must be restarted after the VNet DNS change so it picks up
    the new DNS server via DHCP. Requires reboot after domain join.
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
Write-Host "  DFS-N Server Setup"
Write-Host "========================================"
Write-Host "Server   : $env:COMPUTERNAME"
Write-Host "Domain   : $DomainName"
Write-Host "========================================"

###############################################################################
# Step 1 - Domain join
###############################################################################
Write-Host "`n[1/5] Joining domain '$DomainName'..."
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
# Step 2 - Install DFS-N role + RSAT tools
###############################################################################
Write-Host "`n[2/5] Installing DFS-N role and RSAT tools..."
$features = @(
    "FS-DFS-Namespace",
    "RSAT-DFS-Mgmt-Con",
    "RSAT-AD-Tools",
    "RSAT-DNS-Server"
)
foreach ($feat in $features) {
    $f = Get-WindowsFeature -Name $feat
    if ($f.Installed) {
        Write-Host "  $feat - already installed."
    } else {
        Install-WindowsFeature -Name $feat -IncludeManagementTools -ErrorAction SilentlyContinue | Out-Null
        Write-Host "  $feat - installed."
    }
}

###############################################################################
# Step 3 - Enable root consolidation registry keys
###############################################################################
Write-Host "`n[3/5] Enabling DFS root consolidation registry keys..."
# Per https://learn.microsoft.com/azure/storage/files/files-manage-namespaces
New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Dfs" -Type Registry -ErrorAction SilentlyContinue | Out-Null
New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Dfs\Parameters" -Type Registry -ErrorAction SilentlyContinue | Out-Null
New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Dfs\Parameters\Replicated" -Type Registry -ErrorAction SilentlyContinue | Out-Null
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Dfs\Parameters\Replicated" -Name "ServerConsolidationRetry" -Value 1
Write-Host "  ServerConsolidationRetry = 1"

###############################################################################
# Step 4 - Install Az PowerShell modules + Azure CLI
###############################################################################
Write-Host "`n[4/5] Installing Az PowerShell modules..."
if (-not (Get-Module -ListAvailable -Name Az.Storage)) {
    Install-PackageProvider -Name NuGet -Force | Out-Null
    Install-Module -Name Az.Accounts -Force -AllowClobber -Scope AllUsers | Out-Null
    Install-Module -Name Az.Storage -Force -AllowClobber -Scope AllUsers | Out-Null
    Write-Host "  Az.Accounts + Az.Storage installed."
} else {
    Write-Host "  Az.Storage already installed."
}

Write-Host "  Installing Azure CLI..."
$azCmd = Get-Command az -ErrorAction SilentlyContinue
if ($azCmd) {
    Write-Host "  Azure CLI already installed: $($azCmd.Source)"
} else {
    $ProgressPreference = 'SilentlyContinue'
    $msiPath = "$env:TEMP\AzureCLI.msi"
    Invoke-WebRequest -Uri https://aka.ms/installazurecliwindowsx64 -OutFile $msiPath -UseBasicParsing
    Start-Process msiexec.exe -Wait -ArgumentList '/I', $msiPath, '/quiet'
    Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
    $env:PATH = "$env:ProgramFiles\Microsoft SDKs\Azure\CLI2\wbin;$env:PATH"
    Write-Host "  Azure CLI installed."
}

# Login with system-assigned managed identity
Write-Host "  Logging in with managed identity..."
$loginResult = & "$env:ProgramFiles\Microsoft SDKs\Azure\CLI2\wbin\az.cmd" login --identity 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Authenticated via managed identity."
} else {
    Write-Host "  Managed identity login failed (will retry after reboot): $loginResult"
}

###############################################################################
# Step 5 - Enable Windows Firewall rules for SMB, NetBIOS, DFS, RPC
###############################################################################
Write-Host "`n[5/5] Enabling firewall rules..."
netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes | Out-Null
Write-Host "  File and Printer Sharing firewall rules enabled."

$fwRules = @(
    @{ Name='Allow-RPC-EPM';     Port='135';     Protocol='TCP'; Desc='RPC Endpoint Mapper' },
    @{ Name='Allow-NetBIOS-NS';  Port='137';     Protocol='UDP'; Desc='NetBIOS Name Service' },
    @{ Name='Allow-NetBIOS-DGM'; Port='138';     Protocol='UDP'; Desc='NetBIOS Datagram' },
    @{ Name='Allow-NetBIOS-SSN'; Port='139';     Protocol='TCP'; Desc='NetBIOS Session' },
    @{ Name='Allow-SMB';         Port='445';     Protocol='TCP'; Desc='SMB' },
    @{ Name='Allow-DNS-TCP';     Port='53';      Protocol='TCP'; Desc='DNS TCP' },
    @{ Name='Allow-DNS-UDP';     Port='53';      Protocol='UDP'; Desc='DNS UDP' },
    @{ Name='Allow-Kerberos-TCP';Port='88';      Protocol='TCP'; Desc='Kerberos TCP' },
    @{ Name='Allow-Kerberos-UDP';Port='88';      Protocol='UDP'; Desc='Kerberos UDP' }
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
Write-Host "  DFS-N Server Setup Complete!"
Write-Host "  Computer: $env:COMPUTERNAME"
Write-Host "  Domain:   $DomainName"
Write-Host "  Root consolidation registry keys: enabled"
Write-Host "  Reboot if domain join was performed."
Write-Host "========================================"
