<#
.SYNOPSIS
    Provision Azure infrastructure for the DFS-N root consolidation lab.
    Uses Bicep templates for infrastructure and Azure CLI for orchestration.
    Private networking with P2S VPN — no public IP on the VM.

.DESCRIPTION
    Deploys via Bicep (infra/main.bicep):
      - Resource Group, NSG, VNet (3 subnets), NIC (private IP only)
      - Windows Server 2025 VM (becomes AD DC + DNS server)
      - File server VM (domain-joined, hosts SMB share)
      - DFS-Namsepace Server (domain-joined, hosts DFS-Namespace)
      - Client VM (domain-joined, client connects to file shares.)
      - Storage Account (Entra auth, no shared keys) + Private Endpoint
      - Private DNS Zone (privatelink.file.core.windows.net)
      - P2S VPN Gateway (VpnGw1AZ, certificate auth)

    Post-deployment VM configuration (Azure CLI run-commands):
      Phase 1: Install AD DS + promote to DC + DNS forwarder -> reboot
      Phase 2: File server domain join + local SMB share

    Initial state: users access \\FILESVR01\share directly (file server VM).
    Use scripts\client\toggle.ps1 to set up DFS-N root consolidation and
    switch to Azure Files.

    Follows: https://learn.microsoft.com/en-us/azure/storage/files/files-manage-namespaces

.EXAMPLE    .\deploy.ps1
    .\deploy.ps1 -Location "eastus" -VmSize "Standard_D4as_v7"
#>
[CmdletBinding()]
param(
    [string]$RG = "rg-dfs-azurefiles-demo",
    [string]$Location = "westus3",
    [string]$VNetName = "vnet-dfs-demo",
    [string]$SubnetName = "snet-servers",
    [string]$NsgName = "nsg-dfs-demo",
    [string]$DnsVmName = "vm-dns-01",
    [string]$DnsComputerName = "DNS01",
    [string]$FileServerVmName = "vm-filesvr-01",
    [string]$FileServerComputerName = "FILESVR01",
    [string]$ClientVmName = "vm-client-01",
    [string]$ClientComputerName = "CLIENT01",
    [string]$DfsnVmName = "vm-dfsn-01",
    [string]$DfsnComputerName = "DFSN01",
    [string]$VmSize = "Standard_D4as_v7",
    [string]$AdminUser = "azureadmin",
    [securestring]$AdminPassSecure,
    [string]$Zone = "1",
    [string]$StorageAccount = "",
    [string]$FileShareName = "share",
    [int]$ShareQuota = 100,
    [string]$GatewayName = "vpng-dfs-demo",
    [string]$FileServerName = "FILESVR01",
    [string]$DomainName = "dfslab.local",
    [string]$DomainNetbios = "DFSLAB",
    [string]$VmDnsPrivateStaticIp = "10.0.1.4",
    [switch]$SkipInfra
)

$ErrorActionPreference = "Stop"

###############################################################################
# Helpers
###############################################################################
function Write-Info { param([string]$Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Cyan }
function Write-Warn { param([string]$Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }
function Write-Fatal { param([string]$Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red; throw $Msg }

function Assert-AzCli {
    if ($LASTEXITCODE -ne 0) { Write-Fatal $args[0] }
}

function Invoke-VMRunCommand {
    param(
        [string]$ScriptPath,
        [string[]]$Parameters,
        [string]$VmName
    )

    if (-not (Test-Path $ScriptPath)) {
        Write-Fatal "Script not found: $ScriptPath"
    }
    $resolvedPath = (Resolve-Path $ScriptPath).Path

    $runArgs = @(
        "vm", "run-command", "invoke",
        "-g", $RG,
        "-n", $VmName,
        "--command-id", "RunPowerShellScript",
        "--scripts", "@$resolvedPath",
        "-o", "json"
    )
    if ($Parameters.Count -gt 0) {
        $runArgs += "--parameters"
        $runArgs += $Parameters
    }

    $result = az @runArgs 2>&1
    Assert-AzCli "VM run-command failed."

    $parsed = $result | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($parsed -and $parsed.value) {
        foreach ($msg in $parsed.value) {
            if ($msg.code -match 'StdOut' -and $msg.message) {
                Write-Host $msg.message
            }
            elseif ($msg.code -match 'StdErr' -and $msg.message) {
                Write-Warn "VM stderr: $($msg.message)"
            }
        }
    }
}

###############################################################################
# Pre-flight checks
###############################################################################
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Fatal "Azure CLI (az) not found. Install from https://aka.ms/install-azure-cli"
}

az bicep version -o none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Info "Installing Bicep CLI..."
    az bicep install
    Assert-AzCli "Failed to install Bicep CLI."
}

$acct = az account show -o json 2>$null | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $acct) {
    Write-Fatal "Not logged in to Azure CLI. Run 'az login' first."
}
Write-Info "Subscription: $($acct.name) ($($acct.id))"

if (-not $AdminPassSecure) {
    $AdminPassSecure = Read-Host -Prompt "Enter VM admin password (12+ chars, upper+lower+digit+special)" -AsSecureString
}
$AdminPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassSecure))

if ([string]::IsNullOrEmpty($StorageAccount)) {
    # Check if a storage account already exists in the resource group
    $existingSa = az storage account list -g $RG --query "[0].name" -o tsv 2>$null
    if (-not [string]::IsNullOrEmpty($existingSa)) {
        $StorageAccount = $existingSa
        Write-Info "Using existing storage account: $StorageAccount"
    }
    else {
        $rand = -join ((48..57) + (97..122) | Get-Random -Count 8 | ForEach-Object { [char]$_ })
        $StorageAccount = "stdfs$rand"
        Write-Info "Auto-generated storage account name: $StorageAccount"
    }
}

if ($StorageAccount -notmatch '^[a-z0-9]{3,24}$') {
    Write-Fatal "Storage account name must be 3-24 lowercase letters/digits. Got: '$StorageAccount'"
}

$runId = Get-Date -Format 'yyyyMMddHHmmss'

if ($SkipInfra) {
    Write-Info "SkipInfra: Skipping steps 1-2 (certificates + Bicep deployment)."
    Write-Info "SkipInfra: Retrieving outputs from existing resources..."

    $VmPrivateIp = $VmDnsPrivateStaticIp
    $VpnGatewayPip = az network public-ip list -g $RG `
        --query "[?starts_with(name,'vpng-')].ipAddress | [0]" -o tsv 2>$null
    $StorageAccountId = az storage account show -g $RG -n $StorageAccount `
        --query "id" -o tsv 2>$null
    if ([string]::IsNullOrEmpty($StorageAccountId)) {
        Write-Fatal "Storage account '$StorageAccount' not found in '$RG'. Was infrastructure deployed?"
    }

    Write-Info "     VM Private IP   : $VmPrivateIp"
    Write-Info "     VPN Gateway PIP : $VpnGatewayPip"
    Write-Info "     Storage Account : $StorageAccount ($StorageAccountId)"
}
else {
    ###############################################################################
    # 1. Generate P2S VPN certificates
    ###############################################################################
    Write-Info "1/14  Generating P2S VPN certificates..."
    $certScript = Join-Path $PSScriptRoot "..\scripts\client\p2svpncert-setup.ps1"
    if (-not (Test-Path $certScript)) {
        Write-Fatal "Certificate script not found: $certScript"
    }

    # Capture the base64 cert data (last line of output)
    $certOutput = & (Resolve-Path $certScript).Path 2>&1
    $clientRootCertData = ($certOutput | Where-Object { $_ -is [string] -and $_.Length -gt 100 }) | Select-Object -Last 1
    if ([string]::IsNullOrEmpty($clientRootCertData)) {
        Write-Fatal "Failed to extract root certificate data from p2svpncert-setup.ps1"
    }
    Write-Info "     Root cert extracted ($($clientRootCertData.Length) chars)."

    ###############################################################################
    # 2. Deploy infrastructure via Bicep
    ###############################################################################
    Write-Info "2/14  Deploying Azure infrastructure via Bicep..."
    Write-Info "     Resource group '$RG' in '$Location'"
    Write-Info "     (Creates: RG, VNet, VM, Storage+PE, Private DNS, VPN Gateway)"
    Write-Info "     VPN Gateway deployment takes ~25-30 minutes."

    # Check VM SKU availability before deploying
    $skuAvailable = az vm list-skus -l $Location --size $VmSize --query "[0].name" -o tsv 2>$null
    if ([string]::IsNullOrEmpty($skuAvailable)) {
        Write-Fatal "VM size '$VmSize' not available in '$Location'. Try a different -VmSize or -Location."
    }

    $bicepFile = Join-Path $PSScriptRoot "main.bicep"
    if (-not (Test-Path $bicepFile)) {
        Write-Fatal "Bicep template not found: $bicepFile"
    }

    $deploymentName = "dfsn-$(Get-Date -Format 'yyyyMMddHHmmss')"

    $paramsObject = @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = @{
            rgName                 = @{ value = $RG }
            location               = @{ value = $Location }
            nsgName                = @{ value = $NsgName }
            vnetName               = @{ value = $VNetName }
            subnetName             = @{ value = $SubnetName }
            dnsVmName              = @{ value = $DnsVmName }
            dnsVmComputerName      = @{ value = $DnsComputerName }
            fileServerVmName       = @{ value = $FileServerVmName }
            fileServerComputerName = @{ value = $FileServerComputerName }
            clientVmName           = @{ value = $ClientVmName }
            clientComputerName     = @{ value = $ClientComputerName }
            dfsnServerVmName       = @{ value = $DfsnVmName }
            dfsnServerComputerName = @{ value = $DfsnComputerName }
            vmSize                 = @{ value = $VmSize }
            adminUser              = @{ value = $AdminUser }
            adminPass              = @{ value = $AdminPass }
            storageAccountName     = @{ value = $StorageAccount }
            fileShareName          = @{ value = $FileShareName }
            shareQuota             = @{ value = $ShareQuota }
            zone                   = @{ value = $Zone }
            gatewayName            = @{ value = $GatewayName }
            clientRootCertData     = @{ value = $clientRootCertData }
        }
    }

    $paramsFile = Join-Path $env:TEMP "dfsn-params-$deploymentName.json"
    $paramsObject | ConvertTo-Json -Depth 10 | Set-Content -Path $paramsFile -Encoding UTF8

    try {
        az deployment sub create `
            --name $deploymentName `
            --location $Location `
            --template-file $bicepFile `
            --parameters "@$paramsFile" `
            -o none
        Assert-AzCli "Bicep deployment failed."
    }
    finally {
        Remove-Item -Path $paramsFile -Force -ErrorAction SilentlyContinue
    }

    Write-Info "     Infrastructure deployed."

    $VpnGatewayPip = az deployment sub show --name $deploymentName `
        --query "properties.outputs.vpnGatewayPublicIp.value" -o tsv
    $StorageAccountId = az deployment sub show --name $deploymentName `
        --query "properties.outputs.storageAccountId.value" -o tsv

    Write-Info "     VPN Gateway PIP: $VpnGatewayPip"
    Write-Info "     Storage Account Id: $StorageAccountId"

} # end if/else SkipInfra

###############################################################################
# 3. Phase 1a: Install AD DS features (may require reboot before promotion)
###############################################################################
Write-Info "3/14  Phase 1: Installing AD DS and promoting to domain controller..."
Write-Info "     Domain: $DomainName ($DomainNetbios)"
Write-Info "     (This takes 3-5 minutes)"

$phase1Script = Join-Path $PSScriptRoot "..\scripts\vm\bootstrap-ad.ps1"
$escapedPass = $AdminPass -replace "'", "''"
Invoke-VMRunCommand -ScriptPath $phase1Script `
    -VmName $DnsVmName `
    -Parameters @(
        "DomainName=$DomainName",
        "DomainNetbios=$DomainNetbios",
        "SafeModePass=$escapedPass"
    )

# Feature installation often requires a reboot before DC promotion can proceed.
# Reboot now, then re-run the script — it is idempotent. On the second run the
# features are already installed so Install-ADDSForest will succeed.
Write-Info "     Rebooting after feature install (required before DC promotion)..."
az vm restart -g $RG -n $DnsVmName -o none
Assert-AzCli "Failed to restart VM."
$waitSec = 60
Write-Info "     Waiting $waitSec seconds for VM to come back..."
for ($i = $waitSec; $i -gt 0; $i -= 10) {
    Write-Host "       $i seconds remaining..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 10
}

###############################################################################
# 3b. Phase 1b: Re-run bootstrap to promote (features already installed)
###############################################################################
Write-Info "     Re-running bootstrap-ad.ps1 for DC promotion..."
Invoke-VMRunCommand -ScriptPath $phase1Script `
    -VmName $DnsVmName `
    -Parameters @(
        "DomainName=$DomainName",
        "DomainNetbios=$DomainNetbios",
        "SafeModePass=$escapedPass"
    )

###############################################################################
# 4. Reboot VM + wait for AD DS to initialize
###############################################################################
Write-Info "4/14  Rebooting VM for DC promotion to finalize..."
az vm restart -g $RG -n $DnsVmName -o none
Assert-AzCli "Failed to restart VM."
Write-Info "     Rebooted. Waiting for AD DS to initialize (~90 seconds)..."

$waitSec = 90
Write-Info "     Waiting $waitSec seconds..."
for ($i = $waitSec; $i -gt 0; $i -= 10) {
    Write-Host "       $i seconds remaining..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 10
}

$maxRetries = 6
for ($i = 1; $i -le $maxRetries; $i++) {
    $vmState = az vm get-instance-view -g $RG -n $DnsVmName `
        --query "instanceView.statuses[?code=='PowerState/running'].displayStatus" -o tsv 2>$null
    if ($vmState -eq "VM running") {
        Write-Info "     VM is running."
        break
    }
    Write-Host "       VM not ready yet, waiting 15s (attempt $i/$maxRetries)..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 15
}

# Verify AD DS is actually ready to serve (not just VM running)
Write-Info "     Verifying AD DS is ready..."
$adReadyRetries = 12
for ($i = 1; $i -le $adReadyRetries; $i++) {
    $adCheckResult = az vm run-command invoke -g $RG -n $DnsVmName `
        --command-id RunPowerShellScript `
        --scripts "try { `$d = Get-ADDomain -ErrorAction Stop; Write-Host `$d.DNSRoot } catch { Write-Host 'NOT_READY' }" `
        -o json 2>$null | ConvertFrom-Json
    $adOutput = ($adCheckResult.value | Where-Object { $_.code -match 'StdOut' }).message
    if ($adOutput -and $adOutput.Trim() -eq $DomainName) {
        Write-Info "     AD DS is ready: $DomainName"
        break
    }
    if ($i -eq $adReadyRetries) {
        Write-Fatal "AD DS did not become ready after $adReadyRetries attempts. Check the DC VM."
    }
    Write-Host "       AD DS not ready yet, waiting 20s (attempt $i/$adReadyRetries)..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 20
}

###############################################################################
# 5. Update VNet DNS to point at the Domain Controller
###############################################################################
Write-Info "5/14  Updating VNet DNS servers to $VmDnsPrivateStaticIp (AD DNS)..."
az network vnet update -g $RG -n $VNetName --dns-servers $VmDnsPrivateStaticIp -o none
Assert-AzCli "Failed to update VNet DNS."
Write-Info "     VNet DNS updated."

# Restart file server, dfsn server, and client so they pick up the new DNS via DHCP
Write-Info "     Restarting file server and client VMs to pick up VNet DNS change..."
az vm restart -g $RG -n $FileServerVmName -o none
Assert-AzCli "Failed to restart file server VM."
az vm restart -g $RG -n $ClientVmName -o none
Assert-AzCli "Failed to restart client VM."
az vm restart -g $RG -n $DfsnVmName -o none
Assert-AzCli "Failed to restart dfsn VM."
$waitSec = 60
Write-Info "     Waiting $waitSec seconds for VMs to come back..."
for ($i = $waitSec; $i -gt 0; $i -= 10) {
    Write-Host "       $i seconds remaining..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 10
}

###############################################################################
# 6. Setup file server VM (domain-join + create share)
###############################################################################
Write-Info "6/14  Setting up file server VM '$FileServerVmName'..."
$fileServerScript = Join-Path $PSScriptRoot "..\scripts\vm\bootstrap-fileserver.ps1"
$escapedPassFs = $AdminPass -replace "'", "''"

Invoke-VMRunCommand -ScriptPath $fileServerScript `
    -VmName $FileServerVmName `
    -Parameters @(
        "DomainName=$DomainName",
        "AdminUser=$AdminUser",
        "AdminPass=$escapedPassFs",
        "FileShareName=$FileShareName"
    )

# Reboot file server to complete domain join
Write-Info "     Rebooting file server for domain join..."
az vm restart -g $RG -n $FileServerVmName -o none
Assert-AzCli "Failed to restart file server VM."
$waitSec = 60
Write-Info "     Waiting $waitSec seconds..."
for ($i = $waitSec; $i -gt 0; $i -= 10) {
    Write-Host "       $i seconds remaining..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 10
}

###############################################################################
# 7. Setup DFS-N server VM (domain-join + DFS-N role + root consolidation)
###############################################################################
Write-Info "7/14  Setting up DFS-N server VM '$DfsnVmName'..."
$dfsnScript = Join-Path $PSScriptRoot "..\scripts\vm\bootstrap-dfsn.ps1"
$escapedPassDf = $AdminPass -replace "'", "''"

Invoke-VMRunCommand -ScriptPath $dfsnScript `
    -VmName $DfsnVmName `
    -Parameters @(
        "DomainName=$DomainName",
        "AdminUser=$AdminUser",
        "AdminPass=$escapedPassDf"
    )

# Reboot DFS-N server for domain join
Write-Info "     Rebooting DFS-N server for domain join..."
az vm restart -g $RG -n $DfsnVmName -o none
Assert-AzCli "Failed to restart DFS-N VM."
$waitSec = 60
Write-Info "     Waiting $waitSec seconds..."
for ($i = $waitSec; $i -gt 0; $i -= 10) {
    Write-Host "       $i seconds remaining..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 10
}

###############################################################################
# 8. Setup client VM (domain-join)
###############################################################################
Write-Info "8/14  Setting up client VM '$ClientVmName'..."
$clientScript = Join-Path $PSScriptRoot "..\scripts\vm\bootstrap-client.ps1"
$escapedPassCl = $AdminPass -replace "'", "''"

Invoke-VMRunCommand -ScriptPath $clientScript `
    -VmName $ClientVmName `
    -Parameters @(
        "DomainName=$DomainName",
        "AdminUser=$AdminUser",
        "AdminPass=$escapedPassCl"
    )

# Reboot client to complete domain join
Write-Info "     Rebooting client for domain join..."
az vm restart -g $RG -n $ClientVmName -o none
Assert-AzCli "Failed to restart client VM."
$waitSec = 60
Write-Info "     Waiting $waitSec seconds..."
for ($i = $waitSec; $i -gt 0; $i -= 10) {
    Write-Host "       $i seconds remaining..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 10
}

###############################################################################
# 9. Domain-join storage account to AD DS for identity-based SMB auth
###############################################################################
Write-Info "9/14  Domain-joining storage account to AD DS..."

$subscriptionId = $acct.id
$joinScript = Join-Path $PSScriptRoot "..\scripts\vm\join-storage-to-ad.ps1"

Invoke-VMRunCommand -ScriptPath $joinScript `
    -VmName $DnsVmName `
    -Parameters @(
        "StorageAccountName=$StorageAccount",
        "ResourceGroupName=$RG",
        "SubscriptionId=$subscriptionId"
    )

###############################################################################
# 10. Configure Kerberos realm mapping for Azure Files on DC and client
###############################################################################
Write-Info "10/14 Configuring Kerberos realm mapping for Azure Files..."
$realmFqdn = "${StorageAccount}.file.core.windows.net"
$realmName = $DomainName.ToUpper()

az vm run-command invoke -g $RG -n $DnsVmName `
    --command-id RunPowerShellScript `
    --scripts "ksetup /addhosttorealmmap $realmFqdn $realmName; Write-Host 'Realm mapping added on DC: $realmFqdn -> $realmName'" `
    -o none 2>$null

Write-Info "      DC: $realmFqdn -> $realmName"

# On the client
az vm run-command invoke -g $RG -n $ClientVmName `
    --command-id RunPowerShellScript `
    --scripts "ksetup /addhosttorealmmap $realmFqdn $realmName; Write-Host 'Realm mapping added on client: $realmFqdn -> $realmName'" `
    -o none 2>$null
Write-Info "      Client: $realmFqdn -> $realmName"

###############################################################################
# 11. Assign storage data roles to current user
###############################################################################
Write-Info "11/14 Assigning storage data roles to current user..."
$currentUserId = az ad signed-in-user show --query "id" -o tsv 2>$null
if ($currentUserId) {
    $elevatedContributorRoleId = "a7264617-510b-434b-a828-9731dc254ea7"
    $privilegedContributorRoleId = "69566ab7-960f-475b-8e7c-b3118f30c6bd"
    az role assignment create `
        --assignee $currentUserId `
        --role $elevatedContributorRoleId `
        --scope $StorageAccountId `
        -o none 2>$null
    az role assignment create `
        --assignee $currentUserId `
        --role $privilegedContributorRoleId `
        --scope $StorageAccountId `
        -o none 2>$null
    Write-Info "      Roles assigned to current user."
}
else {
    Write-Warn "      Could not determine signed-in user. Assign roles manually."
}

###############################################################################
# 12. Seed Azure Files share with marker file
###############################################################################
Write-Info "12/14 Uploading marker file to Azure Files share via DC managed identity..."
$seedScript = @"
`$ErrorActionPreference = 'Stop'
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Storage -ErrorAction Stop
Connect-AzAccount -Identity -ErrorAction Stop | Out-Null

`$ctx = New-AzStorageContext -StorageAccountName '$StorageAccount' -UseConnectedAccount -EnableFileBackupRequestIntent
`$shareName = '$FileShareName'

`$tempFile = Join-Path `$env:TEMP 'README-azurefiles.txt'
@'
This file is hosted on Azure Files (storage account: $StorageAccount).
If you see this after running: dir \\FILESVR01\share
then DFS-N root consolidation is working — the backend is now Azure Files.
'@ | Set-Content -Path `$tempFile -Encoding UTF8

Set-AzStorageFileContent -ShareName `$shareName -Source `$tempFile -Path 'README-azurefiles.txt' -Context `$ctx -Force
Remove-Item `$tempFile -Force -ErrorAction SilentlyContinue
Write-Host '  Marker file uploaded to Azure Files share.'
"@

$seedScriptPath = Join-Path $env:TEMP "seed-azurefiles-$runId.ps1"
$seedScript | Set-Content -Path $seedScriptPath -Encoding UTF8
try {
    Invoke-VMRunCommand -ScriptPath $seedScriptPath -VmName $DnsVmName
}
finally {
    Remove-Item -Path $seedScriptPath -Force -ErrorAction SilentlyContinue
}

###############################################################################
# 13. Verify initial state — client can reach \\FILESVR01\share
###############################################################################
Write-Info "13/14 Verifying client can access \\$FileServerComputerName\$FileShareName..."
$verifyScript = @"
`$ErrorActionPreference = 'Stop'
`$sharePath = '\\$FileServerComputerName\$FileShareName'

# Retry up to 3 times (DNS propagation may be in progress)
`$maxAttempts = 3
for (`$i = 1; `$i -le `$maxAttempts; `$i++) {
    if (Test-Path `$sharePath) {
        `$files = Get-ChildItem `$sharePath -ErrorAction SilentlyContinue
        Write-Host "  SUCCESS: `$sharePath is accessible (`$(`$files.Count) file(s))."
        foreach (`$f in `$files) { Write-Host "    - `$(`$f.Name)" }

        # Verify DNS resolves to file server IP
        `$dns = Resolve-DnsName '$FileServerComputerName' -ErrorAction SilentlyContinue
        if (`$dns) { Write-Host "  DNS: $FileServerComputerName -> `$(`$dns.IPAddress -join ', ')" }
        exit 0
    }
    Write-Host "  Attempt `$i/`${maxAttempts}: `$sharePath not reachable yet, waiting 15s..."
    Start-Sleep -Seconds 15
}
Write-Host "  WARNING: Could not verify `$sharePath from client. Check DNS and share access manually."
"@

$verifyScriptPath = Join-Path $env:TEMP "verify-client-$runId.ps1"
$verifyScript | Set-Content -Path $verifyScriptPath -Encoding UTF8
try {
    Invoke-VMRunCommand -ScriptPath $verifyScriptPath -VmName $ClientVmName
}
finally {
    Remove-Item -Path $verifyScriptPath -Force -ErrorAction SilentlyContinue
}

###############################################################################
# 14. Summary
###############################################################################

Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host "  Deployment Complete!" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""
Write-Info "Resource Group :  $RG"
Write-Info "DNS VM Name    :  $DnsVmName ($DnsComputerName)"
Write-Info "DNS VM Private IP:  $VmDnsPrivateStaticIp"
Write-Info "VPN Gateway IP :  $VpnGatewayPip"
Write-Info "Domain         :  $DomainName ($DomainNetbios)"
Write-Info "Admin User     :  $DomainNetbios\$AdminUser"
Write-Info "Storage Account:  $StorageAccount (AD DS auth, Private Endpoint)"
Write-Info "File Share     :  $FileShareName"
Write-Info "File Server    :  $FileServerComputerName (\\$FileServerComputerName\$FileShareName)"
Write-Info "DFS-N Server   :  $DfsnComputerName (10.0.1.7) - standalone namespace host"
Write-Info "Client VM      :  $ClientComputerName (10.0.1.6) - domain-joined test client"
Write-Host ""
Write-Host "--- Initial State (verified by step 13) ---" -ForegroundColor Yellow
Write-Host "  Client VM ($ClientComputerName) can access \\$FileServerComputerName\$FileShareName directly." -ForegroundColor White
Write-Host "  No DFS-N is configured yet." -ForegroundColor White
Write-Host ""
Write-Host "--- Next Steps ---" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. Toggle to Azure Files (sets up DFS-N root consolidation):" -ForegroundColor White
Write-Host "     .\scripts\client\toggle.ps1 -Target azure" -ForegroundColor White
Write-Host ""
Write-Host "  2. Toggle back to local (tears down DFS-N, restores direct access):" -ForegroundColor White
Write-Host "     .\scripts\client\toggle.ps1 -Target local" -ForegroundColor White
Write-Host ""
Write-Host "  3. Validate (run after either toggle):" -ForegroundColor White
Write-Host "     .\scripts\client\validate.ps1" -ForegroundColor White
Write-Host ""
Write-Host "--- Optional: RDP into client VM for manual testing ---" -ForegroundColor DarkGray
Write-Host "  a. Download VPN client:" -ForegroundColor DarkGray
Write-Host "     az network vnet-gateway vpn-client generate -g $RG -n $GatewayName -o tsv" -ForegroundColor DarkGray
Write-Host "  b. Connect VPN, then: mstsc /v:10.0.1.6" -ForegroundColor DarkGray
Write-Host "  c. Login as: $DomainNetbios\$AdminUser" -ForegroundColor DarkGray
Write-Host "  d. Test: dir \\$FileServerComputerName\$FileShareName" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  To teardown, run: .\infra\teardown.ps1"
Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
