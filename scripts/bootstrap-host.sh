#!/usr/bin/env bash
# Bootstrap a fresh Ubuntu VPS for the ys-infra stack. Idempotent: safe to re-run.
#
# Installs/configures: base packages + unattended upgrades, swap, Docker,
# Tailscale (host-level VPN), Docker-waits-for-Tailscale, deploy user,
# SSH hardening, ufw (22/80/443 public, everything on tailscale0).
#
# Env (all optional on re-run once already configured):
#   TS_AUTHKEY         Tailscale auth key (needed only if host is not yet logged in)
#   TS_HOSTNAME        Tailscale machine name            (default: ys-vps)
#   TS_TAGS            e.g. "tag:server" (must exist in tailnet ACL tagOwners)
#   DEPLOY_SSH_PUBKEY  public key for the `deploy` user (GitHub Actions deploy key)
#   DEPLOY_USER        (default: deploy)
#   DEPLOY_DIR         (default: /opt/ys-infra)
#   SWAP_SIZE          (default: 2G; set to 0 to skip)
#
# Usage: sudo -E bash bootstrap-host.sh

set -euo pipefail

TS_HOSTNAME="${TS_HOSTNAME:-ys-vps}"
TS_TAGS="${TS_TAGS:-}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/ys-infra}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
export DEBIAN_FRONTEND=noninteractive

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root"
. /etc/os-release
[ "${ID:-}" = "ubuntu" ] || die "Ubuntu required (found: ${ID:-unknown})"

# ---------------------------------------------------------------------------
log "Base packages + unattended security upgrades"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg ufw unattended-upgrades >/dev/null
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# ---------------------------------------------------------------------------
if [ "$SWAP_SIZE" != "0" ] && ! swapon --show | grep -q .; then
  log "Swap ($SWAP_SIZE) — safety net against OOM-killing Postgres"
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
cat > /etc/sysctl.d/99-ys.conf <<'EOF'
vm.swappiness = 10
vm.overcommit_memory = 1
EOF
sysctl -q --system

# ---------------------------------------------------------------------------
log "Docker"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
mkdir -p /etc/docker
DAEMON_JSON='{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}'
if [ "$(cat /etc/docker/daemon.json 2>/dev/null)" != "$DAEMON_JSON" ]; then
  echo "$DAEMON_JSON" > /etc/docker/daemon.json
  DOCKER_RESTART=1
fi
systemctl enable --now docker >/dev/null

# ---------------------------------------------------------------------------
log "Tailscale (host-level VPN)"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled >/dev/null

if tailscale ip -4 >/dev/null 2>&1; then
  echo "Already logged in to tailnet."
else
  [ -n "${TS_AUTHKEY:-}" ] || die "Host not in tailnet and TS_AUTHKEY not set"
  TS_ARGS=(--authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME" --ssh=false --accept-dns=false)
  if [ -n "$TS_TAGS" ]; then TS_ARGS+=(--advertise-tags="$TS_TAGS"); fi
  tailscale up "${TS_ARGS[@]}"
fi
TAILSCALE_IP="$(tailscale ip -4 | head -n1)"
echo "Tailscale IPv4: $TAILSCALE_IP"

# Docker must start after tailscaled has an IP: Postgres + Traefik dashboard bind to it.
DROPIN=/etc/systemd/system/docker.service.d/tailscale.conf
DROPIN_CONTENT="[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 30); do /usr/bin/tailscale ip -4 >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1'"
mkdir -p "$(dirname "$DROPIN")"
if [ "$(cat "$DROPIN" 2>/dev/null)" != "$DROPIN_CONTENT" ]; then
  echo "$DROPIN_CONTENT" > "$DROPIN"
  systemctl daemon-reload
  DOCKER_RESTART=1
fi
if [ "${DOCKER_RESTART:-0}" = "1" ]; then
  log "Restarting Docker (config changed)"
  systemctl restart docker
fi

# ---------------------------------------------------------------------------
log "Deploy user: $DEPLOY_USER"
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" --shell /bin/bash "$DEPLOY_USER" >/dev/null
fi
usermod -aG docker "$DEPLOY_USER"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
AUTH_KEYS="/home/$DEPLOY_USER/.ssh/authorized_keys"
touch "$AUTH_KEYS"
if [ -n "${DEPLOY_SSH_PUBKEY:-}" ]; then
  grep -qxF "$DEPLOY_SSH_PUBKEY" "$AUTH_KEYS" || echo "$DEPLOY_SSH_PUBKEY" >> "$AUTH_KEYS"
else
  warn "DEPLOY_SSH_PUBKEY not set — deploy user has no new key added"
fi
chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
install -d -m 750 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$DEPLOY_DIR"

# Keep .env's TAILSCALE_IP in sync if .env already exists.
ENV_FILE="$DEPLOY_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  if grep -q '^TAILSCALE_IP=' "$ENV_FILE"; then
    sed -i "s|^TAILSCALE_IP=.*|TAILSCALE_IP=$TAILSCALE_IP|" "$ENV_FILE"
  else
    echo "TAILSCALE_IP=$TAILSCALE_IP" >> "$ENV_FILE"
  fi
  chown "$DEPLOY_USER:$DEPLOY_USER" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

# ---------------------------------------------------------------------------
log "SSH hardening (key-only)"
# Refuse to lock ourselves out: root must already have a key.
if [ ! -s /root/.ssh/authorized_keys ]; then
  die "/root/.ssh/authorized_keys is empty — add a key before disabling passwords"
fi
cat > /etc/ssh/sshd_config.d/99-ys-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
EOF
sshd -t
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh

# ---------------------------------------------------------------------------
log "Firewall (ufw)"
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp  comment 'SSH'   >/dev/null
ufw allow 80/tcp  comment 'HTTP'  >/dev/null
ufw allow 443/tcp comment 'HTTPS' >/dev/null
ufw allow in on tailscale0 comment 'Tailscale' >/dev/null
# No inbound 41641/udp needed: Tailscale NAT traversal works via outbound UDP.
ufw --force enable >/dev/null
ufw status verbose

# ---------------------------------------------------------------------------
log "Done"
cat <<EOF
Tailscale IPv4 : $TAILSCALE_IP   (set TAILSCALE_IP in $ENV_FILE)
Deploy user    : $DEPLOY_USER (docker group)
Deploy dir     : $DEPLOY_DIR
Docker         : $(docker --version)
EOF
[ -f "$ENV_FILE" ] || warn "$ENV_FILE missing — create it (chmod 600, owner $DEPLOY_USER) before first deploy"
