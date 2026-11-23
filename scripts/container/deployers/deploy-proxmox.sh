#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ═══════════════════════════════════════════════════════════════
# deployers/deploy-proxmox.sh — Certificate deployment for Proxmox VE
#
# Copies fullchain.pem and privkey.pem to the fixed certificate
# paths required by Proxmox VE and restarts pveproxy.
#
# Proxmox certificate paths (fixed, not configurable):
#   /etc/pve/local/pveproxy-ssl.pem  ← fullchain
#   /etc/pve/local/pveproxy-ssl.key  ← private key
#
# Note: /etc/pve is a FUSE-based cluster filesystem (pmxcfs).
# File writes are replicated to all cluster nodes automatically.
#
# Called by deploy.sh:
#   deploy-proxmox.sh <domain> <path-to-target-json-file>
# ═══════════════════════════════════════════════════════════════

set -eo pipefail
source /scripts/notify.sh

DOMAIN="$1"
TARGET_FILE="$2"
CERT_DIR="/certs/$DOMAIN"

if [ -z "$DOMAIN" ] || [ -z "$TARGET_FILE" ] || [ ! -f "$TARGET_FILE" ]; then
  log err "deploy-proxmox.sh: Usage: deploy-proxmox.sh <domain> <target-json-file>"
  exit 1
fi

# ── Read target fields ───────────────────────────────────────────
_field() {
  local key="$1"
  local default="${2:-}"
  python3 -c "
import json, sys
d = json.load(open('$TARGET_FILE'))
val = d.get('$key', '$default')
print(val if val is not None else '$default')
"
}

HOST=$(_field host)
USER=$(_field user root)
PORT=$(_field port 22)
KEY=$(_field key /data/ssh/id_ed25519)

if [ -z "$HOST" ]; then
  log err "[$DOMAIN] deploy-proxmox.sh: 'host' is missing in target configuration."
  exit 1
fi

PVE_CERT="/etc/pve/local/pveproxy-ssl.pem"
PVE_KEY="/etc/pve/local/pveproxy-ssl.key"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -i $KEY -p $PORT"

# Address family for ssh/scp: any (default) | inet (IPv4 only) | inet6 (IPv6 only).
# Per target via "address_family", global default via SSH_ADDRESS_FAMILY.
# Needed when a host's A record points somewhere else than its AAAA record
# (e.g. IPv4 only reaches an HTTP(S) proxy) — without it, the container's
# resolver prefers IPv4 because the compose network uses a ULA IPv6 subnet.
ADDRESS_FAMILY=$(_field address_family "${SSH_ADDRESS_FAMILY:-any}")
case "$ADDRESS_FAMILY" in
  any|inet|inet6) ;;
  *)
    log err "[$DOMAIN] Invalid address_family '$ADDRESS_FAMILY' (allowed: any, inet, inet6)."
    exit 1
    ;;
esac
SSH_OPTS="$SSH_OPTS -o AddressFamily=$ADDRESS_FAMILY"
if [ "$ADDRESS_FAMILY" != "any" ]; then
  log info "[$DOMAIN → $HOST] SSH address family: $ADDRESS_FAMILY"
fi

# ── Error handling ───────────────────────────────────────────────
_on_error() {
  local EXIT_CODE=$?
  local LINE=$1
  log err "[$DOMAIN → Proxmox:$HOST] Error at line $LINE (exit code: $EXIT_CODE)"
  exit $EXIT_CODE
}
trap '_on_error $LINENO' ERR

# ── Transfer certificates ────────────────────────────────────────
log info "[$DOMAIN → Proxmox:$HOST] Transferring certificates..."

# SCP to a temp location first — /etc/pve is a FUSE filesystem
# that doesn't support direct SCP writes on some Proxmox versions
ssh $SSH_OPTS "$USER@$HOST" "mkdir -p /tmp/cert-update"

scp -P "$PORT" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o AddressFamily="$ADDRESS_FAMILY" \
    -i "$KEY" \
    "$CERT_DIR/fullchain.pem" \
    "$CERT_DIR/privkey.pem" \
    "$USER@$HOST:/tmp/cert-update/"

# Move into place via SSH (cp preserves pmxcfs semantics)
ssh $SSH_OPTS "$USER@$HOST" "
  cp /tmp/cert-update/fullchain.pem $PVE_CERT &&
  cp /tmp/cert-update/privkey.pem   $PVE_KEY  &&
  chmod 640 $PVE_CERT $PVE_KEY                &&
  rm -rf /tmp/cert-update
"

log info "[$DOMAIN → Proxmox:$HOST] Certificates installed."

# ── Restart pveproxy ─────────────────────────────────────────────
log info "[$DOMAIN → Proxmox:$HOST] Restarting pveproxy..."
ssh $SSH_OPTS "$USER@$HOST" "systemctl restart pveproxy"
log info "[$DOMAIN → Proxmox:$HOST] pveproxy restarted — certificate active."
