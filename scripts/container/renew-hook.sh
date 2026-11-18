#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ═══════════════════════════════════════════════════════════════
# renew-hook.sh — PFX export and certificate distribution
#
# Called automatically by acme.sh after every issuance or renewal.
# Do not invoke manually.
#
# acme.sh sets $CERTDOMAIN to the renewed domain.
#
# PFX_PASSWORD is generated fresh on every run (not read from .env) —
# a new random password every issuance/renewal, handed to the deployers
# only via the exported environment variable for the lifetime of this
# process. Nothing writes it to disk; it exists only in memory between
# "Create PFX" below and the deploy.sh call, and is gone as soon as this
# script exits (each renewal runs renew-hook.sh as a fresh process, so
# there's nothing to unset for the next run either). windows-ssh consumes
# it in-process to import the certificate and never persists it;
# sftp-drop writes it next to the dropped PFX for the fetching host.
# ═══════════════════════════════════════════════════════════════

set -e

source /scripts/notify.sh

DOMAIN="${CERTDOMAIN}"
# 32-character password: cryptographically random mix of alphanumeric + special chars.
# Handed to openssl via "-passout env:PFX_PASSWORD" (not "pass:...") so it
# never appears in the container's process list.
export PFX_PASSWORD="$(python3 -c "import secrets, string; chars = string.ascii_letters + string.digits + '!@#%^&*-_+=.'; print(''.join(secrets.choice(chars) for _ in range(32)))")"
CERT_DIR="/certs/$DOMAIN"
IS_RENEWAL="${1:-auto}"   # "auto" when called by acme.sh, "initial" when called by issue.sh

# ── Error handling ───────────────────────────────────────────────
_on_error() {
  local EXIT_CODE=$?
  local LINE=$1
  local STEP="${CURRENT_STEP:-Unknown step}"
  local ERROR_MSG="Error in '$STEP' at line $LINE (exit code: $EXIT_CODE)"
  log err "$ERROR_MSG"
  notify_error "$STEP" "$DOMAIN" "$ERROR_MSG"
  exit $EXIT_CODE
}
trap '_on_error $LINENO' ERR

if [ -z "$DOMAIN" ]; then
  log err "CERTDOMAIN is not set."
  exit 1
fi

if [ ! -f "$CERT_DIR/fullchain.pem" ] || [ ! -f "$CERT_DIR/privkey.pem" ]; then
  log warning "Certificate files for '$DOMAIN' not found, skipping."
  exit 0
fi

# ── Create PFX ───────────────────────────────────────────────────
CURRENT_STEP="Create PFX"
log info "Creating PFX for $DOMAIN..."

openssl pkcs12 -export \
  -in    "$CERT_DIR/fullchain.pem" \
  -inkey "$CERT_DIR/privkey.pem" \
  -out   "$CERT_DIR/certificate.pfx" \
  -passout env:PFX_PASSWORD \
  -name  "$DOMAIN"

chmod 600 "$CERT_DIR/certificate.pfx"
log info "PFX created: $CERT_DIR/certificate.pfx"

# ── Legacy-compatible PFX (older Windows, e.g. Server 2016) ──────
# -certpbe/-keypbe/-macalg force the legacy RC2/3DES-SHA1 PKCS#12 encryption.
# OpenSSL 3.x defaults to AES-256+SHA-256 (PBES2), which older Windows
# CryptoAPI can't parse — Import-PfxCertificate then fails with a misleading
# "wrong password or AD principal" error even though the password is correct.
# Only transferred to targets that opt in via "legacy_pfx: true" in
# cert-targets.yml (see deploy-windows-ssh.sh), so hosts that support the
# modern scheme keep the stronger certificate.pfx above.
openssl pkcs12 -export \
  -in    "$CERT_DIR/fullchain.pem" \
  -inkey "$CERT_DIR/privkey.pem" \
  -out   "$CERT_DIR/certificate-legacy.pfx" \
  -passout env:PFX_PASSWORD \
  -name  "$DOMAIN" \
  -certpbe PBE-SHA1-3DES \
  -keypbe PBE-SHA1-3DES \
  -macalg SHA1

chmod 600 "$CERT_DIR/certificate-legacy.pfx"
log info "Legacy-compatible PFX created: $CERT_DIR/certificate-legacy.pfx"

# ── Renewal notification (automatic renewals only) ───────────────
if [ "$IS_RENEWAL" = "auto" ]; then
  EXPIRY=$(openssl x509 -in "$CERT_DIR/cert.pem" -noout -enddate 2>/dev/null | cut -d= -f2)
  log info "Renewed: $DOMAIN — expires ${EXPIRY:-unknown}"
  notify_cert_renewed "$DOMAIN" "$EXPIRY"
fi

# ── Distribute certificates via cert-targets.yml ─────────────────
# IMPORTANT: distribution must NOT fail the issuance/renewal. The certificate
# is already valid at this point; a single unreachable deploy target should
# not mark the whole run as failed nor trigger cascading error mails.
# Per-target failures are reported individually by the deployer scripts.
# Running inside "if" keeps the ERR trap (set -e) from aborting the hook.
CURRENT_STEP="Certificate distribution"
if /scripts/deploy.sh; then
  log info "[$DOMAIN] Certificate distribution completed."
else
  log warning "[$DOMAIN] Certificate distribution finished with errors — the certificate itself is valid. See the per-target messages above."
fi

# Deployment is done — the process holding PFX_PASSWORD in memory ends here.
unset PFX_PASSWORD

log info "$DOMAIN — Completed: $(date '+%Y-%m-%d %H:%M:%S')"

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | system | renew_hook | $DOMAIN" >> /data/audit.log
