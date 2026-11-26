# WordLearning (`words.stepaniuk.me`)

WordLearning runs in the `apps` stack as two services, on one origin:

| Service     | Image                                              | Networks                    | Routed by Traefik                                  |
|-------------|----------------------------------------------------|-----------------------------|----------------------------------------------------|
| `words-api` | `ghcr.io/yevheniistepaniuk/wordlearningapp-api`    | `proxy`, `internal`, `words` | `https://words.stepaniuk.me/api*` and `/health`    |
| `words-web` | `ghcr.io/yevheniistepaniuk/wordlearningapp-web`    | `proxy`, `words`            | every other path on `https://words.stepaniuk.me`   |

- **TLS** is Traefik's (Let's Encrypt, like every other router). The web image is Caddy with the
  built PWA; it runs with `DOMAIN=":80"`, so it serves plain HTTP inside Docker and never asks
  for a certificate.
- **`/api` and `/health` go straight to the API, not through the web image's Caddy.** Caddy would
  replace `X-Forwarded-For` with Traefik's address, and the API's per-IP auth-failure limit would
  count every client as one. Traefik drops a client's own `X-Forwarded-*` headers and sets the real
  address, and the API runs with `TRUST_PROXY=true`.
- **Headers.** The API router uses `secure-headers@file`. The web router adds none: the web
  image already sends HSTS, `nosniff`, `Referrer-Policy: same-origin`, the CSP and the
  cache headers the installed PWA relies on.
- **Data.** The API uses the shared `postgres` (database `wordlearning`, created once by hand,
  see below) and the shared `redis` (db `1`). It is on `proxy` as well as `internal` because it
  calls OpenRouter, and `internal` has no internet. `pg-backup` dumps every database, so
  `wordlearning` is in the nightly backup without any change.
- **Secrets.** App secrets live in `/opt/ys-infra/.env.wordlearning` on the server, apart from the
  infra `.env`, so the API never sees the infra secrets. Only the shared Postgres/Redis credentials
  come from `.env`. CI never touches either file (`.env.*` is gitignored).
- The Telegram bot from the WordLearning repo is not deployed here.

## Settings

All optional. They are not in `.env.example`; add them to `/opt/ys-infra/.env` only if you want
something other than the default.

| Variable            | Default              | What it does                                                    |
|---------------------|----------------------|-----------------------------------------------------------------|
| `WORDS_TAG`         | `latest`             | Image tag for both images, e.g. `v0.1.0`. Pin it.               |
| `WORDS_DOMAIN`      | `words.stepaniuk.me` | Host for both routers and the API's `WEB_ORIGIN` (passkeys).    |
| `WORDS_POSTGRES_DB` | `wordlearning`       | Database name on the shared Postgres.                           |

`/opt/ys-infra/.env.wordlearning` holds the app's own settings. Any variable from the WordLearning
repo's `.env.example` works here, except the ones the compose file sets itself (`DATABASE_URL`,
`REDIS_URL`, `PORT`, `TRUST_PROXY`, `WEB_ORIGIN`):

```text
OPENROUTER_API_KEY=sk-or-...
API_TOKEN=<openssl rand -hex 32>
WEB_PASSWORD_HASH=scrypt:...
```

- `OPENROUTER_API_KEY` and `API_TOKEN` (at least 32 characters) are required: the API refuses to
  start without them.
- `WEB_PASSWORD_HASH` turns on web sign-in. Make it on your Mac in the WordLearning checkout with
  `pnpm --filter @wordlearning/api web-password`.

## First deploy

Do steps 1 to 4 **before** merging a change to `docker-compose.apps.yml` that adds these services.
Otherwise the apps deploy fails its healthcheck and rolls back (the rest of the stack is fine).

1. **DNS:** `words.stepaniuk.me  A  <VPS_IP>`. Traefik asks for the certificate on the first
   request after the router appears.

2. **Images.** Push a `v*` tag in the WordLearning repo; its release workflow publishes both images
   to GHCR. A new GHCR package is private, so either make both packages public, or log in once on
   the VPS as `deploy` with a classic token that has only `read:packages`:

   ```bash
   docker login ghcr.io -u yevheniistepaniuk
   ```

3. **Database** (once):

   ```bash
   docker exec postgres sh -c 'createdb -U "$POSTGRES_USER" wordlearning'
   ```

4. **Secrets:** create `/opt/ys-infra/.env.wordlearning` as above, then
   `chmod 600 /opt/ys-infra/.env.wordlearning`. Optionally set `WORDS_TAG` in `.env`.

5. Merge. CI deploys the `apps` stack. Or run **Deploy infra** by hand with `stacks: apps`.

## Verify

```bash
curl https://words.stepaniuk.me/health
```

answers `{"status":"ok","db":"ok","redis":"ok",...}`.

```bash
curl -sI https://words.stepaniuk.me/dictionary/x | grep -iE '^(HTTP|cache-control|content-security-policy)'
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' https://words.stepaniuk.me/api/v1/nope
```

The first prints `HTTP/2 200`, `cache-control: no-cache` and the CSP (the PWA). The second prints
`401 application/json; charset=utf-8` (the API). On the VPS,
`docker logs words-api 2>&1 | grep 'auth failed' | tail -n 1` shows your own public IP, not a
Docker address.

Then open `https://words.stepaniuk.me`, sign in, and point the desktop app at the same URL with the
`API_TOKEN`.

## Update and roll back

Migrations run on every API start and are not undone by an older image: back up first
(`docs/backups.md`).

- **Pinned `WORDS_TAG`:** change it in `.env`, then run **Deploy infra** with `stacks: apps`.
  Roll back the same way. Both images always move to the same tag.
- **`latest`:** run **Deploy infra** with `stacks: apps`; it pulls the newest images.

After editing `.env.wordlearning`, recreate the API, since compose only reads an `env_file` when it
creates the container:

```bash
cd /opt/ys-infra && docker compose -f docker-compose.apps.yml up -d --force-recreate words-api
```
