# Postgres -> Cloudflare R2 backup sidecar.
# Based on the same postgres image as the server, so pg_dump/pg_restore versions always match.
FROM postgres:16-alpine

RUN apk add --no-cache rclone gnupg tzdata \
 # Empty config: remote "r2" is defined purely via RCLONE_CONFIG_R2_* env (silences "config not found").
 && mkdir -p /root/.config/rclone && touch /root/.config/rclone/rclone.conf

COPY --chmod=755 common.sh backup.sh restore.sh healthcheck.sh entrypoint.sh /usr/local/bin/

ENV GNUPGHOME=/tmp/gnupg \
    WORK_DIR=/work

WORKDIR /work
ENTRYPOINT ["entrypoint.sh"]
HEALTHCHECK --interval=5m --timeout=10s --start-period=1m CMD ["healthcheck.sh"]
