#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ═══════════════════════════════════════════════════════════════
# notify.sh — Logging and email notifications via SMTP (msmtp)
#
# Sourced by setup.sh, issue.sh, renew-hook.sh, and deploy scripts.
#
# Log variables (optional, set in .env):
#   CR_LOG_LEVEL   Minimum stdout level: debug|info|notice|warning|err|crit (default: info)
#   CR_LOG_FILE    Path to log file (default: /data/certificate-resolver.log)
#
# NOTE: Do not use LOG_LEVEL or LOG_FILE — acme.sh uses LOG_LEVEL
# internally as a numeric value (0-3) and would break on a string.
#
# Email variables (optional, set in .env):
#   SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASSWORD, SMTP_FROM, NOTIFY_EMAIL
# ═══════════════════════════════════════════════════════════════

# ── Logging ──────────────────────────────────────────────────────
declare -A _LOG_LEVELS=([emerg]=0 [alert]=1 [crit]=2 [err]=3 [warning]=4 [notice]=5 [info]=6 [debug]=7)
CR_LOG_LEVEL=${CR_LOG_LEVEL:-info}
CR_LOG_FILE=${CR_LOG_FILE:-/logs/certificate-resolver.log}
_NUMERIC_LOG_LEVEL=${_LOG_LEVELS[$CR_LOG_LEVEL]:-6}

# When CR_LOG_LEVEL=debug, pass --debug 2 to every acme.sh call.
# Scripts use "${ACME_DEBUG_ARGS[@]}" so the array expands cleanly.
ACME_DEBUG_ARGS=()
[ "${CR_LOG_LEVEL}" = "debug" ] && ACME_DEBUG_ARGS=(--debug 2)

# Size-based rotation for the structured log file.
CR_LOG_MAX_BYTES=${CR_LOG_MAX_BYTES:-5242880}   # rotate at 5 MB
CR_LOG_BACKUPS=${CR_LOG_BACKUPS:-5}             # keep .1 .. .N

_rotate_log() {
  [ -f "$CR_LOG_FILE" ] || return 0
  local size
  size=$(wc -c < "$CR_LOG_FILE" 2>/dev/null || echo 0)
  [ "${size:-0}" -lt "$CR_LOG_MAX_BYTES" ] && return 0
  local i="$CR_LOG_BACKUPS"
  while [ "$i" -gt 1 ]; do
    [ -f "$CR_LOG_FILE.$((i-1))" ] && mv -f "$CR_LOG_FILE.$((i-1))" "$CR_LOG_FILE.$i"
    i=$((i-1))
  done
  mv -f "$CR_LOG_FILE" "$CR_LOG_FILE.1"
}

log() {
  local level=$1
  shift
  local message="$*"
  local numeric_level=${_LOG_LEVELS[$level]:-6}
  local log_message
  log_message="$(date +"%Y-%m-%d %H:%M:%S") [$level] $message"
  mkdir -p "$(dirname "$CR_LOG_FILE")" 2>/dev/null
  _rotate_log
  echo "$log_message" >> "${CR_LOG_FILE}"
  if (( numeric_level <= _NUMERIC_LOG_LEVEL )); then
    echo "$log_message"
  fi
}

# ── Check whether email is configured ───────────────────────────
_notify_configured() {
  if [ -z "$SMTP_HOST" ] || [ -z "$SMTP_USER" ] || [ -z "$SMTP_PASSWORD" ] || [ -z "$NOTIFY_EMAIL" ]; then
    return 1
  fi
  return 0
}

# ── Generate msmtp configuration from environment variables ──────
_write_msmtp_config() {
  local PORT="${SMTP_PORT:-587}"
  local FROM="${SMTP_FROM:-$SMTP_USER}"

  cat > /tmp/msmtprc << EOF
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /dev/stderr

account        default
host           $SMTP_HOST
port           $PORT
from           $FROM
user           $SMTP_USER
password       $SMTP_PASSWORD
EOF
  chmod 600 /tmp/msmtprc
}

# ── Send email ───────────────────────────────────────────────────
# Usage: send_email "Subject" "Body"
send_email() {
  local SUBJECT="$1"
  local BODY="$2"
  local FROM="${SMTP_FROM:-$SMTP_USER}"
  local TIMESTAMP
  TIMESTAMP=$(date '+%d.%m.%Y %H:%M:%S')

  if ! _notify_configured; then
    echo "[notify] SMTP not configured, skipping email."
    return 0
  fi

  _write_msmtp_config

  printf "To: %s\nFrom: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n\nSent: %s\nServer: %s" \
    "$NOTIFY_EMAIL" \
    "$FROM" \
    "$SUBJECT" \
    "$BODY" \
    "$TIMESTAMP" \
    "$(hostname)" \
  | msmtp --file=/tmp/msmtprc "$NOTIFY_EMAIL"

  if [ $? -eq 0 ]; then
    log info "[notify] Email sent to $NOTIFY_EMAIL: $SUBJECT"
  else
    log err "[notify] Failed to send email."
  fi
}

# ── Predefined notifications ─────────────────────────────────────

notify_cert_issued() {
  local DOMAIN="$1"
  local EXPIRY="$2"
  send_email \
    "[Certificate Resolver] Certificate issued: $DOMAIN" \
    "The wildcard certificate has been issued successfully.

Domain:    $DOMAIN
Wildcard:  *.$DOMAIN
Expires:   $EXPIRY

Certificate files are available in:
  fullchain.pem   — Linux (nginx, Apache, Traefik)
  privkey.pem     — Private key
  certificate.pfx — IIS (Windows)"
}

notify_cert_renewed() {
  local DOMAIN="$1"
  local EXPIRY="$2"
  send_email \
    "[Certificate Resolver] Certificate renewed: $DOMAIN" \
    "The wildcard certificate has been renewed automatically.

Domain:    $DOMAIN
Wildcard:  *.$DOMAIN
Expires:   $EXPIRY

The certificate is now being distributed to the configured targets
(failures are reported per target in separate emails).
The PFX files have been recreated in the container at:
  /certs/$DOMAIN/certificate.pfx         — IIS (Windows)
  /certs/$DOMAIN/certificate-legacy.pfx  — older Windows (e.g. Server 2016)"
}

notify_transfer_success() {
  local DOMAIN="$1"
  local REMOTE_HOST="$2"
  send_email \
    "[Certificate Resolver] Certificate deployed: $DOMAIN → $REMOTE_HOST" \
    "The certificate has been successfully transferred to the target server.

Domain:      $DOMAIN
Target:      $REMOTE_HOST"
}

notify_error() {
  local CONTEXT="$1"
  local DOMAIN="$2"
  local ERROR_MSG="$3"
  send_email \
    "[Certificate Resolver] ERROR: $CONTEXT — $DOMAIN" \
    "An error occurred during certificate processing.

Step:    $CONTEXT
Domain:  $DOMAIN

Error message:
$ERROR_MSG

Check the container logs for details:
  docker logs certificate-resolver"
}

# One consolidated email for a whole distribution run (instead of one per target).
# Usage: notify_distribution_summary <domain> <total> <failed> <details>
notify_distribution_summary() {
  local DOMAIN="$1"
  local TOTAL="$2"
  local FAILED="$3"
  local DETAILS="$4"
  local SUCCEEDED=$((TOTAL - FAILED))
  send_email \
    "[Certificate Resolver] Distribution: $FAILED of $TOTAL target(s) failed — $DOMAIN" \
    "Certificate distribution for $DOMAIN finished with errors.
The certificate itself is valid and was issued/renewed successfully — only
the delivery to the targets below failed.

Domain:   $DOMAIN
Targets:  $TOTAL total, $SUCCEEDED succeeded, $FAILED failed

Failed targets:
$DETAILS
Check the container logs for full details:
  docker logs certificate-resolver"
}
