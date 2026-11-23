#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ═══════════════════════════════════════════════════════════════
# deployers/deploy-esxi.sh — Certificate deployment for VMware ESXi
# (Host Client management UI)
#
# Copies fullchain.pem and privkey.pem to the fixed certificate paths
# ESXi's management stack reads (rhttpproxy/hostd behind the Host
# Client on :443), then restarts hostd (and vpxa, if the host is
# managed by vCenter) to pick them up. No full reboot needed.
#
# ESXi certificate paths (fixed, not configurable):
#   /etc/vmware/ssl/rui.crt  ← fullchain (leaf + intermediates — ESXi
#                               6.0+ accepts the full chain here, not
#                               just the leaf)
#   /etc/vmware/ssl/rui.key  ← private key, MUST be unencrypted
#                               (acme.sh's privkey.pem already is)
#
# Requires SSH enabled on the host (Host Client → Actions → Services →
# Enable Secure Shell (SSH), or via DCUI) and normally the "root" user —
# ESXi has no separate deploy account by default.
#
# The previous rui.crt/rui.key are copied to rui.crt.bak/rui.key.bak
# before being overwritten (best-effort — a fresh host may not have
# them yet, that's not an error), so there's a rollback copy on the
# host itself.
#
# Caveat: if this host is managed by vCenter, vCenter may show it as
# "certificate not verified" / briefly disconnected after the swap
# until it re-validates the thumbprint — that's a vCenter-side
# reconnect and out of scope here. vpxa is still restarted below since
# that's what VMware's own docs call for; its failure is logged as a
# warning, not fatal (harmless no-op on a standalone host).
#
# Called by deploy.sh:
#   deploy-esxi.sh <domain> <path-to-target-json-file>
# ═══════════════════════════════════════════════════════════════

set -eo pipefail
source /scripts/notify.sh

DOMAIN="$1"
TARGET_FILE="$2"
CERT_DIR="/certs/$DOMAIN"

if [ -z "$DOMAIN" ] || [ -z "$TARGET_FILE" ] || [ ! -f "$TARGET_FILE" ]; then
  log err "deploy-esxi.sh: Usage: deploy-esxi.sh <domain> <target-json-file>"
  exit 1
fi

for f in fullchain.pem privkey.pem; do
  if [ ! -f "$CERT_DIR/$f" ]; then
    log err "[$DOMAIN] deploy-esxi.sh: Missing certificate file: $CERT_DIR/$f"
    exit 1
  fi
done

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
  log err "[$DOMAIN] deploy-esxi.sh: 'host' is missing in target configuration."
  exit 1
fi

SSL_DIR="/etc/vmware/ssl"

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
  log err "[$DOMAIN → ESXi:$HOST] Error at line $LINE (exit code: $EXIT_CODE)"
  exit $EXIT_CODE
}
trap '_on_error $LINENO' ERR

# ── Transfer certificates ────────────────────────────────────────
log info "[$DOMAIN → ESXi:$HOST] Transferring certificate..."

ssh $SSH_OPTS "$USER@$HOST" "mkdir -p /tmp/cert-update"

scp -P "$PORT" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o AddressFamily="$ADDRESS_FAMILY" \
    -i "$KEY" \
    "$CERT_DIR/fullchain.pem" \
    "$CERT_DIR/privkey.pem" \
    "$USER@$HOST:/tmp/cert-update/"

# Back up the previous cert/key (best-effort — none yet on a fresh
# host), then move the new ones into place with the ownership ESXi
# expects: readable cert, key restricted to root.
ssh $SSH_OPTS "$USER@$HOST" "
  cp $SSL_DIR/rui.crt $SSL_DIR/rui.crt.bak 2>/dev/null || true
  cp $SSL_DIR/rui.key $SSL_DIR/rui.key.bak 2>/dev/null || true
  cp /tmp/cert-update/fullchain.pem $SSL_DIR/rui.crt &&
  cp /tmp/cert-update/privkey.pem   $SSL_DIR/rui.key  &&
  chmod 644 $SSL_DIR/rui.crt &&
  chmod 600 $SSL_DIR/rui.key &&
  rm -rf /tmp/cert-update
"

log info "[$DOMAIN → ESXi:$HOST] Certificate installed."

# ── Restart management agents ─────────────────────────────────────
# hostd serves the Host Client UI on :443 — required, fatal if it fails.
# vpxa only matters if the host is vCenter-managed; restarting it when
# vpxa isn't running is a harmless no-op, so its failure is a warning.
log info "[$DOMAIN → ESXi:$HOST] Restarting hostd..."
ssh $SSH_OPTS "$USER@$HOST" "/etc/init.d/hostd restart"
log info "[$DOMAIN → ESXi:$HOST] Restarting vpxa..."
ssh $SSH_OPTS "$USER@$HOST" "/etc/init.d/vpxa restart" \
  || log warning "[$DOMAIN → ESXi:$HOST] vpxa restart failed/no-op (fine if the host isn't vCenter-managed)."

log info "[$DOMAIN → ESXi:$HOST] Deployment finished."
