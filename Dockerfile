# SPDX-License-Identifier: GPL-3.0-or-later
# ═══════════════════════════════════════════════════════════════
# Stage 1: Build acme-dns with CGO (required for sqlite3)
# ═══════════════════════════════════════════════════════════════
FROM golang:1.27-alpine AS builder

RUN apk add --no-cache git gcc musl-dev
ENV CGO_ENABLED=1
RUN go install github.com/joohoi/acme-dns@latest

# ═══════════════════════════════════════════════════════════════
# Stage 2: Final image
# ═══════════════════════════════════════════════════════════════
FROM alpine:3.24

LABEL org.opencontainers.image.title="Certificate Resolver"
LABEL org.opencontainers.image.source="https://github.com/mluettermann/certificate_resolver"
LABEL org.opencontainers.image.licenses="GPL-3.0-or-later"
LABEL description="Wildcard and multi-name (SAN) Let's Encrypt certificates via acme-dns (no DNS provider API required)"

# System packages
RUN apk add --no-cache \
    bash \
    curl \
    openssl \
    python3 \
    py3-yaml \
    supervisor \
    socat \
    ca-certificates \
    msmtp \
    openssh-client \
    gettext \
    coreutils \
    tzdata \
    && rm -rf /var/cache/apk/*

# acme-dns binary from stage 1
COPY --from=builder /go/bin/acme-dns /usr/local/bin/acme-dns
RUN chmod +x /usr/local/bin/acme-dns

# Install acme.sh to /opt/acme.sh (not the home directory)
ENV ACME_HOME=/opt/acme.sh
RUN curl -fsSL https://github.com/acmesh-official/acme.sh/archive/refs/heads/master.tar.gz \
    | tar -xz -C /opt/ \
    && mv /opt/acme.sh-master /opt/acme.sh \
    && chmod +x /opt/acme.sh/acme.sh \
    && ln -sf /opt/acme.sh/acme.sh /usr/local/bin/acme.sh

# Directory structure
RUN mkdir -p /etc/acme-dns /data /certs /scripts /logs

# Configuration files
COPY config/acme-dns.cfg.template /etc/acme-dns/config.cfg.template
COPY config/supervisord.conf      /etc/supervisord.conf

# Scripts
COPY scripts/container/entrypoint.sh     /entrypoint.sh
COPY scripts/container/setup.sh          /scripts/setup.sh
COPY scripts/container/issue.sh          /scripts/issue.sh
COPY scripts/container/delete.sh         /scripts/delete.sh
COPY scripts/container/renew-hook.sh     /scripts/renew-hook.sh
COPY scripts/container/validate-targets.sh /scripts/validate-targets.sh
COPY scripts/container/deploy.sh         /scripts/deploy.sh
COPY scripts/container/renewal-daemon.sh /scripts/renewal-daemon.sh
COPY scripts/container/notify.sh         /scripts/notify.sh
COPY scripts/container/deployers/        /scripts/deployers/
COPY scripts/container/remote/           /scripts/remote/

# acme.sh DNS hook for multi-name (SAN) certificates — one acme-dns
# registration per hostname (used by issue.sh --san)
COPY scripts/container/dnsapi/dns_acmedns_multi.sh /opt/acme.sh/dnsapi/dns_acmedns_multi.sh
RUN chmod +x /entrypoint.sh /scripts/*.sh /scripts/deployers/*.sh

VOLUME ["/data", "/certs"]
EXPOSE 53/udp 53/tcp
ENTRYPOINT ["/entrypoint.sh"]
