# syntax=docker/dockerfile:1
FROM debian:bookworm-slim

ARG SING_BOX_VERSION=1.11.4
ARG TARGETARCH
ARG TARGETVARIANT

ENV TZ=Asia/Shanghai \
    VLESS_PORT=8001 \
    VMESS_PORT=8002

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl jq bash tzdata tar gzip procps; \
    rm -rf /var/lib/apt/lists/*

# ---------- sing-box v1.11.4 ----------
RUN set -eux; \
    case "${TARGETARCH}${TARGETVARIANT}" in \
        amd64)   SB_ARCH=amd64  ;; \
        arm64)   SB_ARCH=arm64  ;; \
        armv7)   SB_ARCH=armv7  ;; \
        armv6)   SB_ARCH=armv6  ;; \
        386)     SB_ARCH=386    ;; \
        *) echo "unsupported arch: ${TARGETARCH}${TARGETVARIANT}" >&2; exit 1 ;; \
    esac; \
    PKG="sing-box-${SING_BOX_VERSION}-linux-${SB_ARCH}"; \
    curl -fsSL --retry 3 --retry-delay 2 -o /tmp/sing-box.tar.gz \
        "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${PKG}.tar.gz"; \
    tar -xzf /tmp/sing-box.tar.gz -C /tmp; \
    install -m 0755 "/tmp/${PKG}/sing-box" /usr/local/bin/sing-box; \
    rm -rf /tmp/*; \
    sing-box version

# ---------- cloudflared (latest) ----------
RUN set -eux; \
    case "${TARGETARCH}${TARGETVARIANT}" in \
        amd64)   CF_ARCH=amd64 ;; \
        arm64)   CF_ARCH=arm64 ;; \
        armv7)   CF_ARCH=arm   ;; \
        armv6)   CF_ARCH=arm   ;; \
        386)     CF_ARCH=386   ;; \
        *) echo "unsupported arch: ${TARGETARCH}${TARGETVARIANT}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 3 --retry-delay 2 -o /usr/local/bin/cloudflared \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"; \
    chmod +x /usr/local/bin/cloudflared; \
    cloudflared --version

WORKDIR /app
COPY config.json /app/config.json
COPY start.sh  /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

EXPOSE 8001 8002
CMD ["/usr/local/bin/start.sh"]