# homelab-public

A **sealed** self-hosted home server: photos, files, DNS, automation, all over Tailscale with your own
certificate authority, and **zero ports open to the internet**.

This is a cleaned-up template of a real, running setup. All names, IPs and secrets are placeholders.

→ **How it all fits together: [ARCHITECTURE.md](ARCHITECTURE.md)**

## What you get

| Service | URL | What it does |
|---|---|---|
| Pi-hole + unbound | `dns.homelab.internal` | Network-wide ad blocking, private recursive DNS, and the `*.homelab.internal` names |
| Caddy | `*.homelab.internal` | Reverse proxy with TLS from your private CA, bound only to the tailnet IP |
| Homepage | `home.homelab.internal` | Dashboard |
| Immich | `photos.homelab.internal` | Google Photos replacement, with phone backup |
| Samba | `smb://vault.homelab.internal/Vault` | Encrypted (SMB3) file share |
| n8n | `n8n.homelab.internal` | Workflow automation (laptop only) |
| hl-notify | — | Alerts to Telegram, with an offline spool |

## Requirements

- A small always-on machine (any mini PC) running Linux, with Docker + Compose v2
- A free [Tailscale](https://tailscale.com) account
- [`step` CLI](https://smallstep.com/docs/step-cli/installation/) and `openssl` on your laptop (for the CA ceremony)
- A password manager (the root CA key lives there, not on the server)

## Tutorial

Placeholder values used below. Replace them everywhere (`grep -rn 100.64.0` helps):

| Placeholder | Meaning |
|---|---|
| `100.64.0.10` | server's Tailscale IP |
| `100.64.0.20` / `100.64.0.30` | laptop / phone Tailscale IPs |
| `192.168.1.2` | server's LAN IP |
| `homelab.internal` | your private domain (keep `.internal`, it's reserved for private use) |
| `admin` | your Linux / Samba user |

### 1. Prepare the server

```bash
sudo apt install docker.io docker-compose-v2 git
sudo usermod -aG docker $USER            # log out and back in
git clone https://github.com/karemverse/homelab-public.git ~/homelab
sudo mkdir -p /srv/data /etc/homelab && sudo chmod 700 /etc/homelab
```

### 2. Join the tailnet and lock it down

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --advertise-tags=tag:server
tailscale ip -4                            # note it: this is your 100.64.0.10
```

Install Tailscale on your laptop and phone too. Then open the admin console → **Access controls** and paste
`policy/tailnet.hujson` (with your device IPs). The console runs the `tests` block and refuses the paste if a rule is wrong.

### 3. Create your certificate authority

On your **laptop** (not the server):

```bash
cd ~/homelab/pki && bash ceremony.sh
```

It creates the root CA (key goes to your password manager, then is deleted), signs an intermediate, copies
the intermediate to `/srv/data/core-caddy/pki/` on the server, trusts the root on the laptop, and runs a
negative test proving certs outside `.homelab.internal` are rejected. Install `homelab-root.crt` on your phone as well.

### 4. Fill in the secrets

```bash
cd ~/homelab
for f in $(find . -name '.env.example'); do cp -n "$f" "${f%.example}"; done
chmod 600 */*/.env
$EDITOR 00-core/pihole/.env 01-personal/immich/.env 01-personal/samba/.env 02-forge/n8n/.env
```

`.env` files are gitignored. Use long random values (`openssl rand -hex 32`).

### 5. Start the core

Order matters: DNS first, then the proxy.

```bash
docker network create dns
cd 00-core/pihole   && docker compose up -d && cd -
cd 00-core/caddy    && docker compose up -d && cd -
cd 00-core/homepage && docker compose up -d && cd -
```

In Pi-hole, add the wildcard so every service name resolves to the server
(`/srv/data/core-pihole/dnsmasq.d/99-homelab.conf`):

```
address=/homelab.internal/100.64.0.10
```

Then, in the Tailscale admin console → **DNS**, add `100.64.0.10` as a nameserver. Check from your laptop:

```bash
dig +short home.homelab.internal          # -> 100.64.0.10
curl -I https://home.homelab.internal     # -> 200, no certificate warning
```

### 6. Add your services

```bash
cd 01-personal/immich && docker compose up -d && cd -
cd 01-personal/samba  && docker compose up -d && cd -
cd 02-forge/n8n       && docker network create homelab-apps 2>/dev/null; docker compose up -d && cd -
```

Install the Immich app on your phone with server URL `https://photos.homelab.internal` (Tailscale on).
Mount the share from a Mac with `smb://vault.homelab.internal/Vault`.

**Adding a new service** is three steps: bind it to `127.0.0.1:<port>`, add a matcher + `reverse_proxy` block to
the `Caddyfile`, and `docker exec core-caddy caddy reload --config /etc/caddy/Caddyfile --address unix//config/caddy-admin.sock`. DNS already works through the wildcard.

### 7. Alerts and boot checks

```bash
sudo install -m 755 00-core/alerts/hl-notify /usr/local/sbin/hl-notify
sudo install -m 640 00-core/alerts/telegram.env.example /etc/homelab/telegram.env   # then edit it
bash 00-core/alerts/hl-notify.test.sh      # offline test, uses a fake curl
hl-notify hl-warn "hello from the homelab"
```

Run `post-reboot-check.sh` from a systemd unit at boot to get a health snapshot after every restart.

## Security model, in one line each

- No inbound internet path. Remote access is Tailscale only.
- The server can't start connections to your devices (ACL).
- Apps listen on `127.0.0.1` and the proxy listens on the tailnet IP. Nothing listens on `0.0.0.0`.
- The root CA key is offline. A stolen server can only mint `.homelab.internal` certs.
- Images are pinned by digest, and containers drop capabilities and run with `no-new-privileges`.

## License

MIT
