# Idea 1: VPS alerting

Status: **proposal**. Nothing here is implemented yet.

## Problem

Beszel collects metrics for `ys-vps`, but nobody is told when something breaks. Today we only find out
about an outage, a full disk or a crash loop by opening a dashboard.

There is also a structural gap: **the Beszel hub runs on the same VPS it monitors.** If the box goes
down, loses network or Docker dies, the hub dies with it, and its "Status down" alert never fires.
In-host alerting can cover resource problems. It cannot cover "the host is gone".

## Current baseline (2026-11-26)

| Resource | Capacity | In use | Notes |
|---|---|---|---|
| CPU | 6 vCPU | low | Load average is a better signal than a CPU % spike |
| RAM | 11 GiB + 2 GiB swap | ~0.9 GiB | Every container has a memory limit except `postgres` |
| Disk `/` | 193 GB | 6.5 GB (4%) | Docker images, volumes, logs (10 MB × 3 per container) |
| Public | `:80`, `:443` via Traefik | | `stepaniuk.me`, `www` → 308 → apex |
| Tailnet only | `100.100.57.44` | | Beszel, Dozzle, pgweb, Redis Commander, Traefik dashboard, Postgres |

Plenty of headroom, so the thresholds below aim at **real trouble**, not normal noise.

## Proposal: three layers

```
Layer 1  Beszel (on host)        resources: CPU / RAM / disk / load / network
Layer 2  External uptime check   host and site reachable from the internet, TLS valid
Layer 3  GitHub                  deploy and bootstrap workflow failures
                │
                └── all go to one channel: Telegram bot (email as fallback)
```

### Layer 1: Beszel system alerts

Configure in Beszel: system row → **bell icon**.

| Alert | Threshold | Duration | Why |
|---|---|---|---|
| Status | down | 3 min | Agent stopped or socket broken. Not "host down" (see Layer 2) |
| CPU | > 80% | 10 min | Sustained, not spikes (image pulls and deploys spike briefly) |
| Load avg (5 min) | > 6 | 10 min | Equals vCPU count, so tasks are queuing |
| Memory | > 85% | 5 min | About 9.4 GiB. Most likely cause: Postgres, which has no limit |
| Disk | > 80% | 0 (instant) | About 155 GB. Leaves time to prune images or move backups |
| Bandwidth | > 50 MB/s | 10 min | Unexpected traffic: abuse, a runaway job, a DDoS |

Beszel alerts are per **system**, not per container. A crash-looping container only shows up as a
CPU or memory pattern. Layer 2 catches the user-visible effect.

Notification target: **Settings → Notifications** → add a Shoutrrr URL:

```
telegram://<BOT_TOKEN>@telegram?chats=<CHAT_ID>
```

Create the bot with `@BotFather`. Get the chat ID by messaging the bot and opening
`https://api.telegram.org/bot<BOT_TOKEN>/getUpdates`. Add the Beszel account email as a second
channel, so one broken integration doesn't silence everything.

### Layer 2: external uptime checks

This must run **off the VPS**. Options, cheapest first:

| Option | Cost | Pros | Cons |
|---|---|---|---|
| **UptimeRobot** (free) | $0 | 5-min checks, keyword and TLS expiry checks, Telegram integration | Third party; 5-min granularity |
| **Healthchecks.io** (free) | $0 | Dead-man's switch: the VPS pings it, and silence means down | Needs a cron on the VPS; doesn't test the public path |
| GitHub Actions cron | $0 | Lives in this repo, versioned | Scheduled runs can be delayed or skipped; noisy to maintain |
| Uptime Kuma on a 2nd box | ~€3–5/mo | Self-hosted, rich | Another host to run and secure |

**Recommendation:** UptimeRobot for the public checks, plus Healthchecks.io as a heartbeat from the host.

Checks:

| Check | Type | Target | Alert when |
|---|---|---|---|
| Site up | HTTPS keyword | `https://stepaniuk.me`, expects `hello-stepaniuk.me` | 2 consecutive failures |
| www redirect | HTTPS status | `https://www.stepaniuk.me`, expects `308` | 2 consecutive failures |
| TLS expiry | Certificate | `stepaniuk.me` | < 14 days left (Let's Encrypt renews at 30, so this means renewal is broken) |
| Host heartbeat | Healthchecks.io | cron on the VPS every 5 min: `curl -fsS https://hc-ping.com/<uuid>` | No ping for 10 min |

The heartbeat cron can also check Docker itself, so a dead daemon counts as "down":

```bash
*/5 * * * * deploy docker info >/dev/null 2>&1 && curl -fsS -m 10 --retry 3 https://hc-ping.com/<uuid> >/dev/null
```

Put it in `/etc/cron.d/ys-heartbeat`, and let `scripts/bootstrap-host.sh` install it when a
`HEARTBEAT_URL` env var is set. That keeps the setup reproducible.

### Layer 3: CI failure alerts

- GitHub → **Settings → Notifications → Actions**: "Notify on failed workflows only", by email or the GitHub mobile app.
- Optional: a final `if: failure()` step in `deploy-infra.yml` that posts to the same Telegram bot.
  The deploy already rolls back on failed healthchecks, so a red run means "the change didn't ship",
  not "production is down".

## Gaps not covered here

- **Postgres has no memory limit.** The Memory alert will catch it, but setting a limit
  (e.g. `memory: 2G` in `docker-compose.data.yml`) prevents one service starving the rest.
- **Backups.** No alert matters if nothing is backed up. Backups should get their own heartbeat
  (Healthchecks.io check per backup job). That belongs in a separate backups proposal.
- **Security events** (SSH brute force, ufw drops). Password login is off, so the risk is low. Could revisit with fail2ban + notifications.
- **Log-based alerts** (e.g. error-rate spikes). Dozzle has none. Would need Loki/Grafana, which is overkill for now.

## Rollout

1. Create the Telegram bot and add it to Beszel notifications. Send a test notification.
2. Configure the Layer 1 alerts in Beszel.
3. Create the UptimeRobot monitors (site, www, TLS) and connect Telegram.
4. Create the Healthchecks.io check. Add `HEARTBEAT_URL` support to `bootstrap-host.sh`, rerun bootstrap.
5. Turn on GitHub failed-workflow notifications.
6. **Fire drill:** `docker stop hello` (site check fires), stop the heartbeat cron (heartbeat fires),
   then `docker start hello`, and confirm "recovered" messages arrive too.
7. Document the final setup in [docs/monitoring.md](../monitoring.md) and mark this proposal done.

## Open questions

- Telegram, email, or both as the primary channel?
- Is 5-minute granularity from UptimeRobot's free tier enough, or is it worth paying for 1-minute checks?
- Should the heartbeat and Telegram tokens live in `.env` (server) or as GitHub secrets passed to bootstrap?
