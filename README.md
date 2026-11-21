# ys-infra

Infrastructure for the stepaniuk.me pet-project stack on a Contabo VPS (4 vCPU / 8 GB, Ubuntu).

There are five separate compose projects. Each has its own lifecycle, so deploying the edge never recreates the databases.

| Stack  | File                       | Services          | Owns network |
|--------|----------------------------|-------------------|--------------|
| `data` | `docker-compose.data.yml`  | postgres, redis   | `internal`, `tailnet` |
| `edge` | `docker-compose.yml`       | traefik           | `proxy`      |
| `monitoring` | `docker-compose.monitoring.yml` | beszel, beszel-agent, dozzle | — |
| `tools` | `docker-compose.tools.yml` | pgweb, redis-commander | — |
| `apps` | `docker-compose.apps.yml` | hello (placeholder for the PWA) | — |

| Service  | Image               | Networks   | Exposure                                   |
|----------|---------------------|------------|--------------------------------------------|
| traefik  | `traefik:v3.4`      | `proxy`    | `:80`, `:443` public; dashboard `TAILSCALE_IP:8080` |
| postgres | `postgres:16-alpine`| `internal`, `tailnet` | `TAILSCALE_IP:5432` only                   |
| redis    | `redis:7-alpine`    | `internal` | none                                       |
| beszel   | `henrygd/beszel:0.21.2` | default | `TAILSCALE_IP:8090` only (stats UI)  |
| beszel-agent | `henrygd/beszel-agent:0.21.2` | host | none (unix socket)          |
| dozzle   | `amir20/dozzle:v11.5.0` | default | `TAILSCALE_IP:8081` only (logs UI)   |
| pgweb    | `sosedoff/pgweb:0.17.0` | `internal`, `tailnet` | `TAILSCALE_IP:8082` only + basic auth (Postgres UI) |
| hello    | `traefik/whoami:v1.12.0` | `proxy` | `https://stepaniuk.me/` via Traefik |
| redis-commander | `ghcr.io/joeferner/redis-commander:0.9.1` | `internal`, `tailnet` | `TAILSCALE_IP:8083` only + login (Redis UI) |

Networks:
- `proxy`: Traefik and the web-facing apps.
- `internal`: Postgres, Redis and the backend apps. It is `internal: true`, so there is **no internet egress**. A container that needs egress (bots, backup sidecar) also joins `proxy`.
- `tailnet`: a bridge with IP masquerading off. Docker **ignores `ports:` for containers attached only to an `internal: true` network**, so every service published on `TAILSCALE_IP` that also sits on `internal` (postgres, the DB UIs) joins `tailnet` as well. Because there is no masquerade (SNAT), inbound published ports work but outbound traffic can't reach the internet.
- Each stack creates the network it owns. Other stacks join it with `external: true`.

Volume names are fixed (`postgres-data`, `redis-data`, `traefik-certs`) rather than prefixed with the project name. Renaming a project therefore never orphans data.

Domains: `stepaniuk.me`, `www.stepaniuk.me` (redirects to the apex), `webhooks.stepaniuk.me`.

## 1. DNS

Create A records pointing at the VPS public IPv4:

```
stepaniuk.me           A  <VPS_IP>
www.stepaniuk.me       A  <VPS_IP>
webhooks.stepaniuk.me  A  <VPS_IP>
```

## 2. Host bootstrap (GitHub Action)

[scripts/bootstrap-host.sh](scripts/bootstrap-host.sh) is idempotent, so you can re-run it any time to bring a host's config back in line. It sets up:
- **Packages:** base packages, unattended security upgrades, and a 2G swap file with `swappiness=10` as a safety net against Postgres being OOM-killed.
- **Docker:** installed with default log rotation and `live-restore`.
- **Tailscale (host-level VPN):** joins your tailnet using an auth key and prints the Tailscale IP. If `/opt/ys-infra/.env` exists, the script also updates `TAILSCALE_IP` in it.
- **Docker-waits-for-Tailscale:** a systemd drop-in. Postgres and the Traefik dashboard bind to the Tailscale IP, so without it those containers fail to start after a reboot.
- **`deploy` user:** in the `docker` group, with the CI public key and ownership of `/opt/ys-infra`.
- **SSH hardening:** key-only login and root restricted to `prohibit-password`. The script aborts if root has no authorized key, so it can't lock you out.
- **ufw:** 22, 80 and 443 public; everything else allowed only on `tailscale0`.

Run it from GitHub → Actions → **Bootstrap host** → **Run workflow**. It never runs automatically. Inputs: Tailscale hostname, optional tags and swap size.

### One-time prep

1. **Root SSH key on the VPS.** Contabo gives you root with a password. Add a dedicated bootstrap key:
   ```bash
   ssh-keygen -t ed25519 -C "gha-bootstrap" -f ./gha_bootstrap -N ""
   ssh-copy-id -i ./gha_bootstrap.pub root@<VPS_IP>
   ```
2. **Deploy key** (used later by the deploy workflow as the `deploy` user):
   ```bash
   ssh-keygen -t ed25519 -C "gha-deploy" -f ./gha_deploy -N ""
   ```
3. **Host fingerprint** for pinning:
   ```bash
   ssh-keyscan -t ed25519 <VPS_IP> 2>/dev/null | ssh-keygen -lf - | awk '{print $2}'
   ```
4. **Tailscale auth key** (full walkthrough: [docs/tailscale.md](docs/tailscale.md)): in the Tailscale admin console → Settings → Keys, generate one that is **not** ephemeral. Pre-approved is optional. If you use tags (for example `tag:server`, which also disables key expiry for the node), first define them in the ACL under `tagOwners`.
5. **GitHub secrets:** Settings → Environments → create `production`, then add:

| Secret                  | Value                                              | Used by   |
|-------------------------|----------------------------------------------------|-----------|
| `VPS_HOST`              | VPS public IP                                      | both      |
| `VPS_SSH_FINGERPRINT`   | `SHA256:...` from step 3                           | both      |
| `VPS_PORT`              | optional, defaults to `22`                         | both      |
| `VPS_BOOTSTRAP_SSH_KEY` | contents of `gha_bootstrap` (private)              | bootstrap |
| `VPS_BOOTSTRAP_USER`    | optional, defaults to `root`                       | bootstrap |
| `TAILSCALE_AUTHKEY`     | `tskey-auth-...` from step 4                       | bootstrap |
| `DEPLOY_SSH_PUBKEY`     | contents of `gha_deploy.pub`                       | bootstrap |
| `VPS_USER`              | `deploy`                                           | deploy    |
| `VPS_SSH_KEY`           | contents of `gha_deploy` (private)                 | deploy    |

Delete the local `gha_*` key files once the secrets are saved. After the first bootstrap, the Tailscale auth key is only needed again if the node is removed from the tailnet. You can revoke it after the first run.

Running the script by hand instead: `scp scripts/bootstrap-host.sh root@<VPS_IP>:` and then `TS_AUTHKEY=... DEPLOY_SSH_PUBKEY="..." bash bootstrap-host.sh`.

> Note: Docker writes its own iptables rules and **bypasses ufw** for published ports. This setup is safe because only 80/443 are published on all interfaces. Everything else is bound to the Tailscale IP or not published at all. Never add a bare `"5432:5432"`-style port mapping.

## 3. Deploy

```bash
# First deploy: run as `deploy` on the VPS, or just push / run the "Deploy infra" workflow
# once .env exists. Create .env from your machine:
#   scp .env deploy@<VPS_IP>:/opt/ys-infra/.env && ssh deploy@<VPS_IP> chmod 600 /opt/ys-infra/.env
# then set TAILSCALE_IP in it (the bootstrap output prints it).
cd /opt/ys-infra

# data first (creates `internal`), then edge (creates `proxy`)
docker compose -f docker-compose.data.yml up -d --wait
docker compose -f docker-compose.yml up -d --wait
docker compose -f docker-compose.monitoring.yml up -d --wait
docker compose -f docker-compose.tools.yml up -d --wait
docker compose -f docker-compose.apps.yml up -d --wait

docker compose -f docker-compose.data.yml ps
docker compose -f docker-compose.yml ps
```

Check:
- `https://stepaniuk.me` should show the `hello` page: request info from `traefik/whoami`, starting with `Name: hello-stepaniuk.me`.
- `https://www.stepaniuk.me` should 301 to `https://stepaniuk.me`.
- Traefik dashboard: `http://<TAILSCALE_IP>:8080`, reachable over Tailscale only.
- Postgres from DBeaver: `<TAILSCALE_IP>:5432`.
- Beszel (resource stats): `http://<TAILSCALE_IP>:8090`. Create the admin account right away, then enable the agent: [docs/monitoring.md](docs/monitoring.md).
- Dozzle (logs): `http://<TAILSCALE_IP>:8081`.
- pgweb (Postgres UI): `http://<TAILSCALE_IP>:8082`, user/password `TOOLS_USER`/`TOOLS_PASSWORD`.
- Redis Commander (Redis UI): `http://<TAILSCALE_IP>:8083`, same credentials.

## 4. CI/CD (auto-deploy on change)

[.github/workflows/deploy-infra.yml](.github/workflows/deploy-infra.yml) runs on every push to `main` that changes `docker-compose.yml`, `docker-compose.data.yml`, `traefik/**` or the workflow file. You can also start it manually with **Run workflow**.

1. **validate**: runs `docker compose config -q` with dummy env values and a YAML check of `traefik/dynamic/*.yml`.
2. **deploy** (GitHub environment `production`):
   - SCPs the files to `/opt/ys-infra/.deploy/incoming`.
   - Validates them against the **real** `.env` on the server.
   - Snapshots the current config to `.deploy/previous`.
   - Swaps the new files in.
   - For each stack, in order `data` then `edge`, runs `docker compose pull` and `up -d --remove-orphans --wait`.
3. **Only changed services restart.** Compose recreates a container only when its config or image changes. Traefik hot-reloads `traefik/dynamic/*` without restarting.
4. **Rollback:** if any healthcheck fails within 180s, the previous config is restored and brought back up, and the job fails.

`.env` lives **only on the server**. CI never touches it. After editing `.env`, run `docker compose -f <stack file> up -d` for the affected stack on the server, or trigger the workflow manually.

Secrets: see the table in section 2.

> Note: `docker` group membership is effectively root on the host. Keep the deploy key in the `production` environment only. Add required reviewers there if you want a manual approval gate before each deploy.

## Adding an app (template)

Add apps to [docker-compose.apps.yml](docker-compose.apps.yml), next to `hello`. To replace `hello` with the PWA, keep the `Host(`stepaniuk.me`)` router and change the image and port. Apps join both networks as external. `depends_on` doesn't work across projects, so apps must retry their DB connection on startup.

```yaml
name: apps

networks:
  proxy:
    external: true
  internal:
    external: true

services:
  api:
    image: ghcr.io/<owner>/api:latest
    restart: unless-stopped
    env_file: .env
    networks: [proxy, internal]
    deploy:
      resources:
        limits:
          memory: 500M
    labels:
      - traefik.enable=true
      - traefik.http.routers.api.rule=Host(`stepaniuk.me`) && PathPrefix(`/api`)
      - traefik.http.routers.api.entrypoints=websecure
      - traefik.http.routers.api.tls.certresolver=le
      - traefik.http.routers.api.middlewares=secure-headers@file
      - traefik.http.services.api.loadbalancer.server.port=3000
```

Apps reach the databases by service name: `postgres:5432` and `redis:6379`.
