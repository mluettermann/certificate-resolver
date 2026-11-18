#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ═══════════════════════════════════════════════════════════════
# scripts/host/sftp-add-user.sh — Add a new Windows/IIS SFTP user
#
# Creates the required directory structure, adds the user to
# sftp-users.conf, and installs the public key.
#
# Usage (run on the Docker host, in the repository directory):
#   ./scripts/host/sftp-add-user.sh <username> <path-to-public-key>
#
# Example:
#   ./scripts/host/sftp-add-user.sh win-iis-1 /tmp/win-iis-1.pub
#
# After adding a user, restart the SFTP container:
#   docker compose restart sftp
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# Host data root — must match DATA_ROOT in the compose .env.
DATA_ROOT="${DATA_ROOT:-/opt/certificate-resolver}"

USERNAME="${1:-}"
PUBKEY_FILE="${2:-}"

# ── Input validation ─────────────────────────────────────────────
if [ -z "$USERNAME" ] || [ -z "$PUBKEY_FILE" ]; then
  echo "Usage: $0 <username> <path-to-public-key>"
  echo ""
  echo "Example:"
  echo "  $0 win-iis-1 /tmp/win-iis-1.pub"
  exit 1
fi

if [[ ! "$USERNAME" =~ ^[a-z0-9_-]+$ ]]; then
  echo "Error: Username may only contain lowercase letters, digits, hyphens, and underscores."
  exit 1
fi

if [ ! -f "$PUBKEY_FILE" ]; then
  echo "Error: Public key file not found: $PUBKEY_FILE"
  exit 1
fi

USERS_CONF="$DATA_ROOT/sftp-users.conf"
SFTP_HOME="$DATA_ROOT/sftp-home"
USER_HOME="$SFTP_HOME/$USERNAME"

# ── Check for existing user ──────────────────────────────────────
if grep -qE "^$USERNAME:" "$USERS_CONF" 2>/dev/null; then
  echo "Error: User '$USERNAME' is already listed in sftp-users.conf."
  exit 1
fi

# ── Determine next available UID (starting at 1001) ──────────────
LAST_UID=$(grep -oE ':[0-9]+:[0-9]+:' "$USERS_CONF" 2>/dev/null \
  | grep -oE ':[0-9]+:' | head -1 | grep -oE '[0-9]+' \
  | sort -n | tail -1 || echo 1000)
NEXT_UID=$((LAST_UID + 1))
if [ "$NEXT_UID" -le 1000 ]; then
  NEXT_UID=1001
fi

echo "Creating SFTP user '$USERNAME' (UID: $NEXT_UID)..."

# ── Create directory structure ───────────────────────────────────
# /home/<user>/           → chroot base (must be owned root:root 755)
# /home/<user>/.ssh/keys/ → public keys read by atmoz/sftp
# /home/<user>/certs/     → certificate drop directory (readable by user)
mkdir -p "$USER_HOME/.ssh/keys"
mkdir -p "$USER_HOME/certs"

# Chroot base: root:root 755 (OpenSSH requirement)
chmod 755 "$USER_HOME"

# SSH key directories: not readable by others
chmod 700 "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh/keys"

# Certificate drop directory: readable by the SFTP user
chmod 755 "$USER_HOME/certs"

# ── Install public key ───────────────────────────────────────────
# atmoz/sftp reads all .pub files from .ssh/keys/ and appends them
# to the user's authorized_keys on container start.
cp "$PUBKEY_FILE" "$USER_HOME/.ssh/keys/authorized_key.pub"
chmod 644 "$USER_HOME/.ssh/keys/authorized_key.pub"

echo "  Public key installed: $USER_HOME/.ssh/keys/authorized_key.pub"

# ── Add entry to sftp-users.conf ────────────────────────────────
# Format: username::uid:gid:subdir
# gid 100 = 'users' group in Alpine Linux
echo "$USERNAME::$NEXT_UID:100:certs" >> "$USERS_CONF"

echo "  sftp-users.conf updated: $USERNAME::$NEXT_UID:100:certs"

# ── Summary ──────────────────────────────────────────────────────
echo ""
echo "User '$USERNAME' created successfully."
echo ""
echo "Next steps:"
echo "  1. Restart the SFTP container:"
echo "       docker compose restart sftp"
echo ""
echo "  2. Add the user to cert-targets.yml under sftp_users:"
echo "       sftp_users:"
echo "         - $USERNAME"
echo ""
echo "  3. Configure the Windows server (WinSCP scheduled task):"
echo "       Server:  <this-host-ip>:2222"
echo "       User:    $USERNAME"
echo "       Key:     Private key matching $PUBKEY_FILE"
echo "       Path:    /certs/<domain>/certificate.pfx"
echo ""
echo "  Connection test (from Linux):"
echo "    sftp -P 2222 -i <private-key> $USERNAME@<host>"
