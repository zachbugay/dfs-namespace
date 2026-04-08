<#
.SYNOPSIS
    Toggle \\FILESVR01\share between direct file server access and Azure Files
    via DFS-N standalone namespace with root consolidation.
    Runs on the DFS-N server VM via 'az vm run-command invoke'.

.DESCRIPTION
    Root consolidation uses a standalone DFS namespace named #FILESVR01 (with
    hash prefix) on DFSN01. Combined with a DNS CNAME (FILESVR01 -> DFSN01)
    and the OptionalNames registry value, clients accessing \\FILESVR01\share
    are transparently routed through the DFS namespace.

    AZURE mode:
      1. Adds FILESVR01 to OptionalNames on the DFS-N server's LanmanServer.
      2. Sets DisableStrictNameChecking = 1.
      3. Ensures root consolidation registry keys are set.
      4. Replaces FILESVR01 DNS A record with a CNAME to the DFS-N server.
      5. Adds cifs/FILESVR01 SPNs to the DFS-N server's AD computer account.
      6. Creates standalone namespace \\DFSN01\#FILESVR01 with DFS folder
         'share' targeting \\storageaccount.file.core.windows.net\share.

    LOCAL mode:
      1. Removes the DFS namespace and backing share.
      2. Restores DNS A record for FILESVR01 pointing to the file server IP.
      3. Removes OptionalNames from the DFS-N server.

    Ref: https://learn.microsoft.com/azure/storage/files/files-manage-namespaces

.PARAMETER Target
    'azure' to set up DFS-N root consolidation pointing to Azure Files.
    'local'  to tear down DFS-N and restore direct file server access.

.PARAMETER StorageAccount
    Azure storage account name (required when Target = 'azure').

.PARAMETER FileShareName
    File share name (default: share).

.PARAMETER FileServerName
    Name of the file server to take over (default: FILESVR01).

.PARAMETER FileServerIp
    IP address of the file server VM (default: 10.0.1.5).

.PARAMETER ResourceGroupName
    Azure resource group containing the storage account.

.NOTES
    Must run on the DFS-N server (not the DC).
    RSAT-AD-Tools and RSAT-DNS-Server must be installed (done by bootstrap-dfsn.ps1).
    Idempotent — safe to re-run.
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet('azure', 'local')]
    [string]$Target,

    [string]$StorageAccount    = "",
    [string]$FileShareName     = "share",
    [string]$FileServerName    = "FILESVR01",
    [string]$FileServerIp      = "10.0.1.5",
    [string]$ResourceGroupName = ""
)

if ($Target -eq 'azure' -and [string]::IsNullOrEmpty($StorageAccount)) {
    throw "StorageAccount is required when switching to Azure Files."
}

$ErrorActionPreference = "Stop"

$domain        = (Get-ADDomain).DNSRoot
$dfsnHostname  = "$env:COMPUTERNAME.$domain"
$dfsnShortName = $env:COMPUTERNAME
$nsName        = "#${FileServerName}"
$nsPath        = "\\${dfsnShortName}\${nsName}"
$azureTarget   = "\\${StorageAccount}.file.core.windows.net\${FileShareName}"

# Import DFSN module (per Microsoft docs: https://learn.microsoft.com/azure/storage/files/files-manage-namespaces)
Import-Module -Name DFSN -ErrorAction Stop

Write-Host "========================================"
Write-Host "  DFS-N Root Consolidation Toggle"
Write-Host "========================================"
Write-Host "Domain       : $domain"
Write-Host "DFS-N Server : $dfsnHostname"
Write-Host "Server Name  : $FileServerName"
Write-Host "Namespace    : $nsPath"
Write-Host "Target       : $Target"
Write-Host "========================================"

if ($Target -eq 'azure') {
    Write-Host "`n--- Setting up DFS-N root consolidation for Azure Files ---"

    ###########################################################################
    # 1. Add FILESVR01 as OptionalName on the DFS-N server's SMB server
    ###########################################################################
    Write-Host "`n[1/8] Configuring SMB server OptionalNames and registry..."
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"

    $current = (Get-ItemProperty -Path $regPath -Name OptionalNames -ErrorAction SilentlyContinue).OptionalNames
    if ($current -notcontains $FileServerName) {
        Set-ItemProperty -Path $regPath -Name OptionalNames -Value @($FileServerName) -Type MultiString
        Write-Host "  OptionalNames set to $FileServerName"
    } else {
        Write-Host "  OptionalNames already contains $FileServerName"
    }

    reg add "HKLM\System\CurrentControlSet\Services\LanmanServer\Parameters" /v DisableStrictNameChecking /t REG_DWORD /d 1 /f | Out-Null
    Write-Host "  DisableStrictNameChecking = 1"

    ###########################################################################
    # 2. Ensure root consolidation registry keys
    ###########################################################################
    Write-Host "`n[2/8] Verifying root consolidation registry keys..."
    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Dfs" -Type Registry -ErrorAction SilentlyContinue | Out-Null
    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Dfs\Parameters" -Type Registry -ErrorAction SilentlyContinue | Out-Null
    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Dfs\Parameters\Replicated" -Type Registry -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Dfs\Parameters\Replicated" -Name "ServerConsolidationRetry" -Value 1
    Write-Host "  ServerConsolidationRetry = 1"

    ###########################################################################
    # 3. Add cifs/FILESVR01 SPNs to this DFS-N server (DFSN01 can modify
    #    its own AD object). FILESVR01 SPN removal is done by toggle.ps1
    #    on the DC which has full AD admin rights.
    ###########################################################################
    Write-Host "`n[3/8] Adding cifs SPNs for $FileServerName to $dfsnShortName..."
    $spnsToAdd = @(
        "cifs/${FileServerName}",
        "cifs/${FileServerName}.${domain}"
    )
    foreach ($spn in $spnsToAdd) {
        $check = setspn -Q $spn 2>&1 | Out-String
        if ($check -match $dfsnShortName) {
            Write-Host "  SPN already on ${dfsnShortName}: $spn"
        } else {
            $out = setspn -S $spn $dfsnShortName 2>&1 | Out-String
            Write-Host "  Added to ${dfsnShortName}: $spn"
        }
    }

    ###########################################################################
    # 4. Configure Kerberos realm mapping for Azure Files
    ###########################################################################
    Write-Host "`n[4/8] Configuring Kerberos realm mapping..."
    $realmName = $domain.ToUpper()
    $azureFqdn = "${StorageAccount}.file.core.windows.net"
    ksetup /addhosttorealmmap $azureFqdn $realmName 2>$null
    Write-Host "  $azureFqdn -> $realmName"

    ###########################################################################
    # 5. Test connectivity to Azure Files private endpoint
    ###########################################################################
    Write-Host "`n[5/8] Testing Azure Files connectivity..."
    $conn = Test-NetConnection -ComputerName $azureFqdn -Port 445 -WarningAction SilentlyContinue
    if (-not $conn.TcpTestSucceeded) {
        throw "Cannot reach $azureFqdn on port 445. Check private endpoint and DNS."
    }
    Write-Host "  Connectivity OK: $azureFqdn :445"

    ###########################################################################
    # 6. Create standalone DFS-N namespace: \\DFSN01\#FILESVR01
    #    Root consolidation uses # prefix per Microsoft documentation.
    ###########################################################################
    Write-Host "`n[6/8] Creating DFS-N root consolidation namespace $nsPath..."

    # Ensure DFS service is running and in clean state
    Set-Service -Name "Dfs" -StartupType Automatic -ErrorAction SilentlyContinue
    try { Restart-Service -Name "Dfs" -Force -ErrorAction Stop } catch {}
    Start-Sleep -Seconds 3

    # Clean up any previous namespace
    try { Remove-DfsnRoot -Path $nsPath -Force -ErrorAction SilentlyContinue } catch {}
    Remove-SmbShare -Name $nsName -Force -ErrorAction SilentlyContinue
    # Also clean up any old flat-style namespace that may have been used before
    $oldNsPath = "\\${FileServerName}\${FileShareName}"
    try { Remove-DfsnRoot -Path $oldNsPath -Force -ErrorAction SilentlyContinue } catch {}
    Remove-SmbShare -Name $FileShareName -Force -ErrorAction SilentlyContinue

    # Create backing folder and SMB share for the namespace root
    $rootFolder = "C:\DFSRoots\${nsName}"
    if (-not (Test-Path $rootFolder)) {
        New-Item -Path $rootFolder -ItemType Directory -Force | Out-Null
    }
    if (-not (Get-SmbShare -Name $nsName -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name $nsName -Path $rootFolder -FullAccess "Everyone" | Out-Null
        Write-Host "  SMB share created: $nsName"
    } else {
        Write-Host "  SMB share already exists: $nsName"
    }

    # Restart LanmanServer so it picks up the new share + OptionalNames before DFS-N creation
    Write-Host "  Restarting LanmanServer before namespace creation..."
    try { Restart-Service LanmanServer -Force -ErrorAction Stop; Start-Sleep -Seconds 5 } catch {
        Write-Host "  LanmanServer restart failed (will continue)."
    }
    # Re-apply OptionalNames (restart may clear them)
    $regPathPre = "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"
    if ((Get-ItemProperty -Path $regPathPre -Name OptionalNames -ErrorAction SilentlyContinue).OptionalNames -notcontains $FileServerName) {
        Set-ItemProperty -Path $regPathPre -Name OptionalNames -Value @($FileServerName) -Type MultiString
    }
    # Restart DFS service after LanmanServer
    try { Restart-Service -Name "Dfs" -Force -ErrorAction Stop; Start-Sleep -Seconds 3 } catch {}

    $existingNS = $null
    try { $existingNS = Get-DfsnRoot -Path $nsPath -ErrorAction SilentlyContinue } catch {}
    if ($existingNS) {
        Write-Host "  Namespace already exists."
    } else {
        New-DfsnRoot -Path $nsPath `
            -TargetPath $nsPath `
            -Type Standalone | Out-Null
        Write-Host "  Namespace created: $nsPath"
    }

    ###########################################################################
    # 9. Add DFS folder 'share' with Azure Files target
    ###########################################################################
    Write-Host "`n[7/8] Adding DFS folder '${FileShareName}' with Azure Files target..."
    $folderPath = "${nsPath}\${FileShareName}"

    $existingFolder = $null
    try { $existingFolder = Get-DfsnFolder -Path $folderPath -ErrorAction SilentlyContinue } catch {}
    if ($existingFolder) {
        # Ensure the Azure target is present and online
        $existingTargets = Get-DfsnFolderTarget -Path $folderPath -ErrorAction SilentlyContinue
        $azureTargetExists = $existingTargets | Where-Object { $_.TargetPath -eq $azureTarget }
        if (-not $azureTargetExists) {
            New-DfsnFolderTarget -Path $folderPath -TargetPath $azureTarget -State Online | Out-Null
            Write-Host "  Added target: $azureTarget"
        } else {
            Set-DfsnFolderTarget -Path $folderPath -TargetPath $azureTarget -State Online
            Write-Host "  Target already exists, set Online: $azureTarget"
        }
    } else {
        New-DfsnFolder -Path $folderPath -TargetPath $azureTarget | Out-Null
        Write-Host "  Folder created: $folderPath -> $azureTarget"
    }

    # Set referral TTL to 0 for instant toggle switching
    Set-DfsnFolder -Path $folderPath -TimeToLiveSec 0 -ErrorAction SilentlyContinue

    # Verify namespace and folder were created
    Write-Host ""
    Write-Host "  --- Verification ---"
    $verifyRoot = Get-DfsnRoot -Path $nsPath -ErrorAction SilentlyContinue
    if ($verifyRoot) {
        Write-Host "  Namespace OK: $($verifyRoot.Path) [Type: $($verifyRoot.Type), State: $($verifyRoot.State)]"
    } else {
        Write-Host "  ERROR: Namespace $nsPath was NOT created!" 
    }
    $verifyFolder = Get-DfsnFolder -Path $folderPath -ErrorAction SilentlyContinue
    if ($verifyFolder) {
        Write-Host "  Folder OK:    $($verifyFolder.Path) [State: $($verifyFolder.State)]"
    } else {
        Write-Host "  ERROR: Folder $folderPath was NOT created!"
    }
    $verifyTarget = Get-DfsnFolderTarget -Path $folderPath -ErrorAction SilentlyContinue
    if ($verifyTarget) {
        foreach ($t in $verifyTarget) {
            Write-Host "  Target OK:    $($t.TargetPath) [State: $($t.State)]"
        }
    } else {
        Write-Host "  ERROR: No folder targets found for $folderPath!"
    }

    ###########################################################################
    # 10. Restart services and re-verify OptionalNames
    ###########################################################################
    Write-Host "`n[8/8] Restarting LanmanServer and DFS services..."
    try {
        Restart-Service LanmanServer -Force -ErrorAction Stop
        Start-Sleep -Seconds 5
        Write-Host "  LanmanServer restarted."
    } catch {
        Write-Host "  LanmanServer restart failed (active sessions). Will restart DFS service independently."
    }

    # Re-apply OptionalNames after LanmanServer restart (restart can clear them)
    $regPath2 = "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"
    $postCheck = (Get-ItemProperty -Path $regPath2 -Name OptionalNames -ErrorAction SilentlyContinue).OptionalNames
    if ($postCheck -notcontains $FileServerName) {
        Set-ItemProperty -Path $regPath2 -Name OptionalNames -Value @($FileServerName) -Type MultiString
        Write-Host "  Re-applied OptionalNames after service restart."
    }
    $dsnc = (Get-ItemProperty -Path $regPath2 -Name DisableStrictNameChecking -ErrorAction SilentlyContinue).DisableStrictNameChecking
    if ($dsnc -ne 1) {
        Set-ItemProperty -Path $regPath2 -Name DisableStrictNameChecking -Value 1 -Type DWord
        Write-Host "  Re-applied DisableStrictNameChecking after service restart."
    }

    Set-Service -Name "Dfs" -StartupType Automatic
    Restart-Service -Name "Dfs" -Force
    Start-Sleep -Seconds 5
    Write-Host "  Services restarted and registry verified."

    Write-Host "`n========================================"
    Write-Host "  DFS-N Root Consolidation Active!"
    Write-Host "========================================"
    Write-Host "DNS CNAME      : ${FileServerName}.${domain} -> $dfsnHostname"
    Write-Host "DFS Namespace  : $nsPath (Standalone, root consolidation)"
    Write-Host "DFS Folder     : ${nsPath}\${FileShareName}"
    Write-Host "Azure Target   : $azureTarget"
    Write-Host ""
    Write-Host "Test: dir \\${FileServerName}\${FileShareName}"
    Write-Host "========================================"

} else {
    Write-Host "`n--- Tearing down DFS-N root consolidation ---"

    ###########################################################################
    # 1. Remove DFS-N namespace
    ###########################################################################
    Write-Host "`n[1/4] Removing DFS-N namespace..."
    # Remove the root consolidation namespace (#FILESVR01)
    try {
        $existingNS = Get-DfsnRoot -Path $nsPath -ErrorAction SilentlyContinue
        if ($existingNS) {
            Remove-DfsnRoot -Path $nsPath -Force
            Write-Host "  DFS namespace removed: $nsPath"
        }
    } catch {
        Write-Host "  DFS namespace not found (already removed)."
    }
    Remove-SmbShare -Name $nsName -Force -ErrorAction SilentlyContinue
    Write-Host "  Share '$nsName' removed."

    # Also clean up any old flat-style namespace
    $oldNsPath = "\\${FileServerName}\${FileShareName}"
    try { Remove-DfsnRoot -Path $oldNsPath -Force -ErrorAction SilentlyContinue } catch {}
    Remove-SmbShare -Name $FileShareName -Force -ErrorAction SilentlyContinue

    ###########################################################################
    # 2. Remove OptionalNames and DisableStrictNameChecking
    ###########################################################################
    Write-Host "`n[2/4] Removing OptionalNames..."
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"
    Remove-ItemProperty -Path $regPath -Name OptionalNames -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $regPath -Name DisableStrictNameChecking -Force -ErrorAction SilentlyContinue
    Write-Host "  OptionalNames and DisableStrictNameChecking removed."

    ###########################################################################
    # 3. Remove cifs/FILESVR01 SPNs from DFSN01 (this server can modify
    #    its own AD object). FILESVR01 HOST SPN restoration is done by
    #    toggle.ps1 on the DC which has full AD admin rights.
    ###########################################################################
    Write-Host "`n[3/4] Removing cifs SPNs from $dfsnShortName..."
    $spnsToRemove = @(
        "cifs/${FileServerName}",
        "cifs/${FileServerName}.${domain}"
    )
    foreach ($spn in $spnsToRemove) {
        $check = setspn -Q $spn 2>&1 | Out-String
        if ($check -match $dfsnShortName) {
            $out = setspn -D $spn $dfsnShortName 2>&1 | Out-String
            Write-Host "  Removed from ${dfsnShortName}: $spn"
        }
    }

    ###########################################################################
    # 4. Restart LanmanServer
    ###########################################################################
    Write-Host "`n[4/4] Restarting LanmanServer..."
    try {
        Restart-Service LanmanServer -Force -ErrorAction Stop
        Start-Sleep -Seconds 3
        Write-Host "  LanmanServer restarted."
    } catch {
        Write-Host "  LanmanServer restart failed (active sessions). Registry changes take effect on next reboot."
    }

    Write-Host "`n========================================"
    Write-Host "  DFS-N Removed - Direct Access Restored!"
    Write-Host "========================================"
    Write-Host "DNS A record : ${FileServerName}.${domain} -> $FileServerIp"
    Write-Host ""
    Write-Host "Users accessing \\${FileServerName}\${FileShareName}"
    Write-Host "  -> Goes directly to file server at $FileServerIp"
    Write-Host "========================================"
}
