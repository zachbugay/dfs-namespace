<#
.SYNOPSIS
    Phase 1: Install Active Directory Domain Services and promote to domain controller.
    Creates a new AD forest with integrated DNS.

.DESCRIPTION
    This runs on the VM via 'az vm run-command invoke' during deploy.ps1 Phase 1.
    After this script completes, the VM MUST be rebooted and allowed to finish
    DC promotion before running subsequent steps.

    Creates domain: dfslab.local (configurable via -DomainName)

.PARAMETER DomainName
    FQDN for the new AD forest (default: dfslab.local).

.PARAMETER DomainNetbios
    NetBIOS name for the domain (default: DFSLAB).

.PARAMETER SafeModePass
    Directory Services Restore Mode password.

.NOTES
    Idempotent - safe to re-run. Requires reboot after first run.
#>
param(
    [string]$DomainName    = "dfslab.local",
    [string]$DomainNetbios = "DFSLAB",
    [string]$SafeModePass  = ""
)

if ([string]::IsNullOrEmpty($SafeModePass)) {
    throw "SafeModePass is required (Directory Services Restore Mode password)."
}

$ErrorActionPreference = "Stop"

Write-Host "========================================"
Write-Host "  Phase 1: AD DS + DNS Installation"
Write-Host "========================================"
Write-Host "Domain:  $DomainName ($DomainNetbios)"
Write-Host "Server:  $env:COMPUTERNAME"
Write-Host "========================================"


###############################################################################
# Step 1 - Install AD DS, DNS, and DFS-N roles
###############################################################################
Write-Host "`n[1/6] Installing Windows features..."
# $features = @("AD-Domain-Services", "DNS", "FS-DFS-Namespace", "RSAT-AD-Tools", "RSAT-DNS-Server", "RSAT-DFS-Mgmt-Con")
$features = @("AD-Domain-Services", "DNS", "RSAT-AD-Tools", "RSAT-DNS-Server")
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
# Step 2 - Check if already a domain controller
###############################################################################
Write-Host "`n[2/6] Checking domain controller status..."
$dcCheck = Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty DomainRole
# DomainRole: 0=Standalone Workstation, 1=Member Workstation, 2=Standalone Server,
#             3=Member Server, 4=Backup DC, 5=Primary DC
if ($dcCheck -ge 4) {
    Write-Host "  Already a domain controller. Skipping promotion."
    Write-Host "  Domain: $((Get-ADDomain).DNSRoot)"
} else {
    ###############################################################################
    # Step 3 - Promote to domain controller (new forest)
    ###############################################################################
    Write-Host "`n[3/6] Promoting to domain controller (new forest: $DomainName)..."
    Write-Host "  This will trigger an automatic reboot."

    $secPass = ConvertTo-SecureString $SafeModePass -AsPlainText -Force

    Install-ADDSForest `
        -DomainName $DomainName `
        -DomainNetbiosName $DomainNetbios `
        -SafeModeAdministratorPassword $secPass `
        -InstallDns:$true `
        -CreateDnsDelegation:$false `
        -DatabasePath "C:\Windows\NTDS" `
        -LogPath "C:\Windows\NTDS" `
        -SysvolPath "C:\Windows\SYSVOL" `
        -NoRebootOnCompletion:$true `
        -Force:$true | Out-Null

    Write-Host "  DC promotion complete. VM must be rebooted."
}

###############################################################################
# Step 4 - Configure DNS forwarder to Azure DNS (168.63.129.16)
###############################################################################
# This allows the DC to resolve Azure Private DNS zones (e.g. privatelink.file.core.windows.net)
# and external names. Must be set after DNS role is installed.
Write-Host "`n[4/6] Configuring DNS forwarder to Azure DNS (168.63.129.16)..."
try {
    $existing = Get-DnsServerForwarder -ErrorAction SilentlyContinue
    if ($existing -and $existing.IPAddress -contains '168.63.129.16') {
        Write-Host "  Forwarder already configured."
    } else {
        # Use Add (not Set) to avoid removing existing forwarders
        Add-DnsServerForwarder -IPAddress 168.63.129.16 -ErrorAction SilentlyContinue
        Write-Host "  Forwarder 168.63.129.16 added."
    }
} catch {
    Write-Host "  DNS not yet ready for forwarder config (will be set after reboot)."
}

###############################################################################
# Step 5 - Conditional forwarder for Azure Files PE resolution
###############################################################################
Write-Host "`n[5/6] Configuring conditional forwarder for file.core.windows.net..."
try {
    $cfZone = Get-DnsServerZone -Name 'file.core.windows.net' -ErrorAction SilentlyContinue
    if ($cfZone) {
        Write-Host "  Already exists."
    } else {
        Add-DnsServerConditionalForwarderZone -Name 'file.core.windows.net' -MasterServers 168.63.129.16
        Write-Host "  Added: file.core.windows.net -> 168.63.129.16"
    }
} catch {
    Write-Host "  DNS not yet ready for conditional forwarder (will be set after reboot)."
}

###############################################################################
# Step 6 - Install Azure CLI and authenticate with managed identity
###############################################################################
Write-Host "`n[6/7] Installing Azure CLI..."
$azCmd = Get-Command az -ErrorAction SilentlyContinue
if ($azCmd) {
    Write-Host "  Azure CLI already installed: $($azCmd.Source)"
} else {
    $ProgressPreference = 'SilentlyContinue'
    $msiPath = "$env:TEMP\AzureCLI.msi"
    Invoke-WebRequest -Uri https://aka.ms/installazurecliwindowsx64 -OutFile $msiPath -UseBasicParsing
    Start-Process msiexec.exe -Wait -ArgumentList '/I', $msiPath, '/quiet'
    Remove-Item $msiPath -Force -ErrorAction SilentlyContinue

    # Add az to PATH for this session
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
# Step 7 - Open Windows Firewall for AD, DNS, DFS, SMB, NetBIOS, RPC
###############################################################################
Write-Host "`n[7/7] Configuring Windows Firewall rules..."
# Enable File and Printer Sharing (covers SMB 445, NetBIOS 137-139)
netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes | Out-Null
Write-Host "  File and Printer Sharing enabled."

# Ensure specific ports are open for all profiles
$fwRules = @(
    @{ Name='Allow-DNS-TCP';     Port='53';      Protocol='TCP'; Desc='DNS TCP' },
    @{ Name='Allow-DNS-UDP';     Port='53';      Protocol='UDP'; Desc='DNS UDP' },
    @{ Name='Allow-Kerberos-TCP';Port='88';      Protocol='TCP'; Desc='Kerberos TCP' },
    @{ Name='Allow-Kerberos-UDP';Port='88';      Protocol='UDP'; Desc='Kerberos UDP' },
    @{ Name='Allow-RPC-EPM';     Port='135';     Protocol='TCP'; Desc='RPC Endpoint Mapper' },
    @{ Name='Allow-NetBIOS-NS';  Port='137';     Protocol='UDP'; Desc='NetBIOS Name Service' },
    @{ Name='Allow-NetBIOS-DGM'; Port='138';     Protocol='UDP'; Desc='NetBIOS Datagram' },
    @{ Name='Allow-NetBIOS-SSN'; Port='139';     Protocol='TCP'; Desc='NetBIOS Session' },
    @{ Name='Allow-SMB';         Port='445';     Protocol='TCP'; Desc='SMB' },
    @{ Name='Allow-LDAP-TCP';    Port='389';     Protocol='TCP'; Desc='LDAP' },
    @{ Name='Allow-LDAP-UDP';    Port='389';     Protocol='UDP'; Desc='LDAP UDP' },
    @{ Name='Allow-LDAPS';       Port='636';     Protocol='TCP'; Desc='LDAP over SSL' },
    @{ Name='Allow-GC';          Port='3268';    Protocol='TCP'; Desc='Global Catalog' }
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
Write-Host "  Phase 1 Complete"
Write-Host "========================================"
Write-Host "  Reboot the VM, wait ~3-5 min for AD DS to initialize,"
Write-Host "  then proceed with remaining deploy.ps1 steps."
Write-Host "========================================"
