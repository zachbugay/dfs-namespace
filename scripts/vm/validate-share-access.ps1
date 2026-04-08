<#
.SYNOPSIS
    Clears caches and validates share access, DNS resolution, and SMB connections.
    Runs on the client VM via az vm run-command.
#>
param(
    [Parameter(Mandatory)][string]$FileServerName,
    [Parameter(Mandatory)][string]$FileShareName
)

$ErrorActionPreference = 'SilentlyContinue'

# Clear all caches: SMB connections, DFS referrals, DNS, Kerberos tickets
Write-Host "  Clearing caches..."
net use * /delete /y 2>&1 | Out-Null
dfsutil /pktflush 2>&1 | Out-Null
ipconfig /flushdns | Out-Null
klist purge 2>&1 | Out-Null
Start-Sleep -Seconds 5

$sharePath = "\\$FileServerName\$FileShareName"
$maxAttempts = 5
$success = $false

for ($i = 1; $i -le $maxAttempts; $i++) {
    if (Test-Path $sharePath) {
        $files = Get-ChildItem $sharePath -ErrorAction SilentlyContinue
        Write-Host "  SUCCESS: $sharePath is accessible ($($files.Count) file(s))."
        foreach ($f in $files) { Write-Host "    - $($f.Name)" }
        $success = $true
        break
    }
    Write-Host "  Attempt $i/${maxAttempts}: $sharePath not reachable yet, waiting 10s..."
    Start-Sleep -Seconds 10
}

if (-not $success) {
    Write-Host "  FAILED: Could not access $sharePath after $maxAttempts attempts."
}

Write-Host ""
Write-Host "  --- DNS Resolution ---"
$dns = Resolve-DnsName $FileServerName -ErrorAction SilentlyContinue
if ($dns) {
    foreach ($r in $dns) {
        if ($r.Type -eq 'CNAME') { Write-Host "  $($r.Name) CNAME -> $($r.NameHost)" }
        if ($r.Type -eq 'A')     { Write-Host "  $($r.Name) A -> $($r.IPAddress)" }
    }
}

Write-Host ""
Write-Host "  --- SMB Connection ---"
$smb = Get-SmbConnection -ErrorAction SilentlyContinue
if ($smb) {
    $smb | Format-Table ServerName, ShareName, Dialect -AutoSize | Out-String | Write-Host
} else {
    Write-Host "  No active SMB connections."
}
