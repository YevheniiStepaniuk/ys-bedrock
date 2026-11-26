#!/usr/bin/env bash
# End-to-end provisioning from your machine: bootstrap host -> .env -> verify -> CI deploy.
# Idempotent: safe to re-run.
#
#   1. Preflight: local .env, SSH key, gh auth, root login works.
#   2. Upload .env (as root) to $DEPLOY_DIR/.env.
#   3. Run scripts/bootstrap-host.sh (local copy) on the host as root. It syncs
#      TAILSCALE_IP into .env, fixes ownership, hardens sshd, configures ufw.
#   4. Verify: password auth off, deploy user can log in with the key and read .env.
#   5. Point the VPS_USER secret at the deploy user, then run "Deploy infra" and wait.
#
# Usage: scripts/provision.sh <host> [stacks]
#   host    VPS public IP / hostname
#   stacks  passed to the deploy workflow (default: all)
#
# Env overrides:
#   SSH_KEY       private key for root + deploy (default: ~/.ssh/github_deploy_key)
#   DEPLOY_USER   (default: deploy)
#   DEPLOY_DIR    (default: /opt/ys-infra)
#   TS_AUTHKEY    only needed if the host is not in the tailnet yet
#   SKIP_DEPLOY=1 stop after verification

set -euo pipefail

HOST="${1:?usage: $0 <host> [stacks]}"
STACKS="${2:-all}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/github_deploy_key}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/ys-infra}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

# Key-only, non-interactive: never fall back to a password prompt.
SSH_OPTS=(-i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15)
r_ssh() { ssh "${SSH_OPTS[@]}" "root@$HOST" "$@"; }
d_ssh() { ssh "${SSH_OPTS[@]}" "$DEPLOY_USER@$HOST" "$@"; }

# ---------------------------------------------------------------------------
log "Preflight"
[ -f "$ROOT_DIR/.env" ]  || die ".env not found in $ROOT_DIR (copy .env.example and fill it)"
[ -f "$SSH_KEY" ]        || die "SSH key not found: $SSH_KEY"
[ -f "$SSH_KEY.pub" ]    || die "Public key not found: $SSH_KEY.pub"
command -v gh >/dev/null || die "gh CLI not installed"
gh auth status >/dev/null 2>&1 || die "gh not authenticated (run: gh auth login)"
bash -n "$ROOT_DIR/scripts/bootstrap-host.sh"
r_ssh true || die "root@$HOST does not accept $SSH_KEY"
ok "root login with key works"

# ---------------------------------------------------------------------------
log "Upload .env -> $DEPLOY_DIR/.env"
r_ssh "install -d -m 750 '$DEPLOY_DIR'"
scp -q "${SSH_OPTS[@]}" "$ROOT_DIR/.env" "root@$HOST:$DEPLOY_DIR/.env"
r_ssh "chmod 600 '$DEPLOY_DIR/.env'"
ok "uploaded (bootstrap sets owner + TAILSCALE_IP next)"

# ---------------------------------------------------------------------------
log "Bootstrap host (local scripts/bootstrap-host.sh)"
r_ssh "install -d -m 700 /root/ys-bootstrap"
scp -q "${SSH_OPTS[@]}" "$ROOT_DIR/scripts/bootstrap-host.sh" "root@$HOST:/root/ys-bootstrap/bootstrap-host.sh"
PUBKEY="$(cat "$SSH_KEY.pub")"
# Values passed via env on the remote side; printf %q keeps quoting safe.
r_ssh "DEPLOY_USER=$(printf %q "$DEPLOY_USER") DEPLOY_DIR=$(printf %q "$DEPLOY_DIR") \
  DEPLOY_SSH_PUBKEY=$(printf %q "$PUBKEY") TS_AUTHKEY=$(printf %q "${TS_AUTHKEY:-}") \
  bash /root/ys-bootstrap/bootstrap-host.sh"
ok "bootstrap finished"

# ---------------------------------------------------------------------------
log "Verify"
r_ssh "sshd -T | grep -x 'passwordauthentication no' >/dev/null" || die "sshd still allows password login"
ok "sshd: password auth disabled"

d_ssh true || die "$DEPLOY_USER@$HOST does not accept $SSH_KEY"
ok "$DEPLOY_USER login with key works"

d_ssh "test -r '$DEPLOY_DIR/.env' && test -w '$DEPLOY_DIR'" || die "$DEPLOY_USER cannot read .env / write $DEPLOY_DIR"
ok "$DEPLOY_USER owns $DEPLOY_DIR and can read .env"

TS_IP="$(r_ssh "tailscale ip -4 | head -n1")"
d_ssh "grep -qx 'TAILSCALE_IP=$TS_IP' '$DEPLOY_DIR/.env'" || die "TAILSCALE_IP in server .env != $TS_IP"
ok "server .env TAILSCALE_IP=$TS_IP"

d_ssh "docker info >/dev/null" || die "$DEPLOY_USER cannot talk to Docker"
ok "$DEPLOY_USER can use Docker"

if [ "${SKIP_DEPLOY:-0}" = "1" ]; then
  log "SKIP_DEPLOY=1: done"; exit 0
fi

# ---------------------------------------------------------------------------
log "CI: VPS_USER=$DEPLOY_USER, run Deploy infra (stacks: $STACKS)"
gh secret set VPS_USER --body "$DEPLOY_USER" --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner)"
ok "VPS_USER secret set"

BEFORE="$(gh run list --workflow "Deploy infra" --limit 1 --json databaseId -q '.[0].databaseId // 0')"
gh workflow run "Deploy infra" -f stacks="$STACKS"
RUN_ID=""
for _ in $(seq 1 30); do
  RUN_ID="$(gh run list --workflow "Deploy infra" --limit 1 --json databaseId -q '.[0].databaseId // 0')"
  [ "$RUN_ID" != "$BEFORE" ] && break
  sleep 2
done
[ "$RUN_ID" != "$BEFORE" ] || die "Deploy run did not start"
ok "run $RUN_ID started"

if gh run watch "$RUN_ID" --exit-status --interval 5; then
  ok "Deploy succeeded"
  echo
  echo "Check: https://stepaniuk.me  |  Traefik: http://$TS_IP:8080  |  Beszel: http://$TS_IP:8090"
else
  gh run view "$RUN_ID" --log-failed | tail -40 || true
  die "Deploy failed (run $RUN_ID)"
fi
