# DFS-N Root Consolidation Lab: Azure Files Migration

This lab demonstrates **DFS Namespace root consolidation** to transparently migrate
an SMB file share from a Windows VM to Azure Files. Users continue accessing
`\\FILESVR01\share` — the backend flips from a local VM share to an Azure File Share
without changing the UNC path.

## Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│  VNet: 10.0.0.0/16                                               │
│                                                                   │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │ DNS01 (DC/DNS)  │  │ FILESVR01       │  │ DFSN01          │  │
│  │ 10.0.1.4        │  │ 10.0.1.5        │  │ 10.0.1.7        │  │
│  │ AD DS + DNS     │  │ SMB share       │  │ DFS-N role      │  │
│  │                 │  │ (legacy)        │  │ Root consol.    │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘  │
│                                                                   │
│  ┌─────────────────┐  ┌─────────────────┐                       │
│  │ CLIENT01        │  │ Storage Private │                       │
│  │ 10.0.1.6        │  │ Endpoint        │                       │
│  │ Windows 11      │  │ (snet-pe)       │                       │
│  │ Validation host │  │                 │                       │
│  └─────────────────┘  └─────────────────┘                       │
│                                                                   │
│  ┌─────────────────┐                                             │
│  │ VPN Gateway     │<-- P2S VPN (172.16.0.0/24)                 │
│  │ (GatewaySubnet) │    Certificate auth                        │
│  └─────────────────┘                                             │
└───────────────────────────────────────────────────────────────────┘
         │
         v
┌─────────────────────────────────────┐
│  Azure Storage Account             │
│  AD DS auth (domain-joined)        │
│  allowSharedKeyAccess: false       │
│  publicNetworkAccess: Disabled     │
│  Private Endpoint only             │
│  Share: "share"                    │
└─────────────────────────────────────┘
```

## How Root Consolidation Works

### Before toggle (`\\FILESVR01\share` -> VM file server)

```
Client -> DNS: FILESVR01 -> A record -> 10.0.1.5
       -> SMB connect to FILESVR01 (10.0.1.5)
       -> Access C:\Shares\share on file server VM
```

### After toggle to Azure (`\\FILESVR01\share` -> Azure Files)

```
Client -> DNS: FILESVR01 -> CNAME -> DFSN01.dfslab.local -> 10.0.1.7
       -> SMB connect to DFSN01 (accepted via OptionalNames=FILESVR01)
       -> DFS root consolidation: FILESVR01 -> #FILESVR01 namespace
       -> DFS folder "share" -> referral to \\storageaccount.file.core.windows.net\share
       -> Client transparently redirected to Azure Files via Private Endpoint
       -> Kerberos auth (AD DS domain-joined storage account)
```

Key elements per [Microsoft documentation](https://learn.microsoft.com/azure/storage/files/files-manage-namespaces):
- **Standalone namespace** named `#FILESVR01` (with `#` prefix) on DFSN01
- **DNS CNAME** alias: `FILESVR01` -> `DFSN01`
- **Registry** on DFSN01: `OptionalNames=FILESVR01`, `DisableStrictNameChecking=1`, `ServerConsolidationRetry=1`
- **DFS folder** `share` under `#FILESVR01` namespace points to Azure Files UNC
- **SPN management**: `cifs/FILESVR01` on DFSN01 (not on FILESVR01) so Kerberos tickets are encrypted for the right server

## Prerequisites

- Windows machine with PowerShell 5.1+ (for certificate generation)
- [Azure CLI](https://aka.ms/install-azure-cli) (`az`) logged in (`az login`)
- Azure subscription with permissions to create resource groups, VMs, storage accounts, VPN gateways
- Sufficient quota for 4x `Standard_D4as_v7` VMs (or override with `-VmSize`)

## Quick Start

### 1. Deploy the lab

```powershell
cd dfsn
.\infra\deploy.ps1
```

You will be prompted for a VM admin password (12+ chars, upper+lower+digit+special).

The deployment takes **~35-45 minutes** (VPN Gateway is the bottleneck).

Steps performed by `deploy.ps1`:
1. Generate P2S VPN certificates (local machine)
2. Deploy Azure infrastructure via Bicep (VNet, 4 VMs, Storage+PE, DNS zone, VPN GW)
3. Install AD DS features, reboot, promote to DC, reboot
4. Wait for AD DS readiness, verify DNS forwarders
5. Update VNet DNS to the DC IP, restart all VMs
6. Domain-join file server VM + create SMB share
7. Domain-join DFS-N server VM + install DFS-N role + root consolidation registry keys
8. Domain-join client VM
9. Domain-join storage account to AD DS (Kerberos computer account)
10. Configure Kerberos realm mapping on DC and client
11. Assign storage data roles to your user identity
12. Seed Azure Files share with marker file
13. Verify client can access `\\FILESVR01\share` (direct to file server)

### 2. Connect via P2S VPN

```powershell
# Download VPN client configuration
az network vnet-gateway vpn-client generate -g rg-dfs-azurefiles-demo -n vpng-dfs-demo -o tsv
# Download the ZIP from the URL, extract, run the VPN client installer
```

Connect the VPN, then RDP into the client VM:
```
mstsc /v:10.0.1.6
# Login as: DFSLAB\azureadmin (NOT CLIENT01\azureadmin)
```

### 3. Verify initial state (file server)

From the client VM:
```powershell
dir \\FILESVR01\share
# Expected: README-fileserver.txt
```

### 4. Toggle to Azure Files

From your workstation (not the VM):
```powershell
.\scripts\client\toggle.ps1 -Target azure
```

The toggle script orchestrates changes across three VMs:

| Step | VM | What it does |
|---|---|---|
| 1 | DC (`vm-dns-01`) | Replace DNS A record with CNAME, remove HOST SPNs from FILESVR01, add cifs SPNs to DFSN01, sync kerb1 key |
| 2 | DFSN01 (`vm-dfsn-01`) | Set OptionalNames + registry, create `#FILESVR01` namespace + `share` folder, restart services |
| 3 | Client (`vm-client-01`) | Add Kerberos realm mapping for storage account |
| 4 | Client (`vm-client-01`) | Flush caches (SMB, DFS referral, DNS, Kerberos), validate `dir \\FILESVR01\share` |

### 5. Verify Azure Files access

On the client VM (RDP as `DFSLAB\azureadmin`):
```powershell
dir \\FILESVR01\share
# Expected: README-azurefiles.txt

# Verify Kerberos tickets
klist
# Should show:
#   cifs/FILESVR01 (ticket to DFSN01 via root consolidation)
#   cifs/storageaccount.file.core.windows.net (ticket to Azure Files)

# Verify DNS CNAME
Resolve-DnsName FILESVR01
# Should show: CNAME -> DFSN01.dfslab.local

# Verify DFS referral
dfsutil client referral \\FILESVR01\share

# Verify direct namespace access (bypasses root consolidation)
dir "\\DFSN01\#FILESVR01\share"
```

Or use the automated validator:
```powershell
.\scripts\client\validate.ps1
```

### 6. Toggle back to file server

From your workstation:
```powershell
.\scripts\client\toggle.ps1 -Target local
```

On the client VM, clear caches and verify:
```powershell
net use * /delete /y
dfsutil /pktflush
ipconfig /flushdns
dir \\FILESVR01\share
# Expected: README-fileserver.txt
```

> **Note:** After toggling to local, you may need to flush the DFS referral cache
> (`dfsutil /pktflush`) on the client. The toggle script does this automatically
> in step 4, but if testing manually via RDP you must do it yourself.

### 7. Tear down

```powershell
.\infra\teardown.ps1
```

## File Structure

```
infra/
  deploy.ps1              # Main orchestrator (provisions everything)
  teardown.ps1            # Deletes the resource group
  main.bicep              # Bicep template (subscription-scoped)
  modules/
    network.bicep          # VNet, subnets, NSG, NICs
    vm.bicep               # VM definition
    storage.bicep          # Storage account + PE + file share
    gateway.bicep          # VPN Gateway (AVM module)
    private-dns.bicep      # privatelink.file.core.windows.net zone
    role-assignment.bicep  # RBAC for VM managed identities on storage

scripts/
  client/
    p2svpncert-setup.ps1   # Generate P2S root+client certificates
    toggle.ps1             # Orchestrator: runs DC + DFSN + client steps
    validate.ps1           # Runs validation on client VM via az vm run-command
  vm/
    bootstrap-ad.ps1       # DC: AD DS, DNS forwarders, firewall, Azure CLI
    bootstrap-fileserver.ps1  # File server: domain-join, SMB share, firewall
    bootstrap-dfsn.ps1     # DFS-N server: domain-join, DFS-N role, registry keys
    bootstrap-client.ps1   # Client: domain-join, RSAT DFS tools
    join-storage-to-ad.ps1 # Domain-join storage account (AD computer account)
    toggle-dfsn-target.ps1 # DFS-N local config (runs on DFSN01 only)
```

## How toggle.ps1 Works

`toggle.ps1` is an orchestrator that runs on your workstation and uses
`az vm run-command invoke` to execute scripts on the correct VMs.

**Why different VMs?** `az vm run-command` executes as `NT AUTHORITY\SYSTEM`.
Each machine's SYSTEM account can only modify its own AD computer object.
Operations that modify other computers' AD objects (SPNs, passwords) must run
on the DC, which has full domain admin rights.

| Operation | Must run on | Reason |
|---|---|---|
| DNS record changes | DC | DC owns the DNS zone |
| Remove/restore HOST SPNs on FILESVR01 | DC | Modifies FILESVR01's AD object |
| Add/remove cifs SPNs on DFSN01 | DC (also done on DFSN01) | DC has full rights; DFSN01 can modify its own object |
| Sync kerb1 key to AD | DC | `Set-ADAccountPassword` modifies storage account's AD object |
| OptionalNames, DisableStrictNameChecking | DFSN01 | Local registry |
| ServerConsolidationRetry | DFSN01 | Local registry |
| Create/remove DFS namespace + folder | DFSN01 | Local DFS-N service |
| Restart LanmanServer + DFS | DFSN01 | Local services |
| Kerberos realm mapping | Client | `ksetup` is per-machine |
| Cache flush + validation | Client | Tests from the client's perspective |

## Security: "Do Not Do" List

- **No shared access keys**: `allowSharedKeyAccess: false` on the storage account
- **No SAS tokens**: All authentication is identity-based (AD DS Kerberos)
- **No public SMB exposure**: Storage account has `publicNetworkAccess: Disabled`, accessible only via Private Endpoint
- **Standalone namespace**: Root consolidation requires a standalone DFS namespace (not domain-based)
- **No storage account keys for mounting**: Kerberos tickets are obtained from the DC via the domain-joined computer account
- **No key-based Azure CLI commands**: Use `az storage share-rm list` (management plane) not `az storage share list` (data plane with keys)

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-Location` | `westus3` | Azure region |
| `-VmSize` | `Standard_D4as_v7` | VM SKU for all VMs |
| `-AdminUser` | `azureadmin` | VM/domain admin username |
| `-DomainName` | `dfslab.local` | AD domain FQDN |
| `-FileShareName` | `share` | Name of the SMB file share |
| `-StorageAccount` | *(auto-generated)* | Storage account name |
| `-SkipInfra` | `$false` | Skip Bicep deployment (reuse existing) |

## Troubleshooting

### IMPORTANT: You must use the domain account

When RDP'ing into any lab VM, log in as **`DFSLAB\azureadmin`** (domain account), NOT
`DFSN01\azureadmin` or `CLIENT01\azureadmin` (local accounts). Kerberos authentication
to Azure Files requires a domain logon session with a valid TGT.

Verify with:
```powershell
whoami
# Must show: dfslab\azureadmin (NOT dfsn01\azureadmin or client01\azureadmin)

klist
# Must show at least a krbtgt/DFSLAB.LOCAL ticket
```

If `klist` shows 0 tickets, log off and log back in as `DFSLAB\azureadmin`.

### `dir \\FILESVR01\share` fails after toggle to azure

1. **Check you are logged in as domain user** (see above)
2. Flush all caches:
   ```powershell
   net use * /delete /y
   dfsutil /pktflush
   ipconfig /flushdns
   ```
   Then **log off and back in** as `DFSLAB\azureadmin` (to get a fresh TGT).
3. Check DNS: `Resolve-DnsName FILESVR01` (should show CNAME -> DFSN01)
4. Check OptionalNames on DFSN01:
   ```powershell
   Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" | Select-Object OptionalNames, DisableStrictNameChecking
   ```
   Must show `OptionalNames: {FILESVR01}` and `DisableStrictNameChecking: 1`. If missing:
   ```powershell
   Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name OptionalNames -Value @("FILESVR01") -Type MultiString
   Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name DisableStrictNameChecking -Value 1 -Type DWord
   Restart-Service LanmanServer -Force
   ```
5. Check DFS service on DFSN01: `Get-Service Dfs` should be Running
6. Test the namespace directly (bypasses root consolidation):
   ```powershell
   dir "\\DFSN01\#FILESVR01\share"
   ```
   If this works but `dir \\FILESVR01\share` doesn't, OptionalNames is the issue.
7. Check SPNs:
   ```cmd
   setspn -Q cifs/FILESVR01
   ```
   Must show DFSN01, NOT FILESVR01. If wrong:
   ```cmd
   setspn -D HOST/FILESVR01 FILESVR01
   setspn -D HOST/FILESVR01.dfslab.local FILESVR01
   setspn -S cifs/FILESVR01 DFSN01
   setspn -S cifs/FILESVR01.dfslab.local DFSN01
   ```

### Error 1396 "The target account name is incorrect"

This means there's an **SPN conflict** -- the DC issued a Kerberos ticket for the wrong
computer account. The `HOST/FILESVR01` SPN on the file server acts as an alias for
`cifs/FILESVR01`, causing tickets to be encrypted for FILESVR01's key when they should
be encrypted for DFSN01's key.

Fix (run these on the DC or from any machine with AD admin rights):
```cmd
setspn -D HOST/FILESVR01 FILESVR01
setspn -D HOST/FILESVR01.dfslab.local FILESVR01
setspn -D RestrictedKrbHost/FILESVR01 FILESVR01
setspn -D RestrictedKrbHost/FILESVR01.dfslab.local FILESVR01
setspn -S cifs/FILESVR01 DFSN01
setspn -S cifs/FILESVR01.dfslab.local DFSN01
```
Then on the client: `klist purge`, log off and back in, retry.

### `dir \\FILESVR01\share` still shows Azure Files after toggle to local

The client has a **cached DFS referral**. Fix:
```powershell
net use * /delete /y
dfsutil /pktflush
ipconfig /flushdns
dir \\FILESVR01\share
```
If that doesn't work, restart the client VM.

### "The user name or password is incorrect" accessing Azure Files

Kerberos auth failed and Windows fell back to NTLM (which Azure Files rejects).

1. **Check you are logged in as `DFSLAB\azureadmin`** (not a local account)
2. Check Kerberos realm mapping:
   ```cmd
   ksetup
   ```
   Must show `<storageaccount>.file.core.windows.net` mapped to `DFSLAB.LOCAL`. If missing:
   ```cmd
   ksetup /addhosttorealmmap <storageaccount>.file.core.windows.net DFSLAB.LOCAL
   ```
   Then **log off and back in** (realm mappings take effect on new logon sessions).
3. Verify the AD computer account SPN:
   ```cmd
   setspn -L <storageaccount>
   ```
   Must include `cifs/<storageaccount>.file.core.windows.net`.
4. Re-sync the kerb1 key (run on DC):
   ```powershell
   $rg = "rg-dfs-azurefiles-demo"; $sa = "<storageaccount>"
   $sam = $sa; if ($sam.Length -gt 15) { $sam = $sam.Substring(0, 15) }
   Import-Module Az.Accounts, Az.Storage
   Connect-AzAccount -Identity
   New-AzStorageAccountKey -ResourceGroupName $rg -Name $sa -KeyName kerb1 | Out-Null
   $kerbKey = (Get-AzStorageAccountKey -ResourceGroupName $rg -Name $sa -ListKerbKey | Where-Object { $_.KeyName -eq 'kerb1' }).Value
   Set-ADAccountPassword -Identity "${sam}$" -NewPassword (ConvertTo-SecureString $kerbKey -AsPlainText -Force) -Reset
   ```
5. Verify storage account AD DS auth:
   ```cmd
   az storage account show -g rg-dfs-azurefiles-demo -n <storageaccount> --query "azureFilesIdentityBasedAuthentication.directoryServiceOptions" -o tsv
   ```
   Must return `AD`.

### `klist` shows 0 tickets

You either ran `klist purge` (which removes the TGT) or you logged in with a local account.
**Log off and log back in as `DFSLAB\azureadmin`.** Do not run `klist purge` during testing
-- it removes your TGT and you must re-logon to get a new one.

### Private endpoint DNS resolution

1. On any VM: `Resolve-DnsName <storageaccount>.file.core.windows.net`
2. Should return private IP (10.0.2.x range)
3. If it returns public IP, check conditional forwarder on DC:
   ```powershell
   Get-DnsServerZone -Name 'file.core.windows.net'
   ```
   If missing: `Add-DnsServerConditionalForwarderZone -Name 'file.core.windows.net' -MasterServers 168.63.129.16`

### AD DS promotion fails with "Role change is in progress"

The Windows feature installation requires a reboot before DC promotion. `deploy.ps1`
handles this by running `bootstrap-ad.ps1` twice with a reboot between. If it still
fails, run `deploy.ps1 -SkipInfra` to retry from step 3.

### LanmanServer restart fails

`az vm run-command invoke` holds an active SMB session that prevents LanmanServer from
stopping. This is expected -- the toggle script handles it gracefully. The registry
changes (OptionalNames removal/addition) take effect on the next service restart or
VM reboot. If testing manually, reboot the DFSN01 VM after toggling.


[INFO]  DFS-N root consolidation configured.
[INFO]  Waiting for DC to be ready...
[INFO]  DC is ready.

[INFO]  Validating from client VM (vm-client-01)...
  SUCCESS: \\FILESVR01\share is accessible (1 file(s)).
    - README-fileserver.txt

  --- DNS Resolution ---
  FILESVR01.dfslab.local A -> 10.0.1.5

  --- SMB Connection ---

ServerName ShareName Dialect
---------- --------- -------
FILESVR01  share     3.1.1
FILESVR01  share     3.1.1