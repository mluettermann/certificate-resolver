#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ═══════════════════════════════════════════════════════════════
# deployers/deploy-windows-ssh.sh — SSH-based certificate transfer
#
# Copies certificate files to a remote host via SCP and optionally
# runs a reload command. Works for Windwos with SSH Server
#
#
# Called by deploy.sh:
#   deploy-windows-ssh.sh <domain> <path-to-target-json-file>
# ═══════════════════════════════════════════════════════════════

set -eo pipefail
source /scripts/notify.sh

DOMAIN="$1"
TARGET_FILE="$2"
CERT_DIR="/certs/$DOMAIN"
# PFX_PASSWORD is generated fresh per run and exported by renew-hook.sh.
# No fallback default on purpose: a wrong password would only surface as a
# misleading "wrong password" error from Import-PfxCertificate on the host.
if [ -z "${PFX_PASSWORD:-}" ]; then
  log err "[$DOMAIN] deploy-windows-ssh.sh: PFX_PASSWORD is not set. To re-deploy manually, rebuild the PFX and deploy in one go: CERTDOMAIN=$DOMAIN /scripts/renew-hook.sh initial"
  exit 1
fi

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
LEGACY_PFX=$(_field legacy_pfx false)
RELOAD_SCRIPT=$(_field reload_script)

# Let reload_cmd reference {{DOMAIN}} instead of hardcoding the domain a
# second time (it's already the key under "targets:" in cert-targets.yml).
RELOAD_CMD="${RELOAD_CMD//\{\{DOMAIN\}\}/$DOMAIN}"

# renew-hook.sh produces two PFX variants: certificate.pfx (strong,
# AES-256+SHA-256) and certificate-legacy.pfx (RC2/3DES-SHA1, for older
# Windows CryptoAPI that can't parse the modern scheme). Only opt into the
# weaker one for targets that actually need it.
if [ "$LEGACY_PFX" = "True" ] || [ "$LEGACY_PFX" = "true" ]; then
  PFX_FILE="certificate-legacy.pfx"
else
  PFX_FILE="certificate.pfx"
fi

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
# The remote shell on Windows OpenSSH is cmd.exe by default, which
# doesn't understand "mkdir -p" (and isn't idempotent). Invoke
# PowerShell explicitly instead — works regardless of DefaultShell.
log info "[$DOMAIN → $HOST] Establishing SSH connection..."
ssh $SSH_OPTS "$USER@$HOST" "powershell -NoProfile -Command \"\$null = New-Item -ItemType Directory -Force -Path '$REMOTE_CERT_DIR/$DOMAIN'\""

# ── Transfer certificate files ───────────────────────────────────
log info "[$DOMAIN → $HOST] Transferring certificate ($PFX_FILE) to $REMOTE_CERT_DIR/$DOMAIN/ ..."
scp -P "$PORT" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -i "$KEY" \
    "$CERT_DIR/$PFX_FILE" \
    "$USER@$HOST:$REMOTE_CERT_DIR/$DOMAIN/certificate.pfx"

log info "[$DOMAIN → $HOST] Transfer successful."

# ── Import into the Windows certificate store ────────────────────
# The PFX password is streamed over the SSH stdin channel rather than
# passed as a command-line argument or baked into the (base64) script,
# so it never shows up in the remote process list or command-line
# auditing. -EncodedCommand sidesteps the bash → ssh → cmd.exe →
# powershell quoting chain, which is otherwise very easy to break.
IMPORT_PS_SCRIPT=$(cat <<EOF
\$plain = [Console]::In.ReadLine()
\$secure = ConvertTo-SecureString -String \$plain -AsPlainText -Force
Import-PfxCertificate -FilePath "$REMOTE_CERT_DIR/$DOMAIN/certificate.pfx" -CertStoreLocation Cert:\LocalMachine\My -Password \$secure -Exportable | Out-Null
EOF
)
ENCODED_CMD=$(python3 -c "import base64, sys; print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$IMPORT_PS_SCRIPT")

log info "[$DOMAIN → $HOST] Importing certificate into Cert:\\LocalMachine\\My..."
printf '%s' "$PFX_PASSWORD" | ssh $SSH_OPTS "$USER@$HOST" "powershell -NoProfile -NonInteractive -EncodedCommand $ENCODED_CMD"
log info "[$DOMAIN → $HOST] Certificate imported."

# ── Remove PFX from remote host ───────────────────────────────────
# The private key would otherwise sit at rest on the Windows filesystem,
# protected only by PFX_PASSWORD, until the next renewal overwrites it.
# It's already in Cert:\LocalMachine\My now, so the file itself is no
# longer needed.
log info "[$DOMAIN → $HOST] Removing PFX from remote host..."
ssh $SSH_OPTS "$USER@$HOST" "powershell -NoProfile -Command \"Remove-Item -Force '$REMOTE_CERT_DIR/$DOMAIN/certificate.pfx'\""
log info "[$DOMAIN → $HOST] PFX removed from remote host."

# ── Sync reload script (optional) ─────────────────────────────────
# Keeps the remote .ps1 in lockstep with the repo instead of requiring a
# manual copy onto every Windows target — it's re-pushed on every deploy.
if [ -n "$RELOAD_SCRIPT" ]; then
  if [ -f "$RELOAD_SCRIPT" ]; then
    log info "[$DOMAIN → $HOST] Syncing reload script..."
    scp -P "$PORT" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=15 \
        -i "$KEY" \
        "$RELOAD_SCRIPT" \
        "$USER@$HOST:$REMOTE_CERT_DIR/$(basename "$RELOAD_SCRIPT")"
  else
    log warning "[$DOMAIN → $HOST] reload_script '$RELOAD_SCRIPT' not found locally — skipping sync."
  fi
fi

# ── Optional reload command ──────────────────────────────────────
if [ -n "$RELOAD_CMD" ]; then
  log info "[$DOMAIN → $HOST] Running reload: $RELOAD_CMD"
  ssh $SSH_OPTS "$USER@$HOST" "$RELOAD_CMD"
  log info "[$DOMAIN → $HOST] Reload completed."
fi

# ── Final cleanup ──────────────────────────────────────────────────
# Only reached on the success path (the ERR trap exits earlier on failure,
# e.g. if reload_cmd errors — in that case the domain folder/script are left
# in place on purpose, for troubleshooting). Removes the domain's cert
# folder and the synced reload script, and the shared remote_cert_dir root
# too, but only once it's empty (other domains may still use it).
log info "[$DOMAIN → $HOST] Cleaning up remote host..."
CLEANUP_PS="Remove-Item -Recurse -Force '$REMOTE_CERT_DIR/$DOMAIN' -ErrorAction SilentlyContinue"
if [ -n "$RELOAD_SCRIPT" ]; then
  CLEANUP_PS="$CLEANUP_PS; Remove-Item -Force '$REMOTE_CERT_DIR/$(basename "$RELOAD_SCRIPT")' -ErrorAction SilentlyContinue"
fi
CLEANUP_PS="$CLEANUP_PS; if (-not (Get-ChildItem -Path '$REMOTE_CERT_DIR' -ErrorAction SilentlyContinue)) { Remove-Item -Force '$REMOTE_CERT_DIR' -ErrorAction SilentlyContinue }"
ssh $SSH_OPTS "$USER@$HOST" "powershell -NoProfile -Command \"$CLEANUP_PS\""
log info "[$DOMAIN → $HOST] Cleanup completed."

# Success is reported by deploy.sh in a single consolidated summary, not per host.
log info "[$DOMAIN → $HOST] Deployment finished."
