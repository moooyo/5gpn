# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# BuildKit consumes this special argument for image config/history timestamps.
# The release exporter additionally sets rewrite-timestamp=true so filesystem
# metadata inside every layer is normalized to the same value.
ARG SOURCE_DATE_EPOCH=0

# The initial Docker runtime is deliberately Linux/amd64-only. The component
# preparation step selects the matching digest-pinned mihomo asset.
FROM --platform=linux/amd64 debian:13-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258

ARG SOURCE_DATE_EPOCH
ARG VCS_REF="unknown"
ARG VERSION="dev"
ENV DEBIAN_SNAPSHOT=20260809T000000Z

LABEL org.opencontainers.image.title="5gpn" \
      org.opencontainers.image.description="5gpn monolithic DNS-steering gateway" \
      org.opencontainers.image.source="https://github.com/moooyo/5gpn" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.version="${VERSION}" \
      io.5gpn.source-date-epoch="${SOURCE_DATE_EPOCH}" \
      io.5gpn.debian.snapshot="${DEBIAN_SNAPSHOT}" \
      io.5gpn.bootstrap-ca="curl-ca-bundle-2026-07-16"

# debian:13-slim intentionally omits a CA bundle. Component preparation also
# verifies one dated Mozilla bundle so APT can reach the immutable Debian
# snapshot over HTTPS. Debian's pinned ca-certificates package replaces it.
COPY --chmod=0644 docker/build/components/bootstrap-ca.pem /etc/ssl/certs/ca-certificates.crt

# GitHub release assets are intentionally absent from this layer. They must
# already exist below docker/build/components after release/pins.env has been
# parsed by release/pins.sh and checked by docker/prepare-components.sh.
RUN printf '%s\n' \
        "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ trixie main" \
        "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ trixie-updates main" \
        "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}/ trixie-security main" \
        > /etc/apt/sources.list \
    && chmod 0644 /etc/ssl/certs/ca-certificates.crt \
    && rm -f /etc/apt/sources.list.d/debian.sources \
    && apt-get \
        -o Acquire::Check-Valid-Until=false \
        -o Acquire::https::CaInfo=/etc/ssl/certs/ca-certificates.crt \
        update \
    && DEBIAN_FRONTEND=noninteractive apt-get \
        -o Acquire::https::CaInfo=/etc/ssl/certs/ca-certificates.crt \
        install -y --no-install-recommends \
        bash \
        ca-certificates \
        certbot \
        coreutils \
        findutils \
        iproute2 \
        jq \
        openssl \
        passwd \
        python3-certbot-dns-cloudflare \
        util-linux \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/* /var/log/apt/* \
    && rm -f /var/log/alternatives.log /var/log/dpkg.log \
    && groupadd --gid 10001 fivegpn \
    && useradd --uid 10001 --gid 10001 --home-dir /nonexistent \
        --no-create-home --shell /usr/sbin/nologin fivegpn \
    && chage --lastday 0 fivegpn \
    && rm -f \
        /etc/group- \
        /etc/gshadow- \
        /etc/passwd- \
        /etc/shadow- \
        /etc/subgid- \
        /etc/subuid- \
    && install -d -o 10001 -g 10001 -m 0750 \
        /etc/5gpn \
        /etc/5gpn/mihomo \
        /run/5gpn \
        /run/5gpn-bootstrap \
    && install -d -o 10001 -g 10001 -m 0711 \
        /etc/5gpn/mihomo/5gpn \
    && install -d -o 10001 -g 10001 -m 0755 \
        /opt/5gpn/ui \
        /opt/5gpn/ui/generations \
    && install -d -o 10001 -g 10001 -m 0751 \
        /etc/5gpn/cert \
    && install -d -o 10001 -g 10001 -m 0750 \
        /etc/5gpn/cert/dot \
        /etc/5gpn/cert/dot/generations \
        /etc/5gpn/cert/console \
        /etc/5gpn/cert/console/generations \
        /etc/5gpn/intercept \
        /etc/5gpn/intercept/tls \
    && install -d -o 10001 -g 10001 -m 0700 \
        /etc/5gpn/intercept-ca \
        /etc/5gpn/letsencrypt \
        /etc/5gpn/letsencrypt/work \
        /etc/5gpn/letsencrypt/log \
    && install -d -o root -g root -m 0755 \
        /opt/5gpn/bin \
        /opt/5gpn/scripts \
        /run/5gpn-bootstrap-input \
        /usr/share/5gpn \
        /usr/share/5gpn/ui \
        /usr/share/doc/5gpn \
    && printf '%s\n' '5gpn-config' > /etc/5gpn/.5gpn-owned \
    && printf '%s\n' '5gpn-docker-state-v2' > /etc/5gpn/.5gpn-docker-schema \
    && printf '%s\n' '5gpn-cert-root-v1' > /etc/5gpn/cert/.5gpn-cert-root-owned \
    && printf '%s\n' '5gpn-cert-role-v1:dot' > /etc/5gpn/cert/dot/.5gpn-cert-role-owned \
    && printf '%s\n' '5gpn-cert-role-v1:console' > /etc/5gpn/cert/console/.5gpn-cert-role-owned \
    && printf '%s\n' '5gpn-intercept-ca-v1' > /etc/5gpn/intercept-ca/.5gpn-intercept-ca-owned \
    && printf '%s\n' '5gpn-docker-intercept-v1' > /etc/5gpn/intercept/.5gpn-docker-intercept-owned \
    && printf '%s\n' '5gpn-docker-letsencrypt-v1' > /etc/5gpn/letsencrypt/.5gpn-docker-letsencrypt-owned \
    && printf '%s\n' '5gpn-ui-generations' > /opt/5gpn/ui/.5gpn-zashboard-owned \
    && chown 10001:10001 \
        /etc/5gpn/.5gpn-owned /etc/5gpn/.5gpn-docker-schema \
        /etc/5gpn/cert/.5gpn-cert-root-owned \
        /etc/5gpn/cert/dot/.5gpn-cert-role-owned \
        /etc/5gpn/cert/console/.5gpn-cert-role-owned \
        /etc/5gpn/intercept-ca/.5gpn-intercept-ca-owned \
        /etc/5gpn/intercept/.5gpn-docker-intercept-owned \
        /etc/5gpn/letsencrypt/.5gpn-docker-letsencrypt-owned \
        /opt/5gpn/ui/.5gpn-zashboard-owned \
    && chmod 0644 \
        /etc/5gpn/.5gpn-owned /etc/5gpn/.5gpn-docker-schema \
        /etc/5gpn/cert/.5gpn-cert-root-owned \
        /etc/5gpn/cert/dot/.5gpn-cert-role-owned \
        /etc/5gpn/cert/console/.5gpn-cert-role-owned \
        /etc/5gpn/intercept-ca/.5gpn-intercept-ca-owned \
        /opt/5gpn/ui/.5gpn-zashboard-owned \
    && chmod 0600 \
        /etc/5gpn/intercept/.5gpn-docker-intercept-owned \
        /etc/5gpn/letsencrypt/.5gpn-docker-letsencrypt-owned

COPY --chmod=0755 docker/build/components/5gpn-mihomo /opt/5gpn/bin/5gpn-mihomo
COPY --chmod=0644 docker/build/components/manifest.env /usr/share/5gpn/components.env
COPY docker/build/components/ui/ /usr/share/5gpn/ui/
COPY --chmod=0644 etc/mihomo/config.yaml.tmpl /usr/share/5gpn/config.yaml.tmpl
COPY --chmod=0755 docker/docker-public-cert.sh /opt/5gpn/scripts/docker-public-cert.sh
COPY --chmod=0755 docker/docker-intercept-cert.sh /opt/5gpn/scripts/docker-intercept-cert.sh
COPY --chmod=0755 scripts/publication-fs.sh /opt/5gpn/scripts/publication-fs.sh
COPY --chmod=0755 scripts/cert-role-ctl.sh /opt/5gpn/scripts/cert-role-ctl.sh
COPY --chmod=0755 scripts/ui-generation.sh /opt/5gpn/scripts/ui-generation.sh
COPY --chmod=0755 scripts/gen-ios-profile.sh /opt/5gpn/scripts/gen-ios-profile.sh
COPY --chmod=0755 docker/entrypoint.sh /opt/5gpn/bin/docker-entrypoint.sh
COPY --chmod=0644 LICENSE THIRD_PARTY_NOTICES.md /usr/share/doc/5gpn/

ENV FIVEGPN_RUNTIME=container \
    HOME=/run/5gpn \
    PYTHONDONTWRITEBYTECODE=1 \
    SAFE_PATHS=/etc/5gpn/cert/console:/etc/5gpn/cert/dot:/etc/5gpn/intercept/tls:/opt/5gpn/ui

USER 10001:10001
WORKDIR /etc/5gpn/mihomo
VOLUME ["/etc/5gpn", "/opt/5gpn/ui"]
STOPSIGNAL SIGTERM
ENTRYPOINT ["/opt/5gpn/bin/docker-entrypoint.sh"]
