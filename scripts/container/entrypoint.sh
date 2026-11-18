#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ═══════════════════════════════════════════════════════════════
# entrypoint.sh — Generate configuration from environment, then start
#
# Populates acme-dns.cfg.template with values from .env and
# launches supervisord (acme-dns + renewal daemon).
# ═══════════════════════════════════════════════════════════════

set -e

# ── Required variable check ──────────────────────────────────────
MISSING=""
[ -z "$ACMEDNS_ZONE" ] && MISSING="$MISSING ACMEDNS_ZONE"
[ -z "$SERVER_IP"    ] && MISSING="$MISSING SERVER_IP"

if [ -n "$MISSING" ]; then
  echo "Error: The following variables are missing in .env:$MISSING"
  exit 1
fi

# ── Generate acme-dns configuration from template ────────────────
echo "Generating acme-dns configuration..."
echo "  Zone:      $ACMEDNS_ZONE"
echo "  Server IP: $SERVER_IP"

envsubst '${ACMEDNS_ZONE} ${SERVER_IP}' \
  < /etc/acme-dns/config.cfg.template \
  > /etc/acme-dns/config.cfg

echo "Configuration generated successfully."

# ── Prepare SSH directory for certificate deployment ─────────────
# Used by deploy-ssh.sh when transferring certificates to remote hosts.
mkdir -p /data/ssh
chmod 700 /data/ssh

# ── Validate cert-targets.yml ─────────────────────────────────────
# Catches bad YAML, unknown target types, and missing required fields now
# instead of weeks from now when a renewal actually fires for that domain.
# Non-fatal unless CR_STRICT_TARGETS=true (see validate-targets.sh).
/scripts/validate-targets.sh

# ── Start supervisord ────────────────────────────────────────────
exec /usr/bin/supervisord -c /etc/supervisord.conf
