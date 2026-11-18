# Security

## What this container can reach

The Certificate Resolver is a high-value target. Please treat it accordingly:

- **SSH keys** in `DATA_ROOT/data/ssh/` can log in to every configured deploy target — often as `root` or a local Windows administrator.
- **Private keys** of all issued certificates are stored under `DATA_ROOT/certs/`.
- **acme-dns credentials** (`acmedns-credentials.json`) allow anyone to obtain certificates for your registered domains.
- The optional **web UI** mounts the Docker socket (`/var/run/docker.sock`) to control the resolver, which is equivalent to root on the Docker host.

## Recommendations

- Only **port 53 (UDP/TCP)** needs to be reachable from the internet. Do not publish the acme-dns HTTP API (port 8080) or the SFTP port to the internet.
- If you use the optional [web UI](https://github.com/mluettermann/certificate-resolver-ui), follow its [SECURITY.md](https://github.com/mluettermann/certificate-resolver-ui/blob/main/SECURITY.md): TLS only, strong `SECRET_KEY`, 2FA for every user, ideally VPN/internal access only.
- Use **dedicated deploy accounts with minimal rights** on the targets instead of `root`/`Administrator` where the target type allows it, and restrict the SSH key on the target side (e.g. `from="<resolver-ip>"` in `authorized_keys`).
- Restrict file permissions on `DATA_ROOT` (`chmod 700`) and back it up encrypted.

## Supported versions

Security fixes are released for the newest major version only (image tag `1` = newest 1.x). Keep the default `RESOLVER_TAG` or update regularly.

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Use GitHub's private vulnerability reporting instead: *Security → Report a vulnerability* in this repository.
