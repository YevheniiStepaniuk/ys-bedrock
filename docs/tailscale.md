# Tailscale setup — step by step

Tailscale is the private network used for everything that is **not** public web traffic:
Traefik dashboard, PostgreSQL (DBeaver), and later Beszel / Dozzle. It runs on the
**host OS** of the VPS (not in Docker). Public internet sees only ports 22 / 80 / 443.

```
 Your laptop / phone ──(Tailscale, WireGuard)──► VPS 100.x.x.x
                                                   ├─ :5432  Postgres
                                                   └─ :8080  Traefik dashboard
 Internet ──────────────────────────────────────► VPS public IP :80 / :443 only
```

---

## Step 1 — Create a Tailscale account (tailnet)

1. Go to <https://login.tailscale.com/start> and sign in (Google / GitHub / Microsoft / etc.).
   The free **Personal** plan is enough.
2. This creates your **tailnet** — your private network. Admin console:
   <https://login.tailscale.com/admin>.

## Step 2 — Install Tailscale on your own devices

Install the client on every device you want to use to reach the server:

| Device  | How                                                                 |
|---------|---------------------------------------------------------------------|
| macOS   | App Store → "Tailscale", or `brew install --cask tailscale`         |
| Windows | <https://tailscale.com/download/windows>                            |
| Linux   | `curl -fsSL https://tailscale.com/install.sh \| sh && sudo tailscale up` |
| iOS / Android | App Store / Google Play → "Tailscale"                         |

Log in with the **same account** as Step 1. Check the device appears in
admin console → **Machines**.

## Step 3 — Define a `tag:server` tag (ACL policy)

Tagging the VPS means: it is owned by the tailnet (not your personal user), its node key
**never expires** (no surprise disconnect after 180 days), and you can write rules for it.

1. Admin console → **Access controls**.
2. Make sure the policy contains a `tagOwners` entry. Minimal policy:

   ```jsonc
   {
     "tagOwners": {
       "tag:server": ["autogroup:admin"]
     },

     // Your devices can reach the server; the server can NOT reach your devices.
     "grants": [
       {
         "src": ["autogroup:member"],
         "dst": ["tag:server"],
         "ip":  ["*"]
       }
     ]
   }
   ```

   > If you keep the default "allow all" policy, the VPS can also reach your laptop and
   > phone. The `grants` block above makes access one-way (you → server), which is safer
   > if the server is ever compromised. Rules are additive, so this only works if you
   > **remove** the default allow-all entry (`"acls": [{"action": "accept", "src": ["*"], "dst": ["*:*"]}]`
   > or an equivalent `grants` entry with `"src": ["*"]`). If you have other devices that
   > need to talk to each other, add explicit rules for them.

   Optional, stricter — only allow the ports actually used:

   ```jsonc
   "ip": ["tcp:5432", "tcp:8080", "tcp:22"]
   ```

   (Add Beszel / Dozzle ports here later.)

3. Click **Save**.

## Step 4 — Generate an auth key for the VPS

The bootstrap script uses this key to join the VPS to your tailnet without a browser login.

1. Admin console → **Settings** → **Keys** → **Generate auth key…**
2. Settings:

   | Option        | Value       | Why                                                   |
   |---------------|-------------|-------------------------------------------------------|
   | Description   | `ys-vps bootstrap` |                                                |
   | Reusable      | **Off**     | One server, one key                                   |
   | Expiration    | 1–7 days    | Only needed for the first bootstrap                   |
   | Ephemeral     | **Off**     | Ephemeral nodes are deleted when offline — not for a server |
   | Pre-approved  | On          | Only matters if device approval is enabled            |
   | Tags          | `tag:server`| From Step 3                                           |

3. Click **Generate key** and copy it (`tskey-auth-…`). It is shown **once**.

## Step 5 — Add GitHub secrets

GitHub repo → **Settings** → **Environments** → `production` → **Add secret**:

| Secret              | Value             |
|---------------------|-------------------|
| `TAILSCALE_AUTHKEY` | `tskey-auth-…`    |

(Other bootstrap secrets — `VPS_HOST`, `VPS_SSH_FINGERPRINT`, `VPS_BOOTSTRAP_SSH_KEY`,
`DEPLOY_SSH_PUBKEY` — see [README §2](../README.md#2-host-bootstrap-github-action).)

## Step 6 — Run the bootstrap workflow

1. GitHub → **Actions** → **Bootstrap host** → **Run workflow**.
2. Inputs:
   - `ts_hostname`: `ys-vps` (name shown in Tailscale)
   - `ts_tags`: `tag:server`  ← must match Step 3/4
   - `swap_size`: `2G`
3. Wait for green. At the end of the log:

   ```
   ==> Done
   Tailscale IPv4 : 100.101.102.103
   ```

   Copy this IP.

What the script did with Tailscale:
- Installed `tailscale` + `tailscaled` on the host.
- Ran `tailscale up --authkey=… --hostname=ys-vps --advertise-tags=tag:server --ssh=false --accept-dns=false`.
- Added a systemd drop-in so **Docker starts only after Tailscale has its IP**
  (Postgres and the Traefik dashboard bind to that IP — without this they fail after reboot).
- Opened ufw for all traffic **on `tailscale0` only**.

## Step 7 — Put the Tailscale IP in `.env`

In your local `.env` (and on the server, `/opt/ys-infra/.env`):

```
TAILSCALE_IP=100.101.102.103
```

If `/opt/ys-infra/.env` already existed when bootstrap ran, the script updated it
automatically. Otherwise copy it up:

```bash
scp .env deploy@<VPS_PUBLIC_IP>:/opt/ys-infra/.env
ssh deploy@<VPS_PUBLIC_IP> chmod 600 /opt/ys-infra/.env
```

## Step 8 — Disable key expiry & revoke the auth key

1. Admin console → **Machines** → `ys-vps` → `…` menu.
   - Tagged nodes have **key expiry disabled** automatically. If you see an expiry date
     (e.g. you skipped tags), click **Disable key expiry**.
2. Admin console → **Settings** → **Keys** → revoke the `ys-vps bootstrap` auth key.
   It is no longer needed. Re-running bootstrap on an already-joined host skips login.
   (Delete the `TAILSCALE_AUTHKEY` GitHub secret too, or leave it — it is useless once revoked.)

## Step 9 — Verify from your laptop

With Tailscale **connected** on your laptop:

```bash
tailscale status                 # ys-vps should be listed
tailscale ping ys-vps            # "pong from ys-vps (100.x.x.x) via ..."
```

After the first deploy:

| What               | URL / connection                                     |
|--------------------|------------------------------------------------------|
| Traefik dashboard  | `http://ys-vps:8080` or `http://100.x.x.x:8080`       |
| Postgres (DBeaver) | host `ys-vps` (or `100.x.x.x`), port `5432`, user/pass from `.env` |
| SSH over Tailscale | `ssh deploy@ys-vps`                                   |

`ys-vps` resolves via **MagicDNS** (admin console → **DNS** → MagicDNS on; it is on by
default). If the name does not resolve, use the `100.x` IP.

Confirm they are **not** public — from a machine with Tailscale **disconnected**:

```bash
nc -zv -w3 <VPS_PUBLIC_IP> 5432   # must fail / time out
nc -zv -w3 <VPS_PUBLIC_IP> 8080   # must fail / time out
```

---

## Optional: lock SSH to Tailscale only

Once Tailscale works reliably, you can close public SSH so port 22 is reachable only via
the tailnet:

```bash
ssh root@ys-vps
ufw delete allow 22/tcp
ufw status
```

> ⚠️ After this, if Tailscale breaks you can only get in through the **Contabo web
> console (VNC)**. GitHub Actions will also no longer reach the VPS over its public IP —
> you would need to add Tailscale to the workflows (`tailscale/github-action`) first.
> Not done by default for that reason.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Bootstrap: `Host not in tailnet and TS_AUTHKEY not set` | Add `TAILSCALE_AUTHKEY` secret (Step 5). |
| Bootstrap: `requested tags [tag:server] are invalid or not permitted` | Tag missing in ACL `tagOwners` (Step 3), or auth key was created without that tag (Step 4). |
| Bootstrap: `invalid key` / `key expired` | Key used already (non-reusable) or expired → generate a new one. |
| `postgres` / `traefik` container fails: `cannot assign requested address` | `TAILSCALE_IP` in `.env` is wrong or Tailscale is down. Check `tailscale ip -4` on host and compare. |
| After reboot, containers bound to Tailscale IP are down | Check drop-in: `systemctl cat docker` should show `After=tailscaled.service`. Re-run bootstrap. |
| Laptop can't reach `100.x` | Tailscale on laptop connected? Same account? ACL `grants` allow `autogroup:member → tag:server`? |
| `ys-vps` name doesn't resolve | MagicDNS off on tailnet, or laptop `--accept-dns=false`. Use IP. |
| Node shows "Expired" in admin | Click **Disable key expiry**, then on host: `tailscale up --force-reauth` with a new auth key. |

Useful host commands:

```bash
tailscale status          # peers + connection type (direct / relay)
tailscale ip -4           # this host's tailnet IPv4
tailscale netcheck        # NAT / DERP diagnostics
journalctl -u tailscaled -n 100 --no-pager
```

## Rebuilding / replacing the VPS

1. Admin console → **Machines** → old `ys-vps` → **Remove**.
2. Generate a new auth key (Step 4), update `TAILSCALE_AUTHKEY` secret.
3. Run **Bootstrap host** on the new VPS.
4. New node gets a **new 100.x IP** → update `TAILSCALE_IP` in `.env` (Step 7).
   Tip: in admin console you can **edit the machine's IP** to reuse the old one.
