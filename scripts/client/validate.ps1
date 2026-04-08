<#
.SYNOPSIS
    Validate share access and Kerberos authentication from the client VM.
    Runs from your workstation — executes validation commands on the client VM
    via az vm run-command.

.EXAMPLE
    .\validate.ps1
    .\validate.ps1 -FileServerName FILESVR01 -FileShareName share

.PARAMETER FileServerName
    Name of the file server (default: FILESVR01).

.PARAMETER FileShareName
    Name of the file share (default: share).

.PARAMETER RG
    Resource group name.

.PARAMETER ClientVmName
    Client VM resource name.
#>
param(
    [string]$RG             = "rg-dfs-azurefiles-demo",
    [string]$ClientVmName   = "vm-client-01",
    [string]$FileServerName = "FILESVR01",
    [string]$FileShareName  = "share"
)

$ErrorActionPreference = "Stop"

Write-Host "[INFO]  Validating from client VM ($ClientVmName)..." -ForegroundColor Cyan

$validateScript = @"

`$ErrorActionPreference = 'SilentlyContinue'

Write-Host '========================================'
Write-Host '  DFS-N Lab Validation'
Write-Host '========================================'
Write-Host "Computer : `$env:COMPUTERNAME"
Write-Host "Domain   : `$((Get-WmiObject Win32_ComputerSystem).Domain)"
Write-Host '========================================'

# Flush DNS and Kerberos caches for a clean test
ipconfig /flushdns | Out-Null
klist purge | Out-Null
net use * /delete /y 2>&1 | Out-Null
Start-Sleep -Seconds 3

###############################################################################
# 1. DNS Resolution
###############################################################################
Write-Host ''
Write-Host '--- [1] DNS Resolution for $FileServerName ---'
`$dns = Resolve-DnsName '$FileServerName' -ErrorAction SilentlyContinue
if (`$dns) {
    foreach (`$r in `$dns) {
        if (`$r.Type -eq 'CNAME') { Write-Host "  `$(`$r.Name) CNAME -> `$(`$r.NameHost)" }
        if (`$r.Type -eq 'A')     { Write-Host "  `$(`$r.Name) A -> `$(`$r.IPAddress)" }
    }
} else {
    Write-Host '  FAILED: Could not resolve $FileServerName'
}

###############################################################################
# 2. Share Access
###############################################################################
Write-Host ''
Write-Host '--- [2] Share Access: \\$FileServerName\$FileShareName ---'
`$sharePath = '\\$FileServerName\$FileShareName'
`$maxAttempts = 5
`$success = `$false

for (`$i = 1; `$i -le `$maxAttempts; `$i++) {
    if (Test-Path `$sharePath) {
        `$files = Get-ChildItem `$sharePath -ErrorAction SilentlyContinue
        Write-Host "  SUCCESS: `$sharePath is accessible (`$(`$files.Count) file(s))."
        foreach (`$f in `$files) { Write-Host "    - `$(`$f.Name)" }
        `$success = `$true
        break
    }
    Write-Host "  Attempt `$i/`${maxAttempts}: `$sharePath not reachable yet, waiting 10s..."
    Start-Sleep -Seconds 10
}

if (-not `$success) {
    Write-Host "  FAILED: Could not access `$sharePath after `$maxAttempts attempts."
}

###############################################################################
# 3. Kerberos Tickets
###############################################################################
Write-Host ''
Write-Host '--- [3] Kerberos Tickets (CIFS service tickets) ---'
`$tickets = klist 2>&1
`$cifsTickets = `$tickets | Select-String -Pattern 'cifs/' -SimpleMatch
if (`$cifsTickets) {
    foreach (`$t in `$cifsTickets) { Write-Host "  `$(`$t.Line.Trim())" }
} else {
    Write-Host '  No CIFS Kerberos tickets found.'
    Write-Host '  (This may be normal if NTLM fallback occurred or tickets were just purged.)'
}

# Also show all tickets for debugging
Write-Host ''
Write-Host '  All current tickets:'
`$tickets | Where-Object { `$_ -match 'Server:|#\d' } | ForEach-Object { Write-Host "    `$(`$_.Trim())" }

###############################################################################
# 4. SMB Connection Details
###############################################################################
Write-Host ''
Write-Host '--- [4] SMB Connection Details ---'
`$smb = Get-SmbConnection -ErrorAction SilentlyContinue
if (`$smb) {
    `$smb | Format-Table ServerName, ShareName, Dialect, UserName -AutoSize | Out-String | Write-Host
} else {
    Write-Host '  No active SMB connections found.'
}

###############################################################################
# 5. DFS Referral Check
###############################################################################
Write-Host ''
Write-Host '--- [5] DFS Referral Check ---'
try {
    `$refOut = dfsutil client referral '\\$FileServerName\$FileShareName' 2>&1 | Out-String
    if (`$refOut) { Write-Host `$refOut.Trim() } else { Write-Host '  No DFS referral (direct access).' }
} catch {
    Write-Host '  dfsutil not available or no referral.'
}

Write-Host ''
Write-Host '========================================'
Write-Host '  Validation Complete'
Write-Host '========================================'
"@

$validatePath = Join-Path $env:TEMP "validate-dfsn-$(Get-Date -Format 'yyyyMMddHHmmss').ps1"
$validateScript | Set-Content -Path $validatePath -Encoding UTF8

try {
    $result = az vm run-command invoke -g $RG -n $ClientVmName `
        --command-id RunPowerShellScript `
        --scripts "@$validatePath" `
        -o json 2>&1
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
} finally {
    Remove-Item -Path $validatePath -Force -ErrorAction SilentlyContinue
}
