# Architecture

A sealed home server: **nothing is published to the internet**. No open router ports, no Cloudflare tunnel.
Every service is reached over Tailscale, by name (`*.homelab.internal`), with TLS certificates signed by a
private CA you own. The only traffic that leaves the box on its own is outbound: alerts (Telegram) and
heartbeats (healthchecks.io).

## The big picture

```
   laptop ──┐                                   ┌──────────────── server (100.64.0.10) ─────────────────┐
            │       Tailscale (WireGuard)       │                                                        │
   phone ───┼──────────── tailnet ─────────────►│  :53   Pi-hole + unbound   DNS, ad blocking,           │
            │   ACL: only laptop/phone may      │                            *.homelab.internal -> server│
            │   connect; server can't dial out  │                                                        │
            │                                   │  :443  Caddy  (TLS from Homelab intermediate CA)       │
            │                                   │          home.   -> 127.0.0.1:3000  Homepage           │
            │                                   │          dns.    -> 127.0.0.1:8053  Pi-hole UI         │
            │                                   │          photos. -> 127.0.0.1:2283  Immich             │
            │                                   │          n8n.    -> 127.0.0.1:5678  n8n                │
            │                                   │                                                        │
            │                                   │  :445  Samba  (SMB3, encryption required)              │
            │                                   │                                                        │
            │                                   │  host: systemd timers, hl-notify ──► Telegram (out)    │
            └───────────────────────────────────┴────────────────────────────────────────────────────────┘
   Internet → server: nothing. Router has no port forwards.
```

## How a request flows

Example: the phone opens `https://photos.homelab.internal`.

1. **Tailscale is on**, so the phone's DNS server is the Pi-hole at `100.64.0.10` (set in the Tailscale admin
   console under *DNS → Nameservers*, restricted to the `homelab.internal` domain or global).
2. **Pi-hole** answers `photos.homelab.internal → 100.64.0.10` from one wildcard line
   (`address=/homelab.internal/100.64.0.10`). Everything else goes to **unbound**, a local recursive
   resolver, so no third-party DNS provider sees your lookups.
3. The phone connects to `100.64.0.10:443` through the WireGuard tunnel. The **tailnet policy**
   (`policy/tailnet.hujson`) allows it: phone → `tag:server` on 443.
4. **Caddy** binds *only* the tailnet IP (`default_bind`). It matches the host name, checks the source IP
   against the matcher's `remote_ip` list (n8n is laptop-only, for example), and proxies to the app on
   `127.0.0.1`. Apps never bind a public or LAN interface.
5. The certificate Caddy presents is a short-lived leaf signed by the **Homelab intermediate CA**. The phone
   trusts it because you installed the **Homelab root** once. The root key is not on the server at all.

## Trust: the private CA (`pki/`)

```
 Homelab Root CA   (key: offline, in your password manager + paper; never on the server)
       │  signs once, path length 0, name-constrained to .homelab.internal
       ▼
 Homelab Intermediate CA   (key: on the server, root-only file, mounted read-only into Caddy)
       │  Caddy issues automatically
       ▼
 leaf certs for *.homelab.internal   (short-lived, rotated by Caddy)
```

`pki/ceremony.sh` walks you through creating both, copying the intermediate to the server, trusting the root
on your devices, and proving the **name constraint** works (a cert for any other domain must fail). Even if the
server is stolen, the attacker can only mint certs for `.homelab.internal`.

## Network isolation, in layers

| Layer | What it enforces |
|---|---|
| Router | No port forwards. The server is just another LAN client. |
| Tailscale ACL (`policy/tailnet.hujson`) | Only `laptop` and `phone` can reach the server, on a short list of ports. The server (`tag:server`) is never a source, so a compromised container cannot reach your devices. Built-in `tests` block the paste if a rule regresses. |
| Port binding | Docker publishes to `127.0.0.1` (apps) or the tailnet IP (Samba, DNS). Nothing on `0.0.0.0`. |
| Caddy matchers | Per-service `remote_ip` allow-lists on top of the ACL. |
| Containers | `no-new-privileges`, dropped capabilities, memory limits, images pinned by digest. |

## Folder layout and naming

```
00-core/      always-on infrastructure      containers named core-*
  caddy/      reverse proxy + TLS
  pihole/     DNS + unbound
  homepage/   dashboard
  alerts/     hl-notify (host script) + its test
01-personal/  your data                      personal-*
  immich/     photos
  samba/      file share ("Vault")
02-forge/     building and automation        forge-*
  n8n/
pki/          CA ceremony + step-cli certificate templates
policy/       Tailscale policy (source of truth)
post-reboot-check.sh
```

Outside the repo, on the server:

```
/srv/data/<container>/   live state (databases, config)   never in git
/etc/homelab/            secrets for host scripts, root only
/usr/local/sbin/hl-*     host scripts, run by systemd timers
```

## Alerts (`00-core/alerts/hl-notify`)

`hl-notify <topic> <message>` sends one line to Telegram. `hl-critical` and `hl-warn` ring; everything
else is silent. If the send fails (internet down), the message is **spooled** and delivered, tagged
"delayed", on the next call that gets through. The bot token is passed to curl on stdin, so it never shows
up in `ps`. Backup and watchdog timers call it; healthchecks.io catches the case where the box is entirely dead.

## Boot and recovery

- Hardware watchdog + `RuntimeWatchdogSec` reboot a hung kernel within about 1–2 minutes.
- `post-reboot-check.sh` runs at boot and writes a snapshot (containers, disks, timers) you can read afterwards.
- All containers use `restart: unless-stopped`; data lives in `/srv/data`, so a container can be deleted and recreated freely.
