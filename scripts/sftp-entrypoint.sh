#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# ═══════════════════════════════════════════════════════════════
# sftp-entrypoint.sh — Wrapper for the atmoz/sftp entrypoint
#
# Problem: atmoz/sftp's entrypoint runs:
#   grep -v -E "$reArgSkip" < users.conf > users.conf.final
# If users.conf contains only comments or empty lines, grep exits
# with code 1 (no matches), which crashes the container under set -e.
#
# Solution: Mount users.conf at a source path (/etc/sftp/users.conf.src).
# This wrapper filters it and writes the result to the expected path
# (/etc/sftp/users.conf) only when real user entries exist.
# If the file is empty or comment-only, /etc/sftp/users.conf is not
# created — atmoz/sftp checks "if [ -f users.conf ]" before processing,
# so it starts cleanly with no file-based users defined.
#
# Users are added with: ./scripts/host/sftp-add-user.sh
# ═══════════════════════════════════════════════════════════════

SRC="/etc/sftp/users.conf.src"
CONF="/etc/sftp/users.conf"

if [ -f "$SRC" ]; then
    REAL_USERS=$(grep -v -E "^[[:blank:]]*#|^[[:blank:]]*$" "$SRC" 2>/dev/null || true)
    if [ -n "$REAL_USERS" ]; then
        echo "$REAL_USERS" > "$CONF"
    fi
    # If no real users: $CONF is not created → atmoz/sftp skips the file block
fi

exec /entrypoint "$@"
