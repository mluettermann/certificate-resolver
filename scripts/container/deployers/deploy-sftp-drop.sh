#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ═══════════════════════════════════════════════════════════════
# deployers/deploy-sftp-drop.sh — Place PFX in SFTP drop directory
#
# Copies the PFX file into the drop directory of the specified
# SFTP user(s). The Windows server then retrieves it via SFTP.
#
# Directory layout:
#   /sftp-home/<sftp_user>/certs/<domain>/certificate.pfx
#   /sftp-home/<sftp_user>/certs/<domain>/certificate.pfx.password.txt
#     (PFX password — random per renewal, so it has to travel with the PFX)
#
# Called by deploy.sh:
#   deploy-sftp-drop.sh <domain> <path-to-target-json-file>
# ═══════════════════════════════════════════════════════════════

set -eo pipefail
source /scripts/notify.sh

DOMAIN="$1"
TARGET_FILE="$2"
CERT_DIR="/certs/$DOMAIN"
SFTP_HOME="/sftp-home"

if [ -z "$DOMAIN" ] || [ -z "$TARGET_FILE" ] || [ ! -f "$TARGET_FILE" ]; then
  log err "deploy-sftp-drop.sh: Usage: deploy-sftp-drop.sh <domain> <target-json-file>"
  exit 1
fi

if [ ! -f "$CERT_DIR/certificate.pfx" ]; then
  log err "[$DOMAIN] PFX file not found: $CERT_DIR/certificate.pfx"
  exit 1
fi

if [ ! -d "$SFTP_HOME" ]; then
  log err "[$DOMAIN] SFTP home directory not found: $SFTP_HOME"
  log err "         Is the volume ./sftp-home:/sftp-home mounted in docker-compose.yml?"
  exit 1
fi

# ── Read SFTP user(s) from target JSON ──────────────────────────
# sftp_users can be a string (single user) or a list
SFTP_USERS=$(python3 - <<PYEOF
import json, sys

with open("$TARGET_FILE") as f:
    d = json.load(f)

users = d.get("sftp_users", [])
if isinstance(users, str):
    users = [users]

for u in users:
    print(u)
PYEOF
)

if [ -z "$SFTP_USERS" ]; then
  log err "[$DOMAIN] deploy-sftp-drop.sh: 'sftp_users' is missing or empty in target configuration."
  exit 1
fi

# ── Place PFX in each user's drop directory ──────────────────────
ERRORS=0

while IFS= read -r SFTP_USER; do
  [ -z "$SFTP_USER" ] && continue

  DROP_DIR="$SFTP_HOME/$SFTP_USER/certs/$DOMAIN"

  if [ ! -d "$SFTP_HOME/$SFTP_USER" ]; then
    log err "[$DOMAIN → SFTP:$SFTP_USER] Home directory not found: $SFTP_HOME/$SFTP_USER"
    log err "         Add the user first: ./scripts/host/sftp-add-user.sh $SFTP_USER <public-key>"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  log info "[$DOMAIN → SFTP:$SFTP_USER] Placing PFX in $DROP_DIR ..."

  mkdir -p "$DROP_DIR"
  cp "$CERT_DIR/certificate.pfx" "$DROP_DIR/certificate.pfx"
  # Readable by the SFTP user (644), directory traversable (755)
  chmod 644 "$DROP_DIR/certificate.pfx"
  chmod 755 "$DROP_DIR"

  # The PFX password is random per renewal (renew-hook.sh), so the Windows
  # host can't know it in advance — drop it next to the PFX. Same exposure
  # as the PFX itself: only this SFTP user (chrooted) can read its drop dir.
  # Fetch both files, import, then delete both on the Windows side.
  if [ -n "${PFX_PASSWORD:-}" ]; then
    printf '%s' "$PFX_PASSWORD" > "$DROP_DIR/certificate.pfx.password.txt"
    chmod 644 "$DROP_DIR/certificate.pfx.password.txt"
  else
    log warning "[$DOMAIN → SFTP:$SFTP_USER] PFX_PASSWORD not set — certificate.pfx.password.txt not written (run via renew-hook.sh)."
  fi

  log info "[$DOMAIN → SFTP:$SFTP_USER] PFX placed: $DROP_DIR/certificate.pfx (+ certificate.pfx.password.txt)"

done <<< "$SFTP_USERS"

if [ "$ERRORS" -gt 0 ]; then
  exit 1
fi
