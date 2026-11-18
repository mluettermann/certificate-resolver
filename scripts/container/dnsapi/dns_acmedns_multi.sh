#!/usr/bin/env sh
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck disable=SC2034
# ═══════════════════════════════════════════════════════════════
# dns_acmedns_multi — acme.sh DNS hook for multi-name (SAN) certificates
#
# Installed into /opt/acme.sh/dnsapi/ and used by issue.sh --san.
#
# Why not the stock dns_acmedns hook?
#   dns_acmedns uses ONE acme-dns account for every name in a certificate.
#   acme-dns keeps only the two most recent TXT values per account, so a
#   certificate with three or more names would lose earlier challenges
#   before Let's Encrypt validates them. This hook instead looks up the
#   acme-dns credentials per challenge name (_acme-challenge.<name>) in
#   acmedns-credentials.json, i.e. every hostname has its own registration
#   (created by: /scripts/setup.sh name1 name2 ...).
#
# Options (environment):
#   ACMEDNS_BASE_URL    acme-dns API   (default: http://localhost:8080)
#   ACMEDNS_CREDS_FILE  credentials    (default: /data/acmedns-credentials.json)
# ═══════════════════════════════════════════════════════════════

dns_acmedns_multi_info='acme-dns with per-name credentials (certificate-resolver)'

#Usage: dns_acmedns_multi_add  _acme-challenge.www.example.com  "txtvalue"
dns_acmedns_multi_add() {
  fulldomain=$1
  txtvalue=$2
  _info "Using acme-dns (per-name credentials)"
  _debug fulldomain "$fulldomain"
  _debug txtvalue "$txtvalue"

  _amm_base="${ACMEDNS_BASE_URL:-http://localhost:8080}"
  _amm_creds_file="${ACMEDNS_CREDS_FILE:-/data/acmedns-credentials.json}"

  if [ ! -f "$_amm_creds_file" ]; then
    _err "acme-dns credentials file not found: $_amm_creds_file"
    return 1
  fi

  # Prints "username<TAB>password<TAB>subdomain" or nothing.
  _amm_creds=$(python3 - "$_amm_creds_file" "$fulldomain" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
key = sys.argv[2].rstrip('.')
e = data.get(key)
if e is None:
    e = next((v for k, v in data.items() if k.lower() == key.lower()), None)
if e:
    print('\t'.join([e['username'], e['password'], e['subdomain']]))
PY
)

  _amm_user=$(printf '%s' "$_amm_creds" | cut -f1)
  _amm_pass=$(printf '%s' "$_amm_creds" | cut -f2)
  _amm_sub=$(printf '%s' "$_amm_creds" | cut -f3)

  if [ -z "$_amm_user" ] || [ -z "$_amm_pass" ] || [ -z "$_amm_sub" ]; then
    _err "No acme-dns registration for $fulldomain — run: /scripts/setup.sh ${fulldomain#_acme-challenge.}"
    return 1
  fi

  export _H1="X-Api-User: $_amm_user"
  export _H2="X-Api-Key: $_amm_pass"
  data="{\"subdomain\":\"$_amm_sub\", \"txt\": \"$txtvalue\"}"
  _debug data "$data"

  response="$(_post "$data" "$_amm_base/update" "" "POST" "application/json")"
  _debug response "$response"

  # Do not leak the acme-dns auth headers into later requests.
  _H1=""
  _H2=""

  if ! echo "$response" | grep "\"$txtvalue\"" >/dev/null; then
    _err "invalid response of acme-dns for $fulldomain"
    return 1
  fi
  return 0
}

#Usage: dns_acmedns_multi_rm  fulldomain  txtvalue
# acme-dns rotates TXT values itself — nothing to remove.
dns_acmedns_multi_rm() {
  _debug "dns_acmedns_multi_rm: nothing to do for $1"
  return 0
}