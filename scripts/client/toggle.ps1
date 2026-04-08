<#
.SYNOPSIS
    Client-side script to toggle DFS-N root consolidation between direct file
    server access and Azure Files.
    Runs from your workstation. Orchestrates changes across the DC and DFSN VMs.

.DESCRIPTION
    This script runs two separate az vm run-command invocations:
      1. DNS changes on the DC VM (vm-dns-01) - only the DC can reliably
         modify its own DNS records.
      2. DFS-N + registry + SPN + Kerberos changes on the DFSN VM (vm-dfsn-01).

    IMPORTANT: When testing on VMs (DFSN01, CLIENT01), you MUST be logged in as
    the DOMAIN account (DFSLAB\azureadmin), NOT the local account (DFSN01\azureadmin
    or CLIENT01\azureadmin). Kerberos authentication requires a domain logon session.

    After toggling to 'azure', on the client or DFSN VM:
      1. Log off if logged in as a local account.
      2. RDP back in as DFSLAB\azureadmin.
      3. Run: dir \\FILESVR01\share (should show Azure Files content).

.EXAMPLE
    # Set up DFS-N root consolidation pointing to Azure Files
    .\toggle.ps1 -Target azure

    # Tear down DFS-N, restore direct file server access
    .\toggle.ps1 -Target local

.PARAMETER Target
    'azure' to set up DFS-N root consolidation pointing to Azure Files.
    'local'  to tear down DFS-N and restore direct file server access.
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet('azure', 'local')]
    [string]$Target,

    [string]$RG              = "rg-dfs-azurefiles-demo",
    [string]$DfsnVmName      = "vm-dfsn-01",
    [string]$DcVmName        = "vm-dns-01",
    [string]$ClientVmName    = "vm-client-01",
    [string]$StorageAccount  = "",
    [string]$FileShareName   = "share",
    [string]$FileServerName  = "FILESVR01",
    [string]$FileServerIp    = "10.0.1.5",
    [string]$DomainName      = "dfslab.local"
)

$ErrorActionPreference = "Stop"

###############################################################################
# Helpers
###############################################################################
function Invoke-VMRunCommand {
    param(
        [string]$VmName,
        [string]$ScriptPath,
        [hashtable]$Parameters = @{},
        [string]$Label
    )

    if (-not (Test-Path $ScriptPath)) {
        Write-Host "[ERROR] Script not found: $ScriptPath" -ForegroundColor Red
        return $false
    }

    $azArgs = @(
        "vm", "run-command", "invoke",
        "-g", $RG, "-n", $VmName,
        "--command-id", "RunPowerShellScript",
        "--scripts", "@$ScriptPath",
        "-o", "json"
    )

    if ($Parameters.Count -gt 0) {
        $azArgs += "--parameters"
        foreach ($key in $Parameters.Keys) {
            $azArgs += "$key=$($Parameters[$key])"
        }
    }

    $result = & az @azArgs 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] run-command on $VmName failed." -ForegroundColor Red
        Write-Host $result
        return $false
    }

    $parsed = $result | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($parsed -and $parsed.value) {
        foreach ($msg in $parsed.value) {
            if ($msg.code -match 'StdOut' -and $msg.message) {
                Write-Host $msg.message
            } elseif ($msg.code -match 'StdErr' -and $msg.message) {
                Write-Host "[WARN] $($msg.message)" -ForegroundColor Yellow
            }
        }
    }
    return $true
}

# Auto-detect storage account if not provided
if ([string]::IsNullOrEmpty($StorageAccount)) {
    $StorageAccount = az storage account list -g $RG --query "[0].name" -o tsv 2>$null
    if ([string]::IsNullOrEmpty($StorageAccount)) {
        Write-Host "[ERROR] Could not find storage account in resource group '$RG'." -ForegroundColor Red
        exit 1
    }
    Write-Host "[INFO]  Using storage account: $StorageAccount" -ForegroundColor Cyan
}

$dfsnHostFqdn = "DFSN01.$DomainName"
$vmScriptDir = Join-Path $PSScriptRoot "..\vm"

###############################################################################
# Step 1: DNS changes — run on the DC VM
###############################################################################
Write-Host ""
Write-Host "[INFO]  Step 1: Updating DNS on DC ($DcVmName)..." -ForegroundColor Cyan

if ($Target -eq 'azure') {
    $dnsScriptPath = Join-Path $vmScriptDir "toggle-dns-to-azure.ps1"
    $dnsParams = @{
        DomainName        = $DomainName
        FileServerName    = $FileServerName
        DfsnHostFqdn      = $dfsnHostFqdn
        StorageAccount    = $StorageAccount
        ResourceGroupName = $RG
    }
} else {
    $dnsScriptPath = Join-Path $vmScriptDir "toggle-dns-to-local.ps1"
    $dnsParams = @{
        DomainName     = $DomainName
        FileServerName = $FileServerName
        FileServerIp   = $FileServerIp
    }
}

$dnsOk = Invoke-VMRunCommand -VmName $DcVmName -ScriptPath $dnsScriptPath -Parameters $dnsParams -Label "dns"
if (-not $dnsOk) {
    Write-Host "[ERROR] DNS update failed. Aborting." -ForegroundColor Red
    exit 1
}

###############################################################################
# Step 2: DFS-N + registry + SPN + kerberos — run on DFSN VM
###############################################################################
Write-Host ""
Write-Host "[INFO]  Step 2: Configuring DFS-N on DFSN server ($DfsnVmName)..." -ForegroundColor Cyan

$dfsnScriptPath = Join-Path $vmScriptDir "toggle-dfsn-target.ps1"
$dfsnParams = @{
    Target            = $Target
    StorageAccount    = $StorageAccount
    FileShareName     = $FileShareName
    FileServerName    = $FileServerName
    ResourceGroupName = $RG
}

$dfsnOk = Invoke-VMRunCommand -VmName $DfsnVmName -ScriptPath $dfsnScriptPath -Parameters $dfsnParams -Label "dfsn"
if (-not $dfsnOk) {
    Write-Host "[ERROR] DFS-N configuration failed." -ForegroundColor Red
    exit 1
}

###############################################################################
# Step 3: Kerberos realm mapping on client VM
###############################################################################
Write-Host ""
Write-Host "[INFO]  Step 3: Adding Kerberos realm mapping on client ($ClientVmName)..." -ForegroundColor Cyan

$realmScriptPath = Join-Path $vmScriptDir "set-realm-mapping.ps1"
$realmParams = @{
    StorageAccountFqdn = "${StorageAccount}.file.core.windows.net"
    RealmName          = $DomainName.ToUpper()
}

Invoke-VMRunCommand -VmName $ClientVmName -ScriptPath $realmScriptPath -Parameters $realmParams -Label "realm" | Out-Null

###############################################################################
# Step 4: Validate from client VM
###############################################################################
Write-Host ""
Write-Host "[INFO]  Step 4: Validating from client VM ($ClientVmName)..." -ForegroundColor Cyan

$validateScriptPath = Join-Path $vmScriptDir "validate-share-access.ps1"
$validateParams = @{
    FileServerName = $FileServerName
    FileShareName  = $FileShareName
}

Invoke-VMRunCommand -VmName $ClientVmName -ScriptPath $validateScriptPath -Parameters $validateParams -Label "validate" | Out-Null

###############################################################################
# Summary
###############################################################################
Write-Host ""
if ($Target -eq 'azure') {
    Write-Host "=========================================" -ForegroundColor Green
    Write-Host "  Toggle to Azure Files complete!" -ForegroundColor Green
    Write-Host "=========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  IMPORTANT: To test manually via RDP, you MUST log in as" -ForegroundColor Yellow
    Write-Host "  DFSLAB\azureadmin (domain account), NOT the local account." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Test: dir \\$FileServerName\$FileShareName" -ForegroundColor White
    Write-Host "  Expected: README-azurefiles.txt" -ForegroundColor White
} else {
    Write-Host "=========================================" -ForegroundColor Green
    Write-Host "  Toggle to local file server complete!" -ForegroundColor Green
    Write-Host "=========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Test: dir \\$FileServerName\$FileShareName" -ForegroundColor White
    Write-Host "  Expected: README-fileserver.txt" -ForegroundColor White
}
Write-Host ""
