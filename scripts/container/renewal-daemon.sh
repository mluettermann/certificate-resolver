#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ═══════════════════════════════════════════════════════════════
# renewal-daemon.sh — Background renewal process
#
# Started by supervisord. Do not invoke manually.
# Runs once a day at a fixed local time (RENEW_HOUR:RENEW_MINUTE, default
# 03:00) rather than N seconds after container start — otherwise the run
# time drifts with every restart instead of landing in a predictable,
# low-traffic window.
# Let's Encrypt certificates expire after 90 days;
# acme.sh renews automatically when less than 30 days remain.
# After renewal, renew-hook.sh is called (recreates PFX + distributes certs).
#
# Why not plain "acme.sh --cron"?
#   --cron relies solely on the acme-dns credentials acme.sh saved in each
#   domain's .conf at issue time. If those are missing, stale or belong to a
#   different domain, the TXT update goes to the wrong acme-dns subdomain (or
#   to the public default https://auth.acme-dns.io) and validation fails,
#   while a manual issue.sh works because it exports the right credentials.
#   We therefore renew every domain individually with exactly the same
#   ACMEDNS_* environment issue.sh uses (from acmedns-credentials.json).
#   dns_acmedns prefers these env values and re-saves them to the domain conf.
# ═══════════════════════════════════════════════════════════════

source /scripts/notify.sh

RENEW_HOUR="${RENEW_HOUR:-3}"
RENEW_MINUTE="${RENEW_MINUTE:-0}"
SKIP_WEEKENDS="${SKIP_WEEKENDS:-1}"   # 1 = skip, 0 = always run
ACME_DATA="${ACME_DATA:-/data/acme}"
CREDS_FILE="/data/acmedns-credentials.json"
RENEW_SKIP=2   # acme.sh return code: "not due yet, skipped"

# Seconds until the next RENEW_HOUR:RENEW_MINUTE (today if still ahead,
# otherwise tomorrow). Recomputed every iteration instead of a static 86400s
# sleep, so restarts/DST can't drift the run time away from the wall clock.
_seconds_until_next_run() {
  local now_epoch midnight_epoch target_epoch
  now_epoch=$(date +%s)
  midnight_epoch=$(date -d "$(date +%Y-%m-%d)" +%s)
  target_epoch=$((midnight_epoch + RENEW_HOUR * 3600 + RENEW_MINUTE * 60))
  if [ "$target_epoch" -le "$now_epoch" ]; then
    target_epoch=$((target_epoch + 86400))
  fi
  echo $((target_epoch - now_epoch))
}

# Prints "username<TAB>password<TAB>subdomain" for a domain, or nothing.
_creds_for() {
  [ -f "$CREDS_FILE" ] || return 0
  python3 - "$CREDS_FILE" "$1" <<'PY'
import json, sys
e = json.load(open(sys.argv[1])).get('_acme-challenge.' + sys.argv[2])
if e:
    print('\t'.join([e['username'], e['password'], e['subdomain']]))
PY
}

# Renews one domain. Returns 0 = renewed, 2 = not due, other = failed.
_renew_domain() {
  local domain="$1" ecc="$2" creds user pass sub out rc
  local ecc_args=()
  [ -n "$ecc" ] && ecc_args=(--ecc)

  creds=$(_creds_for "$domain")
  if [ -z "$creds" ]; then
    log warning "[$domain] no entry in $CREDS_FILE — using credentials saved by acme.sh"
  fi
  IFS=$'\t' read -r user pass sub <<< "$creds"

  out=$(
    if [ -n "$creds" ]; then
      export ACMEDNS_BASE_URL="http://localhost:8080"
      export ACMEDNS_USERNAME="$user"
      export ACMEDNS_PASSWORD="$pass"
      export ACMEDNS_SUBDOMAIN="$sub"
    fi
    acme.sh --home "$ACME_DATA" "${ACME_DEBUG_ARGS[@]}" \
      --renew -d "$domain" "${ecc_args[@]}" 2>&1 < /dev/null
  )
  rc=$?

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [ "$rc" -ne 0 ] && [ "$rc" -ne "$RENEW_SKIP" ]; then
      log err "[acme.sh] [$domain] $line"
    else
      log info "[acme.sh] [$domain] $line"
    fi
  done <<< "$out"

  return "$rc"
}

_run_renewal() {
  local dir name domain ecc rc failed=0 renewed=0 skipped=0

  for dir in "$ACME_DATA"/*/; do
    name=$(basename "$dir")
    domain="${name%_ecc}"
    ecc=""
    [ "$domain" != "$name" ] && ecc=1
    # Only real certificate directories (contain <domain>.conf)
    [ -f "$dir/$domain.conf" ] || continue

    _renew_domain "$domain" "$ecc"
    rc=$?
    case "$rc" in
      0)
        renewed=$((renewed + 1))
        log info "[$domain] renewed."

        # acme.sh runs the saved reloadcmd (renew-hook.sh → PFX + deploy)
        # itself during --renew. Only call the hook here as a fallback when
        # no reloadcmd is stored, otherwise targets would be deployed twice.
        if grep -q "^Le_ReloadCmd='..*'" "$dir/$domain.conf"; then
          log info "[$domain] deploy hook executed by acme.sh (reloadcmd)."
        elif CERTDOMAIN="$domain" /scripts/renew-hook.sh; then
          log info "[$domain] deploy hook executed (fallback, no reloadcmd stored)."
        else
          log err "[$domain] deploy hook failed."
          failed=$((failed + 1))
        fi
        ;;
      "$RENEW_SKIP")
        skipped=$((skipped + 1))
        log info "[$domain] not due for renewal."
        ;;
      *)
        failed=$((failed + 1))
        log err "[$domain] renewal failed (acme.sh exit code $rc)"
        notify_error "Certificate renewal" "$domain" \
          "acme.sh --renew failed (exit code: $rc) — see renewal.log"
        ;;
    esac
  done

  log info "Renewal check done: $renewed renewed, $skipped not due, $failed failed."
  if [ "$failed" -gt 0 ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | system | renewal_failed" >> /data/audit.log
  else
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | system | renewal_ok" >> /data/audit.log
  fi
}

# Allow a manual test run: /scripts/renewal-daemon.sh --once
if [ "$1" = "--once" ]; then
  _run_renewal
  exit 0
fi

log info "Renewal daemon started (runs daily at $(printf '%02d:%02d' "$RENEW_HOUR" "$RENEW_MINUTE"))"

while true; do
  SLEEP_SECS=$(_seconds_until_next_run)
  log info "Next renewal check in $((SLEEP_SECS / 3600))h $(((SLEEP_SECS % 3600) / 60))m"
  sleep "$SLEEP_SECS"

  # date +%u: 1..7 (Mo..So)
  today=$(date +%u)
  if [ "${SKIP_WEEKENDS:-1}" -eq 1 ] && [ "$today" -ge 6 ]; then
    log info "Today is the weekend (day $today) — Renewal skipped."
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | system | renewal_skipped_weekend" >> /data/audit.log
    continue
  fi

  log info "Checking certificate renewal..."
  _run_renewal
done
