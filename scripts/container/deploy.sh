#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ═══════════════════════════════════════════════════════════════
# deploy.sh — Certificate distribution dispatcher
#
# Reads /data/cert-targets.yml and distributes certificates for
# $CERTDOMAIN to all configured targets.
#
# Called by renew-hook.sh. To re-deploy manually, prefer rebuilding the PFX
# with a fresh password and deploying in one go (no password prompt needed):
#   docker exec certificate-resolver bash -c 'CERTDOMAIN=example.com /scripts/renew-hook.sh initial'
# deploy.sh alone re-uses the existing certificate.pfx:
#   docker exec -it certificate-resolver bash -c 'CERTDOMAIN=example.com /scripts/deploy.sh'
#
# windows-ssh and sftp-drop targets need PFX_PASSWORD (to import the
# existing certificate.pfx, or to write it next to the dropped PFX). On the
# automatic path renew-hook.sh generates a fresh one and exports
# PFX_PASSWORD before calling this script; on a manual run (re-pushing to
# a target without a full renewal) that password isn't known to the
# container. If PFX_PASSWORD isn't already set and stdin is a real
# terminal, this script prompts for it once, up front (must happen here,
# before the per-target loop below redirects each deployer's stdin to
# /dev/null). Run with -it so there's a terminal to prompt on; without it
# (e.g. cron, CI), it's skipped and the affected deployer fails with a
# clear error (windows-ssh) or logs a warning (sftp-drop) instead of hanging.
# ═══════════════════════════════════════════════════════════════

set -eo pipefail
source /scripts/notify.sh

DOMAIN="${CERTDOMAIN:-$1}"
CERT_DIR="/certs/$DOMAIN"
TARGETS_FILE="${TARGETS_FILE:-/data/cert-targets.yml}"

if [ -z "$DOMAIN" ]; then
  log err "deploy.sh: CERTDOMAIN is not set."
  exit 1
fi

# ── No config → no transfer ──────────────────────────────────────
if [ ! -f "$TARGETS_FILE" ]; then
  log info "[$DOMAIN] No cert-targets.yml found at $TARGETS_FILE — skipping distribution."
  exit 0
fi

if [ ! -f "$CERT_DIR/fullchain.pem" ]; then
  log err "[$DOMAIN] Certificate files not found: $CERT_DIR"
  exit 1
fi

# ── Read targets from YAML ───────────────────────────────────────
# Outputs one JSON object per line for each configured target,
# or nothing if no targets are defined for this domain.
TARGETS_JSON=$(python3 - <<PYEOF
import yaml, json, sys

try:
    with open("$TARGETS_FILE") as f:
        data = yaml.safe_load(f) or {}
except Exception as e:
    print(f"Error reading $TARGETS_FILE: {e}", file=sys.stderr)
    sys.exit(1)

matched = (data.get("targets") or {}).get("$DOMAIN", [])

for t in (matched or []):
    print(json.dumps(t))
PYEOF
)

if [ -z "$TARGETS_JSON" ]; then
  log info "[$DOMAIN] No targets configured in cert-targets.yml — skipping distribution."
  exit 0
fi

# ── Manual-run convenience: prompt for a missing PFX_PASSWORD ────
# Relevant for windows-ssh (needs it to import the existing certificate.pfx)
# and sftp-drop (writes it next to the PFX) — other target types don't touch it.
# Skipped whenever PFX_PASSWORD is already set (the normal automatic path
# via renew-hook.sh) or there's no terminal to prompt on.
if [ -z "${PFX_PASSWORD:-}" ] && [ -t 0 ]; then
  NEEDS_PW=$(printf '%s\n' "$TARGETS_JSON" | python3 -c "
import sys, json
need = any(json.loads(l).get('type') in ('windows-ssh', 'sftp-drop') for l in sys.stdin if l.strip())
print('yes' if need else 'no')
")
  if [ "$NEEDS_PW" = "yes" ]; then
    read -r -s -p "[$DOMAIN] PFX_PASSWORD not set — enter the password certificate.pfx was built with: " PFX_PASSWORD
    echo
    export PFX_PASSWORD
  fi
fi

# ── Deploy to each target ────────────────────────────────────────
# Results are collected here and reported in ONE consolidated email at the
# end (only on failure). The individual deployer scripts no longer send mail.
ERRORS=0
TARGET_NUM=0
FAILED_DETAILS=""

while IFS= read -r target_json; do
  [ -z "$target_json" ] && continue
  TARGET_NUM=$((TARGET_NUM + 1))

  TYPE=$(echo "$target_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('type', 'ssh'))")
  HOST=$(echo "$target_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('host', '?'))")

  log info "[$DOMAIN] Target $TARGET_NUM: type=$TYPE host=$HOST"

  # Write target JSON to a temp file to avoid shell quoting issues
  TMP_TARGET=$(mktemp)
  echo "$target_json" > "$TMP_TARGET"

  case "$TYPE" in
    ssh|traefik-ssh|nginx-ssh|apache-ssh) DEPLOYER="/scripts/deployers/deploy-ssh.sh"; LABEL="$TYPE $HOST" ;;
    windows-ssh)                          DEPLOYER="/scripts/deployers/deploy-windows-ssh.sh"; LABEL="$TYPE $HOST" ;;
    sftp-drop)                            DEPLOYER="/scripts/deployers/deploy-sftp-drop.sh"; LABEL="sftp-drop" ;;
    proxmox)                              DEPLOYER="/scripts/deployers/deploy-proxmox.sh"; LABEL="proxmox $HOST" ;;
    esxi)                                 DEPLOYER="/scripts/deployers/deploy-esxi.sh"; LABEL="esxi $HOST" ;;
    *) log warning "[$DOMAIN] Unknown target type '$TYPE' — skipping."; rm -f "$TMP_TARGET"; continue ;;
  esac

  # Capture output so we can show it in the logs AND extract a reason for the summary.
  # </dev/null: prevent child processes (ssh, scp) from consuming the while-loop's
  # here-string stdin and swallowing subsequent target entries.
  if OUT=$("$DEPLOYER" "$DOMAIN" "$TMP_TARGET" </dev/null 2>&1); then
    printf '%s\n' "$OUT"
    log info "[$DOMAIN] Target $TARGET_NUM ($LABEL) succeeded."
  else
    printf '%s\n' "$OUT"
    REASON=$(printf '%s\n' "$OUT" | grep -iE 'ssh:|scp:|denied|unreachable|refused|timed out|not found|missing|error' | tail -1 | sed -E 's/^[0-9]{4}-[0-9-]* [0-9:]+ \[[a-z]+\] //' || true)
    [ -z "$REASON" ] && REASON="see container logs"
    log err "[$DOMAIN] Target $TARGET_NUM ($LABEL) failed: $REASON"
    FAILED_DETAILS="${FAILED_DETAILS}  - ${LABEL}: ${REASON}
"
    ERRORS=$((ERRORS + 1))
  fi

  rm -f "$TMP_TARGET"
done <<< "$TARGETS_JSON"

# ── Summary ──────────────────────────────────────────────────────
if [ "$ERRORS" -gt 0 ]; then
  log err "[$DOMAIN] Distribution completed with $ERRORS error(s) across $TARGET_NUM target(s)."
  # Single consolidated email for the whole run (no per-target spam).
  notify_distribution_summary "$DOMAIN" "$TARGET_NUM" "$ERRORS" "$FAILED_DETAILS"
  exit 1
fi

log info "[$DOMAIN] Distribution completed: $TARGET_NUM target(s) successful."
