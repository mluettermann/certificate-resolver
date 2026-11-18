#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ═══════════════════════════════════════════════════════════════
# setup.sh — One-time acme-dns registration per hostname
#
# Usage:
#   Wildcard certificate (example.com + *.example.com):
#     docker exec certificate-resolver /scripts/setup.sh example.com
#
#   Single / multi-name certificate (no wildcard):
#     docker exec certificate-resolver /scripts/setup.sh test.example.com www.test.example.com
#
# What it does (for every name given):
#   1. Registers a subdomain with acme-dns (skipped if already registered)
#   2. Stores the credentials in /data/acmedns-credentials.json
#      under the key _acme-challenge.<name>
#   3. Prints the CNAME record(s) to be added to the DNS zone
# ═══════════════════════════════════════════════════════════════

set -e

source /scripts/notify.sh

CREDS_FILE="/data/acmedns-credentials.json"

if [ "$#" -eq 0 ]; then
  log err "Domain required. Usage: /scripts/setup.sh example.com [www.example.com ...]"
  exit 1
fi

# Defense in depth: only allow safe domain characters (optional leading "*.").
for NAME in "$@"; do
  if ! [[ "$NAME" =~ ^(\*\.)?[A-Za-z0-9._-]+$ ]]; then
    log err "Invalid domain name: $NAME"
    exit 1
  fi
done

# Load existing credentials or create empty object
if [ ! -f "$CREDS_FILE" ]; then
  echo "{}" > "$CREDS_FILE"
fi

# Prints the fulldomain of a registered challenge key, or nothing.
_fulldomain_for() {
  python3 - "$CREDS_FILE" "$1" <<'PY'
import json, sys
e = json.load(open(sys.argv[1])).get(sys.argv[2])
if e:
    print(e['fulldomain'])
PY
}

API_READY=0
NEW_COUNT=0
declare -a KEYS=()
declare -a TARGETS=()
declare -A SEEN=()

for NAME in "$@"; do
  # A wildcard name is validated via the challenge of its base domain.
  BASE="${NAME#\*.}"
  KEY="_acme-challenge.$BASE"
  [ -n "${SEEN[$KEY]}" ] && continue
  SEEN[$KEY]=1

  FULLDOMAIN=$(_fulldomain_for "$KEY")

  if [ -n "$FULLDOMAIN" ]; then
    log info "Domain '$BASE' is already registered."
  else
    if [ "$API_READY" -eq 0 ]; then
      log info "Waiting for acme-dns API..."
      until curl -sf http://localhost:8080/health > /dev/null 2>&1; do sleep 1; done
      log info "acme-dns ready."
      API_READY=1
    fi

    log info "Registering new subdomain for '$BASE'..."
    RESPONSE=$(curl -sf -X POST http://localhost:8080/register)

    if [ -z "$RESPONSE" ]; then
      log err "No response from acme-dns."
      exit 1
    fi

    # Merge new entry into existing credentials file, print its fulldomain
    FULLDOMAIN=$(python3 - "$CREDS_FILE" "$KEY" "$RESPONSE" <<'PY'
import json, sys
path, key, response = sys.argv[1:4]
data = json.load(open(path))
entry = json.loads(response)
data[key] = entry
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
print(entry['fulldomain'])
PY
)
    log info "Credentials saved to $CREDS_FILE"
    NEW_COUNT=$((NEW_COUNT + 1))
  fi

  KEYS+=("$KEY")
  TARGETS+=("$FULLDOMAIN")
done

# Sync to acme.sh data directory
mkdir -p "${ACME_DATA:-/data/acme}" && cp "$CREDS_FILE" "${ACME_DATA:-/data/acme}/acmedns.json"

_print_records() {
  local i
  for i in "${!KEYS[@]}"; do
    echo "  ${KEYS[$i]}"
    echo "      CNAME  ${TARGETS[$i]}"
  done
}

# ── Output ───────────────────────────────────────────────────────
if [ "$#" -eq 1 ]; then
  DOMAIN="${1#\*.}"
  if [ "$NEW_COUNT" -eq 0 ]; then
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  CNAME record (set this in your DNS zone if not done yet):"
    echo ""
    _print_records
    echo "════════════════════════════════════════════════════════════"
    exit 0
  fi
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "  ADD THIS RECORD TO YOUR DNS ZONE (one-time for $DOMAIN):"
  echo ""
  _print_records
  echo ""
  echo "  Set ONLY the CNAME — no TXT records for _acme-challenge.$DOMAIN!"
  echo "  Direct TXT records override the CNAME and will break validation."
  echo ""
  echo "  After DNS propagation (~5-10 min), run:"
  echo "  docker exec certificate-resolver /scripts/issue.sh $DOMAIN"
  echo "  (or, for a certificate without wildcard:"
  echo "   docker exec certificate-resolver /scripts/issue.sh --san $DOMAIN)"
  echo "════════════════════════════════════════════════════════════"
  exit 0
fi

echo ""
echo "════════════════════════════════════════════════════════════"
if [ "$NEW_COUNT" -eq 0 ]; then
  echo "  CNAME records (set these in your DNS zone if not done yet):"
else
  echo "  ADD THESE RECORDS TO YOUR DNS ZONE (one-time per name):"
fi
echo ""
_print_records
echo ""
echo "  Set ONLY the CNAMEs — no TXT records for these _acme-challenge names!"
echo "  Direct TXT records override the CNAME and will break validation."
echo ""
echo "  After DNS propagation (~5-10 min), run:"
echo "  docker exec certificate-resolver /scripts/issue.sh --san $*"
echo "════════════════════════════════════════════════════════════"
