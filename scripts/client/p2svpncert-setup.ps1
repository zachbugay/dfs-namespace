<#
.SYNOPSIS
    Generate or reuse self-signed root and client certificates for P2S VPN.
    Outputs the base64-encoded root certificate public key for use in Bicep.

.DESCRIPTION
    - Checks if a root cert with the given subject already exists in CurrentUser\My.
    - If not, creates a self-signed root cert and a client cert signed by it.
    - Exports the root cert public key as base64 (no BEGIN/END lines) for Bicep.
    - The client cert is automatically installed and usable by the VPN client.

.PARAMETER RootCertSubject
    CN subject for the root certificate.

.PARAMETER ClientCertSubject
    CN subject for the client certificate.

.OUTPUTS
    Writes the base64 root cert data to stdout (captured by deploy.ps1).
#>
param(
    [string]$RootCertSubject  = "CN=DFSLabP2SRootCert",
    [string]$ClientCertSubject = "CN=DFSLabP2SClientCert"
)

$ErrorActionPreference = "Stop"

# PowerShell 7+ needs the PKI module from Windows PowerShell
if ($PSVersionTable.PSVersion.Major -ge 6) {
    Import-Module -Name PKI -UseWindowsPowerShell -ErrorAction SilentlyContinue
}

###############################################################################
# Check for existing root cert
###############################################################################
$rootCert = Get-ChildItem -Path Cert:\CurrentUser\My |
    Where-Object { $_.Subject -eq $RootCertSubject -and $_.NotAfter -gt (Get-Date) } |
    Select-Object -First 1

if ($rootCert) {
    Write-Host "[INFO] Existing root cert found: $($rootCert.Thumbprint)" -ForegroundColor Cyan
} else {
    Write-Host "[INFO] Creating root certificate: $RootCertSubject" -ForegroundColor Cyan
    $rootCert = New-SelfSignedCertificate `
        -Type Custom `
        -KeySpec Signature `
        -Subject $RootCertSubject `
        -KeyExportPolicy Exportable `
        -HashAlgorithm sha256 `
        -KeyLength 2048 `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -KeyUsageProperty Sign `
        -KeyUsage CertSign `
        -NotAfter (Get-Date).AddYears(3)
    Write-Host "[INFO] Root cert created: $($rootCert.Thumbprint)" -ForegroundColor Cyan
}

###############################################################################
# Check for existing client cert signed by this root
###############################################################################
$clientCert = Get-ChildItem -Path Cert:\CurrentUser\My |
    Where-Object { $_.Subject -eq $ClientCertSubject -and $_.Issuer -eq $RootCertSubject -and $_.NotAfter -gt (Get-Date) } |
    Select-Object -First 1

if ($clientCert) {
    Write-Host "[INFO] Existing client cert found: $($clientCert.Thumbprint)" -ForegroundColor Cyan
} else {
    Write-Host "[INFO] Creating client certificate: $ClientCertSubject" -ForegroundColor Cyan
    $clientCert = New-SelfSignedCertificate `
        -Type Custom `
        -DnsName "DFSLabP2SClient" `
        -KeySpec Signature `
        -Subject $ClientCertSubject `
        -KeyExportPolicy Exportable `
        -HashAlgorithm sha256 `
        -KeyLength 2048 `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -Signer $rootCert `
        -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.2") `
        -NotAfter (Get-Date).AddYears(3)
    Write-Host "[INFO] Client cert created: $($clientCert.Thumbprint)" -ForegroundColor Cyan
}

###############################################################################
# Export root cert public key as base64 (for Bicep clientRootCertData)
###############################################################################
$rawBytes = $rootCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
$base64 = [System.Convert]::ToBase64String($rawBytes)

Write-Host "[INFO] Root cert base64 length: $($base64.Length) chars" -ForegroundColor Cyan
# Output just the base64 string on its own line for capture
Write-Output $base64