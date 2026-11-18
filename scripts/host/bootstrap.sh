#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ═══════════════════════════════════════════════════════════════
# scripts/host/bootstrap.sh — prepare the host data directory
#
# Creates the full DATA_ROOT layout and stages the files that the
# docker-compose.yml bind-mounts, so every mount resolves to a real
# file/directory on the first start.
#
# WHY: Docker auto-creates a *directory* for a missing bind-mounted
# *file* (e.g. cert-targets.yml or sftp-entrypoint.sh). The SFTP
# container then tries to exec a directory and fails with
# "is a directory". This script prevents that by staging the files.
#
# Usage (run on the Docker host, from the repository checkout):
#   sudo DATA_ROOT=/opt/certificate-resolver ./scripts/host/bootstrap.sh
#
# DATA_ROOT must match the value used in the compose .env.
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DATA_ROOT="${DATA_ROOT:-/opt/certificate-resolver}"

echo "Preparing data root: $DATA_ROOT"

# ── Guard: a failed earlier deploy may have let Docker create a
#    DIRECTORY where a file is expected. Detect and abort cleanly.
for f in cert-targets.yml sftp-users.conf sftp-entrypoint.sh; do
  if [ -d "$DATA_ROOT/$f" ]; then
    echo "ERROR: '$DATA_ROOT/$f' is a directory but must be a file."
    echo "       A previous deploy created it. Remove it and re-run:"
    echo "         sudo rmdir '$DATA_ROOT/$f'"
    exit 1
  fi
done

# ── Directories (bind-mounted as folders) ────────────────────────
mkdir -p \
  "$DATA_ROOT/data" \
  "$DATA_ROOT/certs" \
  "$DATA_ROOT/sftp-home" \
  "$DATA_ROOT/ui-data" \
  "$DATA_ROOT/sftp-hostkeys"
echo "  directories ready: data/ certs/ sftp-home/ ui-data/ sftp-hostkeys/"

# ── seed_file <dest> <source-or-empty> ───────────────────────────
# Copies a sample from the repo if present, else creates the file,
# but never overwrites an existing (runtime-modified) file.
seed_file() {
  dest="$1"; src="$2"
  if [ -f "$dest" ]; then
    echo "  kept (exists): $(basename "$dest")"
  elif [ -n "$src" ] && [ -f "$src" ]; then
    cp "$src" "$dest"; echo "  seeded: $(basename "$dest")"
  else
    : > "$dest"; echo "  created empty: $(basename "$dest")"
  fi
}

# ── Files (bind-mounted as files — MUST exist before first start) ─
seed_file "$DATA_ROOT/cert-targets.yml" "$REPO_ROOT/cert-targets.yml"
seed_file "$DATA_ROOT/sftp-users.conf"  "$REPO_ROOT/sftp-users.conf"

# Entrypoint wrapper is code from the repo — always refresh + make executable
cp "$REPO_ROOT/scripts/sftp-entrypoint.sh" "$DATA_ROOT/sftp-entrypoint.sh"
chmod +x "$DATA_ROOT/sftp-entrypoint.sh"
echo "  staged: sftp-entrypoint.sh (executable)"

echo ""
echo "Done. Layout under $DATA_ROOT:"
echo "  data/              acme-dns db, credentials, acme.sh data"
echo "  certs/             certificate files"
echo "  sftp-home/         SFTP drop"
echo "  ui-data/           web UI private data (users.json, audit.log)"
echo "  sftp-hostkeys/     persistent SSH host keys"
echo "  cert-targets.yml   distribution config"
echo "  sftp-users.conf    SFTP user list"
echo "  sftp-entrypoint.sh SFTP entrypoint wrapper"
echo ""
echo "Re-run this script after pulling repo changes (it refreshes the"
echo "entrypoint and keeps your runtime data)."
echo ""
echo "Next: set DATA_ROOT in your .env (if different), then run:"
echo "  docker compose up -d"
