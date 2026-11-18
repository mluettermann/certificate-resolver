#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ═══════════════════════════════════════════════════════════════
# deployers/deploy-ssh.sh — SSH-based certificate transfer
#
# Copies certificate files to a remote host via SCP and optionally
# runs a reload command. Works for Traefik (file provider + watch),
# nginx, Apache, and any other SSH-accessible system.
#
# Traefik with file provider and watch: true does not require
# a reload command — it detects file changes automatically.
#
# Called by deploy.sh:
#   deploy-ssh.sh <domain> <path-to-target-json-file>
# ═══════════════════════════════════════════════════════════════

set -eo pipefail
source /scripts/notify.sh

DOMAIN="$1"
TARGET_FILE="$2"
CERT_DIR="/certs/$DOMAIN"

if [ -z "$DOMAIN" ] || [ -z "$TARGET_FILE" ] || [ ! -f "$TARGET_FILE" ]; then
  log err "deploy-ssh.sh: Usage: deploy-ssh.sh <domain> <target-json-file>"
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
REMOTE_CERT_DIR=$(_field remote_cert_dir)
RELOAD_CMD=$(_field reload_cmd)

if [ -z "$HOST" ]; then
  log err "[$DOMAIN] deploy-ssh.sh: 'host' is missing in target configuration."
  exit 1
fi

if [ -z "$REMOTE_CERT_DIR" ]; then
  log err "[$DOMAIN] deploy-ssh.sh: 'remote_cert_dir' is missing in target configuration."
  exit 1
fi

# Dual-stack: ssh uses IPv6 or IPv4 depending on what the host resolves to.
# Requires IPv6 to be enabled on the container network (see docker-compose.yml).
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -i $KEY -p $PORT"

# ── Error handling ───────────────────────────────────────────────
_on_error() {
  local EXIT_CODE=$?
  local LINE=$1
  # No email here — deploy.sh collects all target results into one summary mail.
  log err "[$DOMAIN → $HOST] Error at line $LINE (exit code: $EXIT_CODE)"
  exit $EXIT_CODE
}
trap '_on_error $LINENO' ERR

# ── Create remote directory ──────────────────────────────────────
log info "[$DOMAIN → $HOST] Establishing SSH connection..."
ssh $SSH_OPTS "$USER@$HOST" "mkdir -p $REMOTE_CERT_DIR/$DOMAIN"

# ── Transfer certificate files ───────────────────────────────────
log info "[$DOMAIN → $HOST] Transferring certificates to $REMOTE_CERT_DIR/$DOMAIN/ ..."
scp -P "$PORT" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -i "$KEY" \
    "$CERT_DIR/fullchain.pem" \
    "$CERT_DIR/privkey.pem" \
    "$CERT_DIR/cert.pem" \
    "$USER@$HOST:$REMOTE_CERT_DIR/$DOMAIN/"

log info "[$DOMAIN → $HOST] Transfer successful."

# ── Optional reload command ──────────────────────────────────────
if [ -n "$RELOAD_CMD" ]; then
  log info "[$DOMAIN → $HOST] Running reload: $RELOAD_CMD"
  ssh $SSH_OPTS "$USER@$HOST" "$RELOAD_CMD"
  log info "[$DOMAIN → $HOST] Reload completed."
fi

# Success is reported by deploy.sh in a single consolidated summary, not per host.
log info "[$DOMAIN → $HOST] Deployment finished."
