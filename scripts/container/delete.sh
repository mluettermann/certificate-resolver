#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ═══════════════════════════════════════════════════════════════
# delete.sh — Completely remove a domain from the resolver
#
# Usage: docker exec certificate-resolver /scripts/delete.sh example.com
#
# For a multi-name (--san) certificate pass its primary name (the first
# name used with issue.sh --san).
#
# What it does:
#   1. Removes the acme-dns credentials entries (_acme-challenge.<name>)
#      of the domain and of every other name in its certificate — except
#      entries still used by another certificate
#   2. Refreshes the acme.sh credentials copy
#   3. Deletes the certificate files (/certs/<domain>)
#   4. Deletes the acme.sh data dir (<ACME_DATA>/<domain>)
#
# NOTE: the distribution config in cert-targets.yml is handled by the
# web UI, not by this script.
# ═══════════════════════════════════════════════════════════════

set -e

source /scripts/notify.sh

DOMAIN="${1}"
CREDS_FILE="/data/acmedns-credentials.json"
ACME_DATA="${ACME_DATA:-/data/acme}"
CERT_DIR="/certs/$DOMAIN"

if [ -z "$DOMAIN" ]; then
  log err "Domain required. Usage: /scripts/delete.sh example.com"
  exit 1
fi

# Defense in depth: only allow safe domain characters.
if ! echo "$DOMAIN" | grep -qE '^[a-zA-Z0-9._-]+$'; then
  log err "Invalid domain name: $DOMAIN"
  exit 1
fi

log info "Deleting domain '$DOMAIN'..."

# 1. Remove credentials entries + refresh acme.sh copy
#    (must run before the acme.sh data dir is removed: the names of the
#    certificate are read from its <domain>.conf)
if [ -f "$CREDS_FILE" ]; then
  RESULT=$(python3 - "$CREDS_FILE" "$ACME_DATA" "$DOMAIN" <<'PY'
import glob, json, os, re, sys

creds_path, acme_data, domain = sys.argv[1:4]

def challenge_keys(conf):
    """Challenge keys (_acme-challenge.<name>) of all names in an acme.sh domain conf."""
    vals = {}
    try:
        for line in open(conf):
            m = re.match(r"^(Le_Domain|Le_Alt)='(.*)'$", line.strip())
            if m:
                vals[m.group(1)] = m.group(2)
    except OSError:
        return set()
    keys = set()
    for v in (vals.get('Le_Domain', ''), vals.get('Le_Alt', '')):
        for n in v.split(','):
            n = n.strip()
            if n and n != 'no':
                keys.add('_acme-challenge.' + (n[2:] if n.startswith('*.') else n))
    return keys

own_dirs = {os.path.join(acme_data, domain), os.path.join(acme_data, domain + '_ecc')}
own = {'_acme-challenge.' + domain}
for d in own_dirs:
    own |= challenge_keys(os.path.join(d, domain + '.conf'))

# Names still used by other certificates keep their registration.
in_use = set()
for conf in glob.glob(os.path.join(acme_data, '*', '*.conf')):
    d = os.path.dirname(conf)
    if d in own_dirs:
        continue
    name = os.path.basename(d)
    dom = name[:-4] if name.endswith('_ecc') else name
    if os.path.basename(conf) == dom + '.conf':
        in_use |= challenge_keys(conf)

data = json.load(open(creds_path))
for key in sorted(own):
    if key in in_use:
        print('kept\t' + key)
    elif data.pop(key, None) is not None:
        print('removed\t' + key)
json.dump(data, open(creds_path, 'w'), indent=2)
PY
)
  while IFS=$'\t' read -r ACTION KEY; do
    case "$ACTION" in
      removed) log info "  removed acme-dns entry: $KEY" ;;
      kept)    log info "  kept acme-dns entry (still used by another certificate): $KEY" ;;
    esac
  done <<< "$RESULT"
  mkdir -p "$ACME_DATA" && cp "$CREDS_FILE" "$ACME_DATA/acmedns.json"
fi

# 2. Remove certificate files
if [ -d "$CERT_DIR" ]; then
  rm -rf "$CERT_DIR"
  log info "  removed certificates: $CERT_DIR"
fi

# 3. Remove acme.sh per-domain data
if [ -d "$ACME_DATA/$DOMAIN" ]; then
  rm -rf "$ACME_DATA/$DOMAIN"
  log info "  removed acme.sh data: $ACME_DATA/$DOMAIN"
fi

log info "Domain '$DOMAIN' deleted."
