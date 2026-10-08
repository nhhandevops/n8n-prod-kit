# compose/backup/Dockerfile — the backup sidecar of the n8n Production Kit.
#
# Base = the SAME Postgres image the stack runs (passed in by docker-compose.yml from versions.env), so pg_dump /
# pg_restore / initdb always match the server version. Added on top, each download pinned by sha256 (computed from the
# real release artifacts on 2026-10-08; rclone's also match its published SHA256SUMS):
#   age          encrypts every bundle to two recipients (host key + offline recovery key)
#   rclone       copies bundles to every target in BACKUP_REMOTES (local paths, Cloudflare R2, AWS S3, any rclone remote)
#   supercronic  cron for containers: runs the nightly backup and the weekly restore test, logs to stdout
# Runs as uid 70 (postgres) — the restore test starts a scratch Postgres, which refuses to run as root.
ARG BASE_IMAGE=postgres:18.6-alpine
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

ARG TARGETARCH
# PKG_ prefix on purpose: rclone treats ANY RCLONE_<FLAG> environment variable as a flag (build args are visible as
# environment to RUN) — an ARG named RCLONE_VERSION made `rclone version` fail with "invalid value ... --version".
ARG PKG_AGE_VERSION=v1.3.2
ARG PKG_AGE_SHA256_AMD64=cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10
ARG PKG_AGE_SHA256_ARM64=6b8dc4333c53a5a57c9e5834e3a48f92605d7154014cd07269ff3327db5d37f4
ARG PKG_RCLONE_VERSION=v1.75.1
ARG PKG_RCLONE_SHA256_AMD64=982b5aa772841168f8e380f139e9e787b2a105403e32b94da8676a0e1c0a13ab
ARG PKG_RCLONE_SHA256_ARM64=03f2504174034b6d004152ed7369251c9a9ec1f7e0836eda420f5c7a5ec0dff9
ARG PKG_SUPERCRONIC_VERSION=v0.2.49
ARG PKG_SUPERCRONIC_SHA256_AMD64=a53ae236602c7338aba3fbaff40bda6300eae3b9fedb8261eb06cfe3724430c1
ARG PKG_SUPERCRONIC_SHA256_ARM64=02aa0cb229ba09050cba6638059dadb9eedc2276632ea43d6a57a2f8c1629dd5

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# bash: the scripts; jq: manifests/metrics; curl: downloads + Telegram; openssl: credential decrypt check in the
# restore test; tzdata: cron schedules in GENERIC_TIMEZONE; coreutils: sha256sum/date -d with GNU semantics.
RUN apk add --no-cache bash jq curl openssl tzdata coreutils

WORKDIR /tmp
RUN arch="${TARGETARCH:-amd64}"; \
    case "${arch}" in \
      amd64) age_sum="${PKG_AGE_SHA256_AMD64}"; rclone_sum="${PKG_RCLONE_SHA256_AMD64}"; cron_sum="${PKG_SUPERCRONIC_SHA256_AMD64}" ;; \
      arm64) age_sum="${PKG_AGE_SHA256_ARM64}"; rclone_sum="${PKG_RCLONE_SHA256_ARM64}"; cron_sum="${PKG_SUPERCRONIC_SHA256_ARM64}" ;; \
      *) echo "unsupported architecture: ${arch}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o age.tgz "https://github.com/FiloSottile/age/releases/download/${PKG_AGE_VERSION}/age-${PKG_AGE_VERSION}-linux-${arch}.tar.gz"; \
    echo "${age_sum}  age.tgz" | sha256sum -c -; \
    tar -xzf age.tgz; \
    install -m 0755 age/age age/age-keygen /usr/local/bin/; \
    curl -fsSL -o rclone.zip "https://downloads.rclone.org/${PKG_RCLONE_VERSION}/rclone-${PKG_RCLONE_VERSION}-linux-${arch}.zip"; \
    echo "${rclone_sum}  rclone.zip" | sha256sum -c -; \
    unzip -q rclone.zip; \
    install -m 0755 "rclone-${PKG_RCLONE_VERSION}-linux-${arch}/rclone" /usr/local/bin/rclone; \
    curl -fsSL -o supercronic "https://github.com/aptible/supercronic/releases/download/${PKG_SUPERCRONIC_VERSION}/supercronic-linux-${arch}"; \
    echo "${cron_sum}  supercronic" | sha256sum -c -; \
    install -m 0755 supercronic /usr/local/bin/supercronic; \
    rm -rf /tmp/*; \
    # no `| head` here: under pipefail the SIGPIPE it causes fails the build
    age --version; rclone version | sed -n 1p; supercronic -version 2>&1 | sed -n 1p

COPY --chmod=0755 *.sh /opt/backup/

# Mount points for the backup_state / backup_work volumes, owned by uid 70: Docker copies this ownership into a NEW
# named volume on first use (existing volumes are fixed by scripts/backup-perms.sh).
RUN mkdir -p /state /work && chown 70:70 /state /work

# HOME/XDG on the tmpfs: the root filesystem is read-only and rclone wants a cache dir; RCLONE_CONFIG points at a file
# that never exists — every remote is defined through RCLONE_CONFIG_<NAME>_* environment variables instead.
ENV HOME=/tmp \
    XDG_CACHE_HOME=/tmp/.cache \
    RCLONE_CONFIG=/tmp/rclone-unused.conf
USER 70:70
WORKDIR /tmp
ENTRYPOINT ["/opt/backup/entrypoint.sh"]
