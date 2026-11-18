# Certificate Resolver

Automated wildcard Let's Encrypt certificates without a DNS-provider API — fully self-hosted in a single Docker stack, with a web UI for day-to-day operation.

Supports any number of domains. Issues wildcard certificates for `example.com` and `*.example.com` — or, without wildcard, certificates for an explicit list of hostnames (e.g. `test.example.com` + `www.test.example.com`) — as PEM (fullchain, key, cert) and PFX for IIS. After issuance or renewal, certificates are automatically distributed to all configured targets.

---

## What's in the stack

The `docker-compose.yml` runs three services:

| Service | Container | Purpose |
|---|---|---|
| `certificate-resolver` | `certificate-resolver` | acme-dns server + acme.sh issuance/renewal + distribution |
| `cert-ui` | `certificate-resolver-ui` | Web UI (login + 2FA) to manage domains and targets |
| `sftp` | `certificate-sftp` | SFTP drop (port 2222) for Windows/IIS to fetch PFX files |

The UI image is built from a separate repository ([`certificate-resolver-ui`](https://github.com/mluettermann/certificate-resolver-ui)) and deployed as part of this stack.

---

## How it works

Let's Encrypt requires the **DNS-01 challenge** for wildcard certificates — a TXT record must be set in the DNS zone to prove domain ownership. This normally requires API access to the DNS provider.

This solution uses **acme-dns**: a minimal DNS server dedicated solely to ACME challenges. A CNAME is set once in the DNS zone pointing to acme-dns. From then on, acme-dns manages the TXT records automatically — no further changes to the DNS zone are needed.

```
Let's Encrypt
     │  queries TXT record
     ▼
_acme-challenge.example.com
     │  CNAME (set once)
     ▼
<uuid>.acmedns.auth.example.com
     │  managed by acme-dns
     ▼
This server (port 53)
```

---

## Prerequisites

- Docker + Docker Compose on the server (Docker ≥ 27 recommended for IPv6 support)
- A public, static IP address
- Port 53 (UDP + TCP) reachable from the internet
- Write access to the DNS zone (once per domain)
- A reverse proxy (e.g. Traefik) for the web UI over HTTPS (recommended)

---

## Deployment

Prebuilt images are published to the GitHub Container Registry (`ghcr.io/mluettermann/certificate-resolver`, `ghcr.io/mluettermann/certificate-resolver-ui`), so `docker compose pull` is enough. To build the resolver image yourself instead, run `docker compose build`.

### 1. Prepare the host data layout

All runtime data and config live under `DATA_ROOT` (default `/opt/certificate-resolver`). Run the bootstrap script **once** on the host from a checkout of this repository:

```bash
sudo DATA_ROOT=/opt/certificate-resolver ./scripts/host/bootstrap.sh
```

This creates the directory layout and seeds `cert-targets.yml`, `sftp-users.conf` and the SFTP entrypoint. It is important because Docker would otherwise create *directories* where *files* are expected.

### 2. Set environment variables

When deploying via the Docker CLI, put them in a `.env` next to the compose file (see [`.env-example`](.env-example)). In **Portainer**, set them as stack environment variables.

At minimum:

```env
ACMEDNS_ZONE=acmedns.auth.example.com
SERVER_IP=1.2.3.4
DOMAIN=cert.example.com            # hostname of the web UI (Traefik router)
UI_SECRET_KEY=$(openssl rand -hex 32)
UI_SECURE_COOKIES=true             # the UI runs behind TLS
```

### 3. Set DNS records (once)

```
acmedns.auth.example.com  A   <SERVER_IP>          # points to this server
acmedns.auth.example.com  NS  acmedns.auth.example.com.   # acme-dns is authoritative
```

> **Important:** If a wildcard record (`*.example.com`) exists, make sure it does not shadow the explicit A record for `acmedns.auth.example.com`.

### 4. Deploy

```bash
docker compose pull
docker compose up -d
```

On first start the UI creates an `admin` account. If `UI_ADMIN_PASSWORD` is not set, a random password is generated and printed once — retrieve it with:

```bash
docker compose logs cert-ui | grep -A2 "Initial admin"
```

A password change is enforced on first login.

---

## Environment variables

### Resolver

| Variable | Default | Description |
|---|---|---|
| `ACMEDNS_ZONE` | — | Subdomain acme-dns is authoritative for (required) |
| `SERVER_IP` | — | Public IP of this server (required) |
| `RENEW_HOUR` / `RENEW_MINUTE` | `3` / `0` | Local time of day (in `TZ`) the daily renewal check runs |
| `SKIP_WEEKENDS` | `1` | `1` = no renewal check on Saturday/Sunday, `0` = run daily |
| `TZ` | `Europe/Berlin` | Container time zone (renewal time, weekend check, log timestamps) |
| `SMTP_HOST/PORT/USER/PASSWORD/FROM` | empty | Email notifications (leave empty to disable) |
| `NOTIFY_EMAIL` | empty | Recipient for notifications |
| `ACME_DATA` | `/data/acme` | acme.sh runtime data dir |
| `CR_LOG_LEVEL` | `info` | stdout verbosity for the daemon |
| `CR_LOG_FILE` | `/logs/certificate-resolver.log` | structured resolver log |
| `CR_LOG_MAX_BYTES` / `CR_LOG_BACKUPS` | `5 MB` / `5` | rotation of the above |

### Paths

| Variable | Default | Description |
|---|---|---|
| `DATA_ROOT` | `/opt/certificate-resolver` | Host folder for all runtime data/config |
| `LOG_ROOT` | `/var/log/certificate_resolver` | Single host folder for all log files |

---

## Data & logs on the host

```
/opt/certificate-resolver/        # DATA_ROOT — persistent state
├── data/                        # acme-dns db, acmedns-credentials.json, acme.sh data
├── certs/                       # issued certificates (per domain)
├── ui-data/                     # UI state: users.json, audit.log, login_attempts.json
├── sftp-home/                   # SFTP drop directories
├── cert-targets.yml             # distribution config (also editable in the UI)
└── sftp-users.conf              # SFTP user list

/var/log/certificate_resolver/   # LOG_ROOT — all logs (rotated automatically)
├── acme-dns.log / acme-dns.err.log
├── renewal.log / renewal.err.log
└── certificate-resolver.log
```

`docker logs` shows **status only**; detailed logs live in the files above (size-rotated, no host logrotate required).

---

## Issuing a certificate

Either use the **Domain Setup** tab in the UI, or the CLI:

**Step 1 — Register** (prints the CNAME to add to DNS):
```bash
docker exec certificate-resolver /scripts/setup.sh example.com
```
Add the printed CNAME to the DNS zone:
```
_acme-challenge.example.com  CNAME  <uuid>.acmedns.auth.example.com
```
> **Important:** Set **only the CNAME** — no direct TXT records for `_acme-challenge.example.com`.

**Step 2 — Issue** (after DNS propagation, ~5–10 min):
```bash
docker exec certificate-resolver /scripts/issue.sh example.com
```

**Delete a domain** (certs + acme-dns registration + acme.sh data; the UI also removes it from `cert-targets.yml`):
```bash
docker exec certificate-resolver /scripts/delete.sh example.com
```


### Certificates without wildcard (single / multi-name)

For a certificate that contains only specific hostnames (no `*.`), pass all names to `setup.sh` and use `issue.sh --san`. The **first name is the primary name**: it names the certificate directory (`certs/<primary>/`) and is the domain key in `cert-targets.yml`.

```bash
# 1. Register every hostname (prints one CNAME per name)
docker exec certificate-resolver /scripts/setup.sh test.example.com www.test.example.com

# 2. Add ALL printed CNAMEs to the DNS zone, e.g.
#    _acme-challenge.test.example.com      CNAME  <uuid-1>.acmedns.auth.example.com
#    _acme-challenge.www.test.example.com  CNAME  <uuid-2>.acmedns.auth.example.com

# 3. Issue (after DNS propagation)
docker exec certificate-resolver /scripts/issue.sh --san test.example.com www.test.example.com
```

Notes:
- Every hostname gets its **own acme-dns registration** and CNAME. acme-dns keeps only the two most recent TXT values per registration, so sharing one registration would break certificates with three or more names. The `dns_acmedns_multi` hook (installed into acme.sh) picks the right credentials per name.
- A single hostname works the same way: `issue.sh --san test.example.com`.
- To add a name later, run `setup.sh` for the new name, set its CNAME and re-run `issue.sh --san` with the complete list.
- Renewal works automatically (acme.sh keeps the name list and the hook).
- `delete.sh <primary>` removes the certificate and the acme-dns registrations of all its names — except registrations still used by another certificate.
- A primary name must not collide with a wildcard certificate of the same name (both use `certs/<name>/`).

---

## Certificate files

| File | Usage |
|---|---|
| `fullchain.pem` | Linux — nginx, Apache, HAProxy, Traefik |
| `privkey.pem` | Private key |
| `cert.pem` | Certificate only |
| `certificate.pfx` | Windows IIS (standard AES-256+SHA-256 encoding) |
| `certificate-legacy.pfx` | Windows IIS on older CryptoAPI (e.g. Server 2016) — see `legacy_pfx` under [Certificate distribution](#certificate-distribution) |

Located at `/opt/certificate-resolver/certs/<domain>/` on the host.

---

## Certificate distribution

After issuance/renewal, certificates are distributed according to **`cert-targets.yml`** (editable in the UI's Deploy Setup tab). A failed target no longer fails the whole issuance — the certificate stays valid and a single consolidated email lists any failed targets.

**`ssh`** — SCP transfer to any SSH host (Traefik, nginx, Apache, …):
```yaml
targets:
  example.com:
    - type: ssh
      host: proxy.example.com
      user: root
      port: 22
      key: /data/ssh/id_ed25519
      remote_cert_dir: /opt/traefik/certs
      reload_cmd: "systemctl reload nginx"   # optional
```

**`windows-ssh`** — SCP transfer to a Windows host running an SSH server (Win32-OpenSSH), then automatic import into `Cert:\LocalMachine\My`. The PFX is deleted from the remote host again immediately after import; on a successful deploy the reload script and the domain's cert folder (and `remote_cert_dir` itself, if now empty) are removed too — nothing is left behind on the Windows host beyond the imported certificate and its IIS binding:
```yaml
targets:
  example.com:
    - type: windows-ssh
      host: win-iis-1.example.com
      user: Administrator          # needs local admin rights (LocalMachine\My)
      port: 22
      key: /data/ssh/id_ed25519
      remote_cert_dir: C:\certs
      legacy_pfx: true              # optional (default: false) — see below
      reload_script: /scripts/remote/reload-iis.ps1   # optional, synced before reload_cmd runs
      reload_cmd: 'powershell -File C:\certs\reload-iis.ps1 -Domain {{DOMAIN}}'   # optional
```

- **`legacy_pfx`** — OpenSSL 3.x's default PFX encoding (AES-256+SHA-256) can't be parsed by older Windows CryptoAPI (e.g. Server 2016); `Import-PfxCertificate` then fails there with a misleading "wrong password or AD principal" error even though the password is correct. `renew-hook.sh` always builds a second, legacy-compatible `certificate-legacy.pfx` (RC2/3DES-SHA1) alongside the standard one — set `legacy_pfx: true` on targets that need it; leave it unset on newer Windows hosts to keep the stronger encryption.
- **`reload_script`** — optional path (inside the container) to a `.ps1` file pushed to `remote_cert_dir` before `reload_cmd` runs, e.g. the bundled [`scripts/container/remote/reload-iis.ps1`](scripts/container/remote/reload-iis.ps1), which rebinds the imported certificate to IIS (both classic and SNI bindings). It's re-synced on every deploy, so there's no manual per-host copy to keep up to date, and no drift between hosts.
- **`{{DOMAIN}}`** inside `reload_cmd` is substituted with the actual domain before execution, so it doesn't need to be hardcoded a second time next to the `targets:` key.

The PFX password is a fresh random value generated by `renew-hook.sh` on every issuance/renewal (not a static value from `.env`), sent over the SSH stdin channel — it never appears as a command-line argument or in the remote process list. The container itself doesn't persist it anywhere.

**`sftp-drop`** — Place the PFX for Windows/IIS to fetch via SFTP (use this instead of `windows-ssh` if the host has no SSH server, or you'd rather keep the import a manual/scripted step):
```yaml
targets:
  example.com:
    - type: sftp-drop
      sftp_users: [win-iis-1, win-iis-2]
```

**`proxmox`** — Install directly into Proxmox VE (writes to `/etc/pve/local/`, restarts pveproxy):
```yaml
targets:
  example.com:
    - type: proxmox
      host: proxmox.example.com
      user: root
      port: 22
      key: /data/ssh/id_ed25519
```

**`esxi`** — Install directly into a VMware ESXi host (writes to `/etc/vmware/ssl/rui.crt` + `rui.key`, restarts `hostd` and `vpxa`). Requires SSH enabled on the host (Host Client → Actions → Services → Enable Secure Shell (SSH)); the previous cert/key are backed up to `rui.crt.bak`/`rui.key.bak` on the host before being overwritten:
```yaml
targets:
  example.com:
    - type: esxi
      host: esxi-host1.example.com
      user: root
      port: 22
      key: /data/ssh/id_ed25519
```
If the host is vCenter-managed, vCenter may briefly show it as "certificate not verified" until it re-validates the thumbprint on its own — that reconnect happens on the vCenter side and isn't something this target triggers.

### SSH key setup

The transfer key lives at `/data/ssh/id_ed25519` inside the container (persisted under `DATA_ROOT/data`):

```bash
ssh-keygen -t ed25519 -f ./ssh-key -N ""
docker cp ./ssh-key certificate-resolver:/data/ssh/id_ed25519
docker exec certificate-resolver chmod 600 /data/ssh/id_ed25519
ssh-copy-id -i ./ssh-key.pub root@proxy.example.com
```

### Traefik target host

Traefik needs a file provider with `watch: true`:
```yaml
# traefik.yml (static)
providers:
  file:
    directory: /dynamic
    watch: true
# /dynamic/tls.yml (dynamic)
tls:
  certificates:
    - certFile: /certs/example.com/fullchain.pem
      keyFile:  /certs/example.com/privkey.pem
```

---

## Windows / IIS: SFTP drop

Add a Windows server (run on the host, from a repo checkout):
```bash
./scripts/host/sftp-add-user.sh win-iis-1 /path/to/win-iis-1.pub
docker compose restart sftp
```
Then add the user under the domain in `cert-targets.yml` (or via the UI). Windows fetches `/certs/<domain>/certificate.pfx` via SFTP on port 2222 (key auth).

Import on Windows:
```powershell
Import-PfxCertificate -FilePath "C:\certs\example.com\certificate.pfx" `
  -CertStoreLocation Cert:\LocalMachine\My `
  -Password (ConvertTo-SecureString "YourPfxPassword" -AsPlainText -Force)
```

---

## Automatic renewal

Two processes run inside the resolver container: **acme-dns** (answers challenges) and the **renewal daemon** (checks daily; renews at < 30 days). After renewal, the PFX is rebuilt, certificates are distributed, and a notification is sent. Let's Encrypt certificates expire after 90 days; renewal happens around day 60.

---

## Email notifications

Set `SMTP_*` and `NOTIFY_EMAIL` to receive: certificate issued, renewed, and a single distribution-error summary when targets fail. Leave SMTP empty to disable.

---

## IPv6

To serve deploy targets that only have an AAAA record, enable IPv6 on the network (the host and Docker must support IPv6, Docker ≥ 27 enables IPv6 NAT by default):

```yaml
networks:
  default:
    enable_ipv6: true
    ipam:
      config:
        - subnet: fd00:c0ff:ee::/64
```

---

## Troubleshooting

**"Incorrect TXT record":** check for conflicting direct TXT records — only the CNAME should exist:
```bash
dig TXT _acme-challenge.example.com @8.8.8.8
```

**"forbidden" on TXT update** (stale credentials after re-registration): remove the entry and re-run setup:
```bash
docker exec certificate-resolver /scripts/delete.sh example.com   # or remove just the creds entry
docker exec certificate-resolver /scripts/setup.sh example.com
```
Then update the CNAME in the DNS zone with the new value.

**Web UI not reachable behind Traefik:** verify `DOMAIN` is set (an empty value yields `Host(\`\`)`), and that both Traefik and `cert-ui` share the `traefik_proxy` network. Test the backend directly:
```bash
docker run --rm --network traefik_proxy curlimages/curl -s http://certificate-resolver-ui:5000/health
```

**Detailed logs:** see `/var/log/certificate_resolver/` (e.g. `tail -f .../renewal.log`).

**`windows-ssh` import fails with "The PFX file you are trying to import requires either a different password or membership in an Active Directory principal"** even though the password is correct: the target's Windows CryptoAPI can't parse OpenSSL 3.x's default PFX encoding (AES-256+SHA-256). Set `legacy_pfx: true` on that target — see [Certificate distribution](#certificate-distribution).

**`windows-ssh` reload fails with "The argument '...' to the -File parameter does not exist"**: the `reload_script` file was never synced to the host, either because `reload_script` isn't set on the target, or because the container is running an older image that predates the sync logic — pull or rebuild it (`docker compose pull` / `docker compose build`) and recreate the container (`docker compose up -d --force-recreate`).

---

## Project structure

```
.
├── docker-compose.yml              # resolver + cert-ui + sftp
├── Dockerfile
├── .env-example
├── cert-targets.yml                # distribution targets (seed)
├── sftp-users.conf
├── offline-cert-target-yml-creator.html   # offline editor for cert-targets.yml
├── config/
│   ├── acme-dns.cfg.template
│   └── supervisord.conf            # logs to rotating files in /logs
└── scripts/
    ├── sftp-entrypoint.sh
    ├── container/
    │   ├── entrypoint.sh
    │   ├── setup.sh                # register a domain
    │   ├── issue.sh                # issue a certificate (wildcard or --san)
    │   ├── delete.sh               # remove a domain completely
    │   ├── renew-hook.sh           # post-renewal: PFX + distribution (non-fatal)
    │   ├── deploy.sh               # distribution dispatcher (consolidated email)
    │   ├── validate-targets.sh     # sanity-checks cert-targets.yml at startup
    │   ├── renewal-daemon.sh
    │   ├── notify.sh               # logging (rotating) + email
    │   ├── dnsapi/
    │   │   └── dns_acmedns_multi.sh   # acme.sh hook: per-name acme-dns credentials (SAN)
    │   ├── deployers/
    │   │   ├── deploy-ssh.sh
    │   │   ├── deploy-windows-ssh.sh
    │   │   ├── deploy-sftp-drop.sh
    │   │   ├── deploy-proxmox.sh
    │   │   └── deploy-esxi.sh
    │   └── remote/
    │       └── reload-iis.ps1      # optional windows-ssh reload_script (IIS rebind)
    └── host/
        ├── bootstrap.sh            # prepare DATA_ROOT layout (run once)
        └── sftp-add-user.sh        # add an SFTP user
```

---

## Security

This container holds SSH keys that can log in to every deploy target, and the UI controls it through the Docker socket. Please read [SECURITY.md](SECURITY.md) before exposing anything to the internet.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).
