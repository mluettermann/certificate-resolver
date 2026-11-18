# SPDX-License-Identifier: GPL-3.0-or-later
# ═══════════════════════════════════════════════════════════════
# reload-iis.ps1 — Rebind the newly imported certificate to IIS
#
# Synced to the Windows target by deploy-windows-ssh.sh (see the
# "reload_script" field in cert-targets.yml) and then run via reload_cmd,
# e.g.:  reload_cmd: "powershell -File C:\certs\reload-iis.ps1 -Domain {{DOMAIN}}"
#
# Handles both binding styles:
#   - classic (non-SNI): one cert shared by the whole ip:port
#   - SNI: one cert per hostname, but only for hosts that are exactly
#     one label under $Domain (that's all a *.$Domain wildcard covers —
#     multi-level hosts like fake.gap.$Domain are skipped on purpose)
# ═══════════════════════════════════════════════════════════════

param(
    [Parameter(Mandatory = $true)]
    [string]$Domain
)

$cert = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Subject -match [regex]::Escape($Domain) } |
    Sort-Object NotBefore -Descending |
    Select-Object -First 1

if (-not $cert) {
    Write-Error "Kein Zertifikat fuer $Domain in Cert:\LocalMachine\My gefunden"
    exit 1
}

$appId = '{00000000-0000-0000-0000-000000000000}'

# Classic (non-SNI) binding.
netsh http delete sslcert ipport=0.0.0.0:443 | Out-Null
netsh http add sslcert ipport=0.0.0.0:443 certhash=$($cert.Thumbprint) appid=$appId | Out-Null

# SNI bindings — only single-level subdomains of $Domain.
$pattern = "^[^.]+\.$([regex]::Escape($Domain))$"

Get-WebBinding -Protocol https |
    Where-Object { $_.sslFlags -eq 1 } |
    ForEach-Object {
        $hostname = ($_.bindingInformation -split ':')[2]
        if ($hostname -match $pattern) {
            netsh http delete sslcert hostnameport="${hostname}:443" | Out-Null
            netsh http add sslcert hostnameport="${hostname}:443" certhash=$($cert.Thumbprint) certstorename=MY appid=$appId | Out-Null
            Write-Output "Rebound: $hostname"
        }
    }
