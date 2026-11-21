# ys-infra

Infrastructure for the stepaniuk.me pet-project stack on a Contabo VPS (4 vCPU / 8 GB, Ubuntu).

There are two separate compose projects. Each has its own lifecycle, so deploying the edge never recreates the databases.

| Stack  | File                       | Services          | Owns network |
|--------|----------------------------|-------------------|--------------|
| `data` | `docker-compose.data.yml`  | postgres, redis   | `internal`   |
| `edge` | `docker-compose.yml`       | traefik           | `proxy`      |

| Service  | Image               | Networks   | Exposure                                   |
|----------|---------------------|------------|--------------------------------------------|
| traefik  | `traefik:v3.4`      | `proxy`    | `:80`, `:443` public; dashboard `TAILSCALE_IP:8080` |
| postgres | `postgres:16-alpine`| `internal` | `TAILSCALE_IP:5432` only                   |
| redis    | `redis:7-alpine`    | `internal` | none                                       |

Networks:
- `proxy`: Traefik and the web-facing apps.
- `internal`: Postgres, Redis and the backend apps. It is `internal: true`, so there is **no internet egress**. A container that needs egress (bots, backup sidecar) also joins `proxy`.
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

## 2. Host setup (once, as root)

```bash
# Docker
curl -fsSL https://get.docker.com | sh

# Tailscale
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --ssh=false
tailscale ip -4   # put this in .env as TAILSCALE_IP

# Firewall: only 22/80/443 public
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow in on tailscale0
ufw enable
```

SSH hardening: in `/etc/ssh/sshd_config`, set `PasswordAuthentication no` and `PermitRootLogin prohibit-password`, then run `systemctl restart ssh`.

**Make Docker wait for Tailscale.** Postgres and the Traefik dashboard bind to the Tailscale IP. If Docker starts before `tailscaled` has that IP, those containers fail to start after a reboot.

```bash
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/tailscale.conf <<'EOF'
[Unit]
After=tailscaled.service
Wants=tailscaled.service
[Service]
ExecStartPre=/bin/sh -c 'for i in $(seq 1 30); do tailscale ip -4 >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1'
EOF
systemctl daemon-reload && systemctl restart docker
```

> Note: Docker writes its own iptables rules and **bypasses ufw** for published ports. This setup is safe because only 80/443 are published on all interfaces. Everything else is bound to the Tailscale IP or not published at all. Never add a bare `"5432:5432"`-style port mapping.

## 3. Deploy

```bash
git clone <repo> /opt/ys-infra && cd /opt/ys-infra
cp .env.example .env && chmod 600 .env   # fill in values

# data first (creates `internal`), then edge (creates `proxy`)
docker compose -f docker-compose.data.yml up -d --wait
docker compose -f docker-compose.yml up -d --wait

docker compose -f docker-compose.data.yml ps
docker compose -f docker-compose.yml ps
```

Check:
- `https://www.stepaniuk.me` should 301 to `https://stepaniuk.me`. It will 404 until an app serves the apex.
- Traefik dashboard: `http://<TAILSCALE_IP>:8080`, reachable over Tailscale only.
- Postgres from DBeaver: `<TAILSCALE_IP>:5432`.

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

### One-time setup

On the VPS (as root), create a non-root deploy user:

```bash
adduser --disabled-password --gecos "" --shell /bin/bash deploy
usermod -aG docker deploy
mkdir -p /opt/ys-infra && chown -R deploy:deploy /opt/ys-infra
# then place .env in /opt/ys-infra (chmod 600, owned by deploy)
```

On your machine, generate a dedicated CI key:

```bash
ssh-keygen -t ed25519 -C "gha-deploy" -f ./gha_deploy -N ""
```

Append `gha_deploy.pub` to `/home/deploy/.ssh/authorized_keys` on the VPS. Get the host key fingerprint for pinning:

```bash
ssh-keyscan -t ed25519 <VPS_IP> 2>/dev/null | ssh-keygen -lf - | awk '{print $2}'
```

In GitHub → Settings → Environments → create `production` and add these secrets:

| Secret                | Value                                         |
|-----------------------|-----------------------------------------------|
| `VPS_HOST`            | VPS public IP                                 |
| `VPS_USER`            | `deploy`                                      |
| `VPS_SSH_KEY`         | contents of `gha_deploy` (private key)        |
| `VPS_SSH_FINGERPRINT` | `SHA256:...` from the command above           |
| `VPS_PORT`            | optional, defaults to `22`                    |

Delete the local `gha_deploy*` files once the secrets are saved.

> Note: `docker` group membership is effectively root on the host. Keep the deploy key in the `production` environment only. Add required reviewers there if you want a manual approval gate before each deploy.

## Adding an app (template)

Apps live in their own stack and join both networks as external. `depends_on` doesn't work across projects, so apps must retry their DB connection on startup.

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
