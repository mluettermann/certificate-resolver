#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ═══════════════════════════════════════════════════════════════
# validate-targets.sh — Sanity-check cert-targets.yml at container start
#
# Catches config mistakes early (bad YAML, duplicate domain keys, unknown
# target types, missing required fields, missing SSH key files) instead of
# only surfacing them the next time a renewal actually fires for that
# domain — which can be weeks later, since acme.sh only renews ~30 days
# before expiry.
#
# Non-fatal by default: every issue is logged and — if SMTP is configured
# (see notify.sh) — mailed as one consolidated summary, but the container
# still starts (a bad target for domain X shouldn't stop acme-dns/renewal
# for every other correctly configured domain). Set CR_STRICT_TARGETS=true
# in .env to abort startup instead when issues are found.
#
# Called by entrypoint.sh before supervisord starts. Can also be run
# manually:
#   docker exec -it certificate-resolver /scripts/validate-targets.sh
# ═══════════════════════════════════════════════════════════════

set -eo pipefail
source /scripts/notify.sh

TARGETS_FILE="${TARGETS_FILE:-/data/cert-targets.yml}"

if [ ! -f "$TARGETS_FILE" ]; then
  log info "[validate-targets] No cert-targets.yml found at $TARGETS_FILE — nothing to validate."
  exit 0
fi

ISSUES=$(python3 - "$TARGETS_FILE" <<'PYEOF'
import os, sys, yaml

path = sys.argv[1]
issues = []

# ── Duplicate-key-aware loader ──────────────────────────────────
# Plain yaml.safe_load silently keeps only the LAST of two identical
# mapping keys (e.g. two "example.com:" blocks under targets:) — the
# first block's targets would vanish with no warning at all.
class DupCheckLoader(yaml.SafeLoader):
    pass

def _no_dup_mapping(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            issues.append(
                f"Duplicate key '{key}' near line {key_node.start_mark.line + 1} "
                "— the earlier entry for this key is silently overwritten."
            )
        value = loader.construct_object(value_node, deep=deep)
        mapping[key] = value
    return mapping

DupCheckLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_dup_mapping)

try:
    with open(path) as f:
        data = yaml.load(f, Loader=DupCheckLoader)
except yaml.YAMLError as e:
    print(f"FATAL: {path} is not valid YAML: {e}")
    sys.exit(0)
except Exception as e:
    print(f"FATAL: could not read {path}: {e}")
    sys.exit(0)

if data is None:
    print(f"FATAL: {path} is empty.")
    sys.exit(0)

if not isinstance(data, dict) or "targets" not in data:
    print(f"FATAL: {path} has no top-level 'targets:' key.")
    sys.exit(0)

targets = data["targets"]
if not isinstance(targets, dict):
    print("FATAL: 'targets:' must be a mapping of domain -> list of targets.")
    sys.exit(0)

# Kept in sync with the case statement in deploy.sh.
KNOWN_TYPES = {
    "ssh", "traefik-ssh", "nginx-ssh", "apache-ssh", "windows-ssh",
    "sftp-drop", "proxmox", "esxi",
}
# Types that shell out via ssh/scp with a private key (default
# /data/ssh/id_ed25519) — checked in REQUIRED.get() plus a common SSH key
# check.
SSH_LIKE = {"ssh", "traefik-ssh", "nginx-ssh", "apache-ssh", "windows-ssh", "proxmox", "esxi"}

# Mirrors the "missing in target configuration" checks each deployer
# script does for itself, just surfaced at startup instead of at the next
# renewal for that domain.
REQUIRED = {
    "ssh":          ["host", "remote_cert_dir"],
    "traefik-ssh":  ["host", "remote_cert_dir"],
    "nginx-ssh":    ["host", "remote_cert_dir"],
    "apache-ssh":   ["host", "remote_cert_dir"],
    "windows-ssh":  ["host", "remote_cert_dir"],
    "proxmox":      ["host"],
    "esxi":         ["host"],
}

for domain, entries in targets.items():
    if not isinstance(entries, list):
        issues.append(f"[{domain}]: value under this domain must be a list of targets, got {type(entries).__name__}.")
        continue
    if len(entries) == 0:
        issues.append(f"[{domain}]: no targets defined (empty list) — certificate will be issued but never deployed anywhere.")
        continue

    for i, t in enumerate(entries, start=1):
        if not isinstance(t, dict):
            issues.append(f"[{domain}] target #{i}: must be a mapping, got {type(t).__name__}.")
            continue

        # deploy.sh defaults a missing 'type' to "ssh" — match that here so
        # the required-field check below looks at the right rules.
        ttype = t.get("type", "ssh")
        label = f"[{domain}] target #{i} (type={ttype})"

        if ttype not in KNOWN_TYPES:
            issues.append(f"{label}: unknown type — deploy.sh will skip this target silently at renewal time.")
            continue

        for field in REQUIRED.get(ttype, []):
            if not t.get(field):
                issues.append(f"{label}: missing required field '{field}'.")

        if ttype == "sftp-drop" and not t.get("sftp_users"):
            issues.append(f"{label}: missing required field 'sftp_users'.")

        if ttype in SSH_LIKE:
            key_path = t.get("key") or "/data/ssh/id_ed25519"
            if not os.path.isfile(key_path):
                issues.append(f"{label}: SSH key file not found in container: {key_path}")
            af = str(t.get("address_family") or os.environ.get("SSH_ADDRESS_FAMILY") or "any")
            if af not in ("any", "inet", "inet6"):
                issues.append(f"{label}: invalid address_family '{af}' (allowed: any, inet, inet6) — deploy will fail.")

for issue in issues:
    print(issue)
PYEOF
)

if [ -z "$ISSUES" ]; then
  log info "[validate-targets] $TARGETS_FILE looks clean."
  exit 0
fi

ISSUE_COUNT=$(printf '%s\n' "$ISSUES" | grep -c .)
log err "[validate-targets] Found $ISSUE_COUNT issue(s) in $TARGETS_FILE:"
printf '%s\n' "$ISSUES" | while IFS= read -r line; do
  [ -z "$line" ] && continue
  log err "[validate-targets]   - $line"
done

notify_error "cert-targets.yml validation" "(startup check)" "$ISSUES"

if [ "${CR_STRICT_TARGETS:-false}" = "true" ]; then
  log err "[validate-targets] CR_STRICT_TARGETS=true — aborting startup due to the issue(s) above."
  exit 1
fi

exit 0
