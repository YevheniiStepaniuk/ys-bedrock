# Backups: Postgres → Cloudflare R2

The `pg-backup` sidecar in the **data** stack ([docker-compose.data.yml](../docker-compose.data.yml),
source in [`backup/`](../backup)) runs once a day and, for **every database** on the server:

1. dumps it with `pg_dump -Fc`, plus the cluster globals (roles) via `pg_dumpall --globals-only`
2. **verifies** that the archive is readable (`pg_restore -l`)
3. **encrypts** it with gpg AES256 using `BACKUP_PASSPHRASE`
4. uploads it to R2, then deletes objects older than `BACKUP_KEEP_DAYS`

```
r2://ys-backups/postgres/
  2026-11-26T030000Z/
    globals.sql.gpg
    app.dump.gpg
    bot1.dump.gpg
  2026-11-27T030000Z/
    ...
```

The image is built **on the VPS** from `backup/Dockerfile`. It is based on `postgres:16-alpine`, so
`pg_dump` always matches the server version, and no third-party image ever sees the credentials.
It runs on `internal` (to reach Postgres) and `backup-egress` (outbound only, to reach R2). Nothing
is published. Memory limit 256M.

> R2 free tier: 10 GB stored, no egress fees. A small pet-project DB with 14 days of compressed dumps
> uses a tiny fraction of that.

---

## Setup

### 1. Create the bucket

Cloudflare dashboard → **R2 Object Storage** → **Create bucket**:
- Name: `ys-backups`
- Location: Automatic, or EU if you prefer
- Leave the default storage class

Leave **Public access** off (the default).

### 2. Create an API token scoped to that bucket

R2 → **Manage R2 API Tokens** → **Create API token**:

| Field | Value |
|---|---|
| Name | `ys-vps-backup` |
| Permissions | **Object Read & Write** (not Admin) |
| Specify bucket(s) | **Apply to specific buckets only** → `ys-backups` |
| TTL | Forever, or set a reminder to rotate it |

Click **Create**, then copy:
- **Access Key ID**
- **Secret Access Key** (it is shown once)
- your **Account ID**, also visible on the R2 overview page

### 3. Configure `.env` on the VPS

```bash
ssh deploy@ys-vps
nano /opt/ys-infra/.env
```

```bash
R2_ACCOUNT_ID=<account id>
R2_ACCESS_KEY_ID=<access key id>
R2_SECRET_ACCESS_KEY=<secret access key>
R2_BUCKET=ys-backups
BACKUP_PASSPHRASE=<generate: openssl rand -base64 48 | tr -d '/+=' | cut -c1-40>
BACKUP_TIME=03:00
BACKUP_KEEP_DAYS=14
COMPOSE_PROFILES=agent,backup     # add `backup` to whatever is already there
```

> ⚠️ **Save `BACKUP_PASSPHRASE` in your password manager now.** Every backup is encrypted with it.
> If the VPS dies together with its `.env`, the backups are **unrecoverable** without it.
> Do not change it casually: older backups stay encrypted with the old passphrase.

### 4. Deploy

Run Actions → **Deploy infra** → **Run workflow** with `stacks` = `data`, or on the VPS:

```bash
cd /opt/ys-infra
docker compose -f docker-compose.data.yml up -d --build --wait
```

### 5. Take the first backup now and test-restore it

```bash
docker exec pg-backup backup.sh
docker exec pg-backup restore.sh list
docker exec pg-backup restore.sh latest app --into app_restore_test --yes
docker exec postgres psql -U app -d app_restore_test -c '\dt'
docker exec postgres dropdb -U app app_restore_test
```

If those commands work, backups are working end to end.

### 6. Optional, recommended: dead-man's switch

The healthcheck turns `pg-backup` **unhealthy** after a failure or 26 h without success, and Beszel
shows that. But if the whole VPS is down, nothing on it can alert you. Add an external check:

1. Sign up at <https://healthchecks.io> (free) and create a check with period **1 day**, grace **2 hours**.
   Connect it to Telegram or email.
2. Set `BACKUP_PING_URL=https://hc-ping.com/<uuid>` in `.env`, then redeploy `data`.

Each run pings `/start`, then success or `/fail`. A missing ping also triggers an alert.

---

## Daily operations

| Task | Command |
|---|---|
| Backup now | `docker exec pg-backup backup.sh` |
| Status | `docker exec pg-backup healthcheck.sh` |
| Scheduler logs | `docker logs pg-backup --tail 50` (or Dozzle → `pg-backup`) |
| List runs | `docker exec pg-backup restore.sh list` |
| Files in a run | `docker exec pg-backup restore.sh show latest` |

## Restore

> Restoring **into an existing database drops and recreates every object** in the dump.
> Rehearse with `--into <scratch db>` first.

```bash
# Safe: restore into a new database and compare
docker exec pg-backup restore.sh latest app --into app_check --yes

# Real: overwrite `app` from the latest backup (interactive confirmation: type the DB name)
docker exec -it pg-backup restore.sh latest app

# A specific point in time
docker exec pg-backup restore.sh list
docker exec -it pg-backup restore.sh 2026-11-25T030000Z app
```

Recommended for the real thing: stop the apps that write to the database first
(`docker compose -f docker-compose.apps.yml stop <svc>`), restore, then start them again.

### Disaster recovery (new VPS)

1. Bootstrap the new VPS and restore `.env`, including the **same `BACKUP_PASSPHRASE`** and the R2 credentials.
2. Deploy the `data` stack with the `backup` profile. Postgres starts empty.
3. Restore each database:
   ```bash
   docker exec pg-backup restore.sh list
   docker exec pg-backup restore.sh latest app --yes
   docker exec pg-backup restore.sh latest bot1 --yes   # …for each *.dump.gpg in `show latest`
   ```
4. Only if you had extra roles beyond `POSTGRES_USER`, restore the globals:
   ```bash
   docker exec pg-backup sh -c '. common.sh; rclone cat "$REMOTE/<run>/globals.sql.gpg" > /tmp/g.gpg \
     && decrypt /tmp/g.gpg /tmp/g.sql && psql -d postgres -f /tmp/g.sql; rm -f /tmp/g.*'
   ```
   On a fresh server, errors like `role "app" already exists` are expected and harmless.
5. Deploy the other stacks.

### Without the sidecar (any machine with rclone, gpg and Postgres client tools)

```bash
export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
  RCLONE_CONFIG_R2_ENDPOINT=https://<account>.r2.cloudflarestorage.com \
  RCLONE_CONFIG_R2_ACCESS_KEY_ID=... RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=...
rclone lsf r2:ys-backups/postgres/
rclone copy r2:ys-backups/postgres/<run>/app.dump.gpg .
gpg --decrypt -o app.dump app.dump.gpg     # prompts for BACKUP_PASSPHRASE
pg_restore -l app.dump | head              # inspect
pg_restore -d <conn string> --clean --if-exists --no-owner app.dump
```

---

## Settings (`.env`)

| Variable | Default | Notes |
|---|---|---|
| `R2_ACCOUNT_ID` | — | Used to build the endpoint `https://<id>.r2.cloudflarestorage.com` |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | — | Object Read & Write token scoped to the bucket |
| `R2_BUCKET` | — | e.g. `ys-backups` |
| `BACKUP_PASSPHRASE` | — | gpg symmetric key. **Keep a copy off the VPS.** |
| `BACKUP_TIME` | `03:00` | Daily, UTC, `HH:MM` |
| `BACKUP_KEEP_DAYS` | `14` | Objects older than this are deleted after each successful run. `0` disables deletion. |
| `BACKUP_PREFIX` | `postgres` | Folder inside the bucket |
| `BACKUP_ON_START` | `false` | `true` runs a backup every time the container starts |
| `BACKUP_PING_URL` | — | healthchecks.io-style URL |

## Troubleshooting

| Symptom | Fix |
|---|---|
| Container restarts with `missing env: ...` | Fill in the listed `.env` vars, then redeploy `data`. |
| `FAILED: upload ...` / `403 AccessDenied` | Token not scoped to this bucket, or not **Object Read & Write**. Check `R2_ACCOUNT_ID`. |
| `decrypt failed (wrong BACKUP_PASSPHRASE?)` | The run was made with a different passphrase. Use the one that was active then. |
| `pg-backup` unhealthy: `last backup failed: ...` | See `docker logs pg-backup`, fix, then run `docker exec pg-backup backup.sh`. Health clears on success. |
| Restore: `role "x" does not exist` | Restore the globals first (DR step 4), or keep `--no-owner` (the default in `restore.sh`). |

## Not covered

- **Redis** is not backed up. It runs with AOF on the `redis-data` volume and is treated as cache
  or ephemeral state. If an app stores durable data in Redis, revisit this.
- **Point-in-time recovery** (WAL archiving) is not set up. The worst case is losing up to 24 h of data.
  For more frequent backups, run `backup.sh` more often (see `entrypoint.sh`).
