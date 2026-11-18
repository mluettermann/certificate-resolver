#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ═══════════════════════════════════════════════════════════════
# issue.sh — Issue a certificate for a domain
#
# Usage:
#   Wildcard certificate (example.com + *.example.com):
#     docker exec certificate-resolver /scripts/issue.sh example.com
#
#   Single / multi-name certificate without wildcard (SAN):
#     docker exec certificate-resolver /scripts/issue.sh --san test.example.com www.test.example.com
#   The first name is the primary name: it names the certificate
#   directory (/certs/<primary>/) and the entry in cert-targets.yml.
#
# Prerequisites:
#   - setup.sh has been run for this domain (with --san: for every name)
#   - The CNAME record(s) have propagated in DNS
#
# Output in /certs/<domain>/ (= ./certs/<domain>/ on the host):
#   fullchain.pem   → Linux (nginx, Apache, HAProxy, Traefik)
#   privkey.pem     → Private key
#   cert.pem        → Certificate only
#   certificate.pfx → IIS (Windows) — import via MMC or PowerShell
# ═══════════════════════════════════════════════════════════════

set -e

source /scripts/notify.sh

MODE="wildcard"
if [ "$1" = "--san" ] || [ "$1" = "--no-wildcard" ]; then
  MODE="san"
  shift
fi

DOMAIN="${1}"
PFX_PASSWORD="${PFX_PASSWORD:-ChangeMeSecure123!}"
CREDS_FILE="/data/acmedns-credentials.json"
CERT_DIR="/certs/$DOMAIN"
ACME_DATA="${ACME_DATA:-/data/acme}"
CURRENT_STEP="Initialization"

# ── Error handling ───────────────────────────────────────────────
_on_error() {
  local EXIT_CODE=$?
  local LINE=$1
  local ERROR_MSG="Error in '$CURRENT_STEP' at line $LINE (exit code: $EXIT_CODE)"
  log err "$ERROR_MSG"
  notify_error "Certificate issuance" "$DOMAIN" "$ERROR_MSG"
  exit $EXIT_CODE
}
trap '_on_error $LINENO' ERR

# ── Input validation ─────────────────────────────────────────────
if [ -z "$DOMAIN" ]; then
  log err "Domain required. Usage: /scripts/issue.sh example.com"
  log err "               or: /scripts/issue.sh --san name1.example.com [name2.example.com ...]"
  exit 1
fi

# Defense in depth: only allow safe domain characters. The primary name
# becomes a directory name, so it must never be a wildcard.
if ! [[ "$DOMAIN" =~ ^[A-Za-z0-9._-]+$ ]]; then
  log err "Invalid domain name: $DOMAIN (the first name must not be a wildcard)"
  exit 1
fi

# List of certificate names (deduplicated, order preserved)
declare -a NAMES=()
if [ "$MODE" = "wildcard" ]; then
  if [ "$#" -gt 1 ]; then
    log err "Several names given. For a certificate without wildcard use: /scripts/issue.sh --san $*"
    exit 1
  fi
  NAMES=("$DOMAIN" "*.$DOMAIN")
else
  declare -A _SEEN=()
  for NAME in "$@"; do
    if ! [[ "$NAME" =~ ^(\*\.)?[A-Za-z0-9._-]+$ ]]; then
      log err "Invalid domain name: $NAME"
      exit 1
    fi
    [ -n "${_SEEN[$NAME]}" ] && continue
    _SEEN[$NAME]=1
    NAMES+=("$NAME")
  done
fi

if [ ! -f "$CREDS_FILE" ]; then
  MSG="No credentials found. Run first: /scripts/setup.sh ${NAMES[*]}"
  [ "$MODE" = "wildcard" ] && MSG="No credentials found. Run first: /scripts/setup.sh $DOMAIN"
  log err "$MSG"
  notify_error "Certificate issuance" "$DOMAIN" "$MSG"
  exit 1
fi

# Every name needs an acme-dns registration for its challenge record
# (wildcard mode: only _acme-challenge.<domain>, shared by both names).
MISSING=$(python3 - "$CREDS_FILE" "${NAMES[@]}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
missing = []
for name in sys.argv[2:]:
    base = name[2:] if name.startswith('*.') else name
    if '_acme-challenge.' + base not in data and base not in missing:
        missing.append(base)
print(' '.join(missing))
PY
)

if [ -n "$MISSING" ]; then
  if [ "$MODE" = "wildcard" ]; then
    MSG="Domain '$DOMAIN' not registered. Run first: /scripts/setup.sh $DOMAIN"
  else
    MSG="Not registered: $MISSING. Run first: /scripts/setup.sh $MISSING"
  fi
  log err "$MSG"
  notify_error "Certificate issuance" "$DOMAIN" "$MSG"
  exit 1
fi

# ── Load acme-dns credentials for acme.sh ───────────────────────
CURRENT_STEP="Loading credentials"
export ACMEDNS_BASE_URL="http://localhost:8080"

if [ "$MODE" = "wildcard" ]; then
  # Stock dns_acmedns hook: one acme-dns account for both names.
  DNS_HOOK="dns_acmedns"
  export ACMEDNS_USERNAME=$(python3 -c "import json; d=json.load(open('$CREDS_FILE')); print(d['_acme-challenge.$DOMAIN']['username'])")
  export ACMEDNS_PASSWORD=$(python3 -c "import json; d=json.load(open('$CREDS_FILE')); print(d['_acme-challenge.$DOMAIN']['password'])")
  export ACMEDNS_SUBDOMAIN=$(python3 -c "import json; d=json.load(open('$CREDS_FILE')); print(d['_acme-challenge.$DOMAIN']['subdomain'])")
else
  # dns_acmedns_multi looks up the account per name in the credentials
  # file (acme-dns keeps only 2 TXT values per account).
  DNS_HOOK="dns_acmedns_multi"
  export ACMEDNS_CREDS_FILE="$CREDS_FILE"
fi

# Persist credentials to acme.sh data directory
mkdir -p "$ACME_DATA"
cp "$CREDS_FILE" "$ACME_DATA/acmedns.json"

# Remove any stale domain state from previous runs
rm -rf "$ACME_DATA/$DOMAIN"

# ── Issue certificate ────────────────────────────────────────────
CURRENT_STEP="acme.sh --issue"
NAMES_TEXT=$(printf '%s, ' "${NAMES[@]}")
NAMES_TEXT="${NAMES_TEXT%, }"
log info "Requesting certificate for $NAMES_TEXT"

declare -a DOMAIN_ARGS=()
for NAME in "${NAMES[@]}"; do
  DOMAIN_ARGS+=(-d "$NAME")
done

# Capture acme.sh output for error reporting (EXIT trap cleans up)
_ACME_TMP=$(mktemp)
trap 'rm -f "$_ACME_TMP"' EXIT

set +e
acme.sh \
  --home "$ACME_DATA" \
  "${ACME_DEBUG_ARGS[@]}" \
  --issue \
  --server letsencrypt \
  "${DOMAIN_ARGS[@]}" \
  --dns "$DNS_HOOK" \
  --keylength 2048 \
  --dnssleep 120 \
  2>&1 | tee "$_ACME_TMP"
_ACME_EXIT=${PIPESTATUS[0]}
set -e

if [ "$_ACME_EXIT" -ne 0 ]; then
  log err "acme.sh --issue failed (exit code: $_ACME_EXIT). Last output:"
  tail -20 "$_ACME_TMP" | while IFS= read -r line; do
    [ -n "$line" ] && log err "[acme.sh] $line"
  done
  notify_error "Certificate issuance" "$DOMAIN" \
    "acme.sh --issue failed (exit code: $_ACME_EXIT) — see Docker logs for details"
  exit "$_ACME_EXIT"
fi

log info "Certificate issued, installing to $CERT_DIR"

# ── Install certificate ──────────────────────────────────────────
# --reloadcmd is executed immediately by acme.sh (creates PFX + triggers deploy)
# and again on every automatic renewal — no separate renew-hook wiring needed.
CURRENT_STEP="acme.sh --install-cert"
mkdir -p "$CERT_DIR"

acme.sh \
  --home "$ACME_DATA" \
  "${ACME_DEBUG_ARGS[@]}" \
  --install-cert \
  -d "$DOMAIN" \
  --cert-file      "$CERT_DIR/cert.pem" \
  --key-file       "$CERT_DIR/privkey.pem" \
  --fullchain-file "$CERT_DIR/fullchain.pem" \
  --reloadcmd      "CERTDOMAIN=$DOMAIN /scripts/renew-hook.sh"

# ── Success notification ─────────────────────────────────────────
EXPIRY=$(openssl x509 -in "$CERT_DIR/cert.pem" -noout -enddate 2>/dev/null | cut -d= -f2)
notify_cert_issued "$DOMAIN" "$EXPIRY"

log info "Done: $DOMAIN ($NAMES_TEXT) — expires $EXPIRY"
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  DONE! Certificate files in ./certs/$DOMAIN/:"
echo ""
echo "  fullchain.pem   → Linux (nginx, Apache, Traefik, HAProxy)"
echo "  privkey.pem     → Private key"
echo "  certificate.pfx → IIS import (Windows)"
echo ""
echo "  Valid for: $NAMES_TEXT"
echo "  Expires:   $EXPIRY"
echo "════════════════════════════════════════════════════════════"
