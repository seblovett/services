# Self-hosted services (VPN-only)

A Docker Compose stack on a DigitalOcean droplet, plus Cockpit running
natively on the host. All web services are reachable **only through the
WireGuard VPN**. The only port open to the
internet is UDP 51820 (WireGuard).

| Service | URL | Container | Internal port |
|---|---|---|---|
| Homepage (dashboard) | `https://home.<domain>` | `homepage` | 3000 |
| Actual Budget | `https://budget.<domain>` | `actual` | 5006 |
| Part-DB | `https://parts.<domain>` | `partdb` | 80 |
| wg-easy (VPN admin) | `https://wg.<domain>` | `wg-easy` | 51821 |
| Traefik dashboard | `https://traefik.<domain>` | `traefik` | (internal) |
| Cockpit (host admin) | `https://cockpit.<domain>` | none (runs natively on the host) | 9090 on `172.20.0.1` |

> Keep this table up to date if you rename a subdomain (see
> [Changing a subdomain](#changing-a-subdomain)).

---

## Contents

1. [Architecture](#architecture)
2. [Files and folders](#files-and-folders)
3. [How a request reaches a service](#how-a-request-reaches-a-service)
4. [Networking and IP plan](#networking-and-ip-plan)
5. [DNS and certificates](#dns-and-certificates)
6. [How Traefik routing works (labels)](#how-traefik-routing-works-labels)
7. [The services in detail](#the-services-in-detail)
8. [First-time setup](#first-time-setup)
9. [Day-to-day operations](#day-to-day-operations)
10. [Backups and restore](#backups-and-restore)
11. [Troubleshooting](#troubleshooting)
12. [Security notes](#security-notes)

---

## Architecture

```
                Internet
                   │
                   │  UDP 51820 only (firewall blocks everything else except SSH)
                   ▼
   ┌──────────────────────────── Droplet ────────────────────────────┐
   │                                                                 │
   │   wg-easy  ── decrypts VPN traffic, NATs it into ──┐            │
   │                                                    ▼            │
   │   ┌────────────── Docker network "proxy" (172.20.0.0/24) ─────┐ │
   │   │                                                           │ │
   │   │   traefik (172.20.0.10)  ── routes by hostname ──►        │ │
   │   │        homepage · actual · partdb · wg-easy UI            │ │
   │   └───────────────────────────────────────────────────────────┘ │
   │                                                                 │
   │   ┌─── Docker network "socket" (internal, no internet) ───┐     │
   │   │   socket-proxy ◄── traefik, homepage (read-only API)  │     │
   │   └───────────────────────────────────────────────────────┘     │
   │                                                                 │
   │   cockpit (native, runs on the host, not in Docker)             │
   │        listens on 172.20.0.1:9090 ◄── traefik (file provider)   │
   └─────────────────────────────────────────────────────────────────┘
```

Key design points:

- **Traefik publishes no host ports.** It is not listening on the droplet's
  public interface at all. It's only reachable from inside the `proxy`
  Docker network, and VPN clients are routed into that network by wg-easy.
- **Split tunnel.** VPN clients only send traffic for `10.8.0.0/24` (the VPN
  itself) and `172.20.0.0/24` (the Docker network) through the tunnel. Normal
  browsing doesn't go through the droplet.
- **One wildcard certificate** (`*.<domain>`) from Let's Encrypt, obtained
  via Cloudflare DNS, so the server never needs to be publicly reachable for
  certificate issuance.
- **No container gets the raw Docker socket.** Traefik and Homepage talk to a
  filtered, read-only socket proxy instead.
- **Cockpit is the one non-Docker service.** It administers the host itself,
  so it runs natively and is bound to the `proxy` bridge gateway
  (`172.20.0.1`) instead of all interfaces. Traefik reaches it through a
  file-provider route.

---

## Files and folders

The Compose project lives in the `services` folder (Compose uses the folder
name as the project name, so **always run `docker compose` from this
folder**).

```
services/
├── docker-compose.yml     # all service definitions
├── .env                   # secrets and settings (chmod 600, never commit)
├── .env.example           # template for .env
├── README.md              # this file
├── backup.sh              # backup script (restic → off-site storage)
├── backup.env             # restic repository + credentials (chmod 600, never commit)
├── backup.env.example     # template for backup.env
├── homepage/              # Homepage config (mounted at /app/config)
│   ├── services.yaml      # tiles shown on the dashboard
│   ├── docker.yaml        # how Homepage reaches Docker (via socket-proxy)
│   └── ...                # other files Homepage creates on first start
├── traefik-dynamic/       # Traefik file-provider routes (non-Docker services)
│   └── cockpit.yml        # routes cockpit.<domain> to the host's Cockpit
└── data/                  # all persistent data (BACK THIS UP)
    ├── wg-easy/           # WireGuard keys, clients, wg-easy database
    ├── traefik/           # acme.json (certificates)
    ├── partdb/            # uploads/, public_media/, db/ (SQLite)
    └── actual/            # Actual Budget server files and budgets
```

Cockpit's own configuration lives on the host, outside this folder (see
[Cockpit](#cockpit-host-admin-ui)).

### `.env` variables

| Variable | Purpose |
|---|---|
| `DOMAIN` | Base domain; subdomains are built from it |
| `ACME_EMAIL` | Let's Encrypt account email (expiry notices) |
| `CF_DNS_API_TOKEN` | Cloudflare token (Zone → DNS → Edit) for certificate issuance |
| `WG_HOST` | Public IP of the droplet; written into client VPN configs |
| `WG_ADMIN_USER` / `WG_ADMIN_PASSWORD` | Initial wg-easy login (first start only) |
| `TZ` | Timezone for Part-DB and Homepage |
| `CURRENCY` | Part-DB base currency |

---

## How a request reaches a service

Example: opening `https://home.<domain>` with the VPN connected.

1. **DNS:** the browser looks up `home.<domain>`. The Cloudflare wildcard
   record `*` answers `172.20.0.10`.
2. **VPN routing:** `172.20.0.0/24` is in the client's WireGuard
   `AllowedIPs`, so the packet goes through the tunnel to the droplet.
3. **wg-easy:** decrypts the packet and NATs (masquerades) it out of its
   `eth0` interface into the `proxy` Docker network. Services therefore see
   wg-easy's container IP as the client address, not your VPN IP.
4. **Traefik:** receives the HTTPS request at `172.20.0.10:443`, terminates
   TLS with the wildcard certificate, and matches the hostname against its
   routers.
5. **Router match:** the router built from Homepage's labels matches
   `Host(home.<domain>)`, so Traefik forwards the request to the `homepage`
   container on port 3000.

Plain HTTP (port 80) is redirected to HTTPS by Traefik globally.

---

## Networking and IP plan

| Network | Subnet | Purpose |
|---|---|---|
| `proxy` | `172.20.0.0/24` | Traefik and every web service; VPN traffic enters here |
| `socket` | (auto) | `internal: true`; only connects the socket proxy to its clients |
| WireGuard | `10.8.0.0/24` | VPN client addresses (wg-easy default) |

Address allocation in `proxy`:

| Range | Use |
|---|---|
| `172.20.0.1` | Docker gateway (pinned in `docker-compose.yml`). Cockpit listens here |
| `172.20.0.2`–`.127` | Reserved for fixed IPs |
| `172.20.0.10` | **Traefik (fixed)**. DNS points here, so it must never change |
| `172.20.0.128`–`.254` | Automatic IPs for all other containers (`ip_range`) |

Why `ip_range` matters: without it, Docker hands out automatic addresses
from `.2` upward, and whichever container starts first can steal an address
another container is pinned to. That causes the
`failed to set up container networking: Address already in use` error.
Restricting automatic addresses to `.128/25` makes that impossible.

Why the `gateway` is pinned: when `ip_range` is set and no `gateway` is
given, Docker takes the gateway from the start of the range (here
`172.20.0.128`), not `.1`. Cockpit binds to `172.20.0.1`, so the compose
file sets `gateway: 172.20.0.1` explicitly. Changing the gateway means
recreating the network (`docker compose down`, `docker network rm proxy`,
`docker compose up -d`).

Only Traefik has a fixed IP. Everything else is reached by container name.

> **Changing the subnet** (e.g. if your home LAN also uses `172.20.x.x`):
> update all of these together:
> the `subnet`, `ip_range` and `gateway` in `docker-compose.yml`; Traefik's
> `ipv4_address`; Part-DB's `TRUSTED_PROXIES`; Cockpit's `ListenStream`
> (systemd override) and the URL in `traefik-dynamic/cockpit.yml`; the host
> firewall rule for Cockpit; the Cloudflare `*` record;
> and the `AllowedIPs` in wg-easy's admin UI (*not* `INIT_ALLOWED_IPS`, which
> only applies on first start). Then re-download or update each client
> config. Recreate the network with `docker compose down`,
> `docker network rm proxy`, `docker compose up -d`.

---

## DNS and certificates

### Cloudflare records

| Type | Name | Value | Proxy status |
|---|---|---|---|
| A | `*` | `172.20.0.10` | **DNS only** (grey cloud) |
| A | `vpn` *(optional)* | droplet public IP | DNS only |

- The wildcard covers every subdomain, so **new services don't need new DNS
  records**.
- Publishing a private IP in public DNS is harmless: it's only reachable by
  someone on the VPN.
- If `WG_HOST` is a hostname rather than an IP, it must have its own
  specific record pointing to the public IP (a specific record overrides the
  wildcard).
- The orange-cloud proxy must stay **off**: Cloudflare can't proxy to a
  private IP.

### Certificates

Traefik obtains `<domain>` + `*.<domain>` from Let's Encrypt using the
**DNS-01 challenge**: it creates a temporary TXT record via the Cloudflare
API to prove domain ownership. This works even though the server isn't
publicly reachable. Renewal is automatic.

- Stored in `data/traefik/acme.json` (must stay `chmod 600`; Traefik
  creates it that way).
- Using one wildcard means individual subdomain names don't appear in public
  certificate transparency logs.
- Watch issuance or renewal: `docker logs traefik 2>&1 | grep -i acme`
- If the Cloudflare token is rotated, update `.env` and run
  `docker compose up -d traefik`.

---

## How Traefik routing works (labels)

Traefik watches Docker (via the socket proxy) and builds its routing table
from **labels** on each container. Example (Homepage):

```yaml
labels:
  - traefik.enable=true
  - traefik.http.routers.homepage.rule=Host(`home.${DOMAIN}`)
  - traefik.http.routers.homepage.entrypoints=websecure
  - traefik.http.services.homepage.loadbalancer.server.port=3000
```

| Label | Meaning |
|---|---|
| `traefik.enable=true` | Opt in. Traefik ignores containers without it (`exposedbydefault=false`) |
| `routers.<name>.rule` | Which requests match. **This ties the subdomain to the container** |
| `routers.<name>.entrypoints=websecure` | Listen on HTTPS (443) only |
| `services.<name>.loadbalancer.server.port` | Port *inside* the container to forward to |

- `<name>` is just an identifier; it must be unique across the stack.
- `${DOMAIN}` is substituted from `.env` by Compose.
- TLS and the certificate are applied globally to the `websecure`
  entrypoint, so services don't need TLS labels.
- Traefik only routes to containers that are **running** and, if they have a
  health check, **healthy**. A container in `health: starting` (e.g. wg-easy
  right after a restart) won't appear on the dashboard for a short while.
  That's expected.

The Traefik dashboard (`https://traefik.<domain>`) shows every router, its
rule, and which container it points to. It's the quickest way to check
routing.

The global Traefik settings (entrypoints, certificate resolver, Docker
provider) are the `command:` flags on the `traefik` service.

Things that aren't Docker containers (currently only Cockpit) are routed
with the **file provider** instead: Traefik loads every YAML file in
`traefik-dynamic/` (mounted at `/dynamic`) and watches it for changes. The
domain is written literally in these files, because Traefik doesn't
substitute `${DOMAIN}` in them.

---

## The services in detail

### wg-easy (WireGuard)

- Image: `ghcr.io/wg-easy/wg-easy:15`
- Ports: `51820/udp` public (VPN); `127.0.0.1:51821` (admin UI on localhost,
  for SSH-tunnel access only).
- `INIT_*` variables run an unattended setup **on the very first start
  only**. After that, all settings (DNS, AllowedIPs, port, etc.) live in the
  admin UI and in `data/wg-easy/`. Changing `INIT_*` later does nothing
  unless `data/wg-easy/` is deleted (which also deletes all clients and
  keys).
- `INSECURE=true` allows the UI over plain HTTP. That's acceptable because
  the UI is only ever reached via Traefik (HTTPS) or a localhost SSH tunnel.
- Client DNS is `1.1.1.1` / `1.0.0.1`.
- Needs `NET_ADMIN` and `SYS_MODULE` capabilities and IP-forwarding sysctls
  to manage the WireGuard interface and NAT.

### Traefik (reverse proxy)

- Image: `traefik:v3`, fixed IP `172.20.0.10`, no published ports.
- Talks to Docker via `tcp://socket-proxy:2375`.
- Uses the `cloudflare` certificate resolver for the wildcard certificate.
- Also loads static routes from `./traefik-dynamic` (flag
  `--providers.file.directory=/dynamic`, mounted read-only at `/dynamic`).

### socket-proxy

- Image: `tecnativa/docker-socket-proxy`
- Exposes only the read-only container-listing parts of the Docker API
  (`CONTAINERS=1`, `POST=0`) on the internal `socket` network.
- The HAProxy warnings in its logs (missing timeouts, chroot, running as
  root) are normal for this image and harmless.

### Part-DB

- Image: `jbtronics/part-db1:latest`, SQLite database in
  `data/partdb/db/app.db`.
- `DB_AUTOMIGRATE=true` runs database migrations automatically on start
  (including after upgrades).
- `TRUSTED_PROXIES=172.20.0.0/24` lets it trust Traefik's forwarded headers
  (correct HTTPS URLs and redirects).
- The initial admin password is printed in `docker logs partdb` on first
  start. To reset it:
  ```bash
  docker exec --user=www-data -it partdb php bin/console partdb:users:set-password admin
  ```

### Actual Budget

- Image: `actualbudget/actual-server:latest`, data in `data/actual/`.
- Requires HTTPS to work in the browser, which Traefik provides.
- The server password is set in the web UI on first visit.

### Homepage

- Image: `ghcr.io/gethomepage/homepage:latest`, config in `homepage/`.
- `HOMEPAGE_ALLOWED_HOSTS` **must match its subdomain**, or it rejects
  requests.
- `HOMEPAGE_VAR_DOMAIN` makes `{{HOMEPAGE_VAR_DOMAIN}}` usable in its
  YAML files, so links follow the `DOMAIN` setting.
- Container status dots come from `docker.yaml` (→ socket-proxy) plus
  `server:` / `container:` on each tile in `services.yaml`.
- Config changes are picked up automatically; just refresh the page.

### Cockpit (host admin UI)

The one service that does **not** run in Docker. Cockpit is a web UI for
administering the host itself (logs, updates, storage, networking, a
terminal), so it runs natively from the Ubuntu package under systemd
(`cockpit.socket`) rather than in a container.

- **URL:** `https://cockpit.<domain>` (via Traefik), or directly at
  `https://172.20.0.1:9090` (self-signed certificate warning). The direct
  address doesn't depend on Traefik or the Docker services, so it's a handy
  fallback when something in the stack is broken.
- **Bound to `172.20.0.1:9090` only**, the host's address on the `proxy`
  bridge. It's reachable from the host, from containers on `proxy`, and from
  VPN clients (their traffic for `172.20.0.0/24` goes through the tunnel). It
  is not reachable from the LAN or the internet. Cockpit's default is all
  interfaces on port 9090, so don't remove the override below.
- **Login** is a host account. A sudo-capable user gets what is effectively a
  root shell, so use a strong password.
- **Updates** come with the host's packages (`apt upgrade`), not Docker.

Its configuration lives in three places. The first two are on the host,
outside this folder:

`/etc/systemd/system/cockpit.socket.d/override.conf` (create it with
`sudo systemctl edit cockpit.socket`):

```ini
[Socket]
ListenStream=
ListenStream=172.20.0.1:9090
FreeBind=yes
```

`FreeBind=yes` lets the socket start at boot before Docker has created the
bridge. A side effect: `ss` shows the listener even if the address doesn't
exist, so also confirm with `ip -br addr | grep 172.20.0.1`.

`/etc/cockpit/cockpit.conf` (use the real domain; `Origins` is required for
websockets behind a proxy, and `AllowUnencrypted` is needed because Traefik
talks plain HTTP to Cockpit over the bridge):

```ini
[WebService]
Origins = https://cockpit.<domain> wss://cockpit.<domain>
ProtocolHeader = X-Forwarded-Proto
AllowUnencrypted = true
```

`traefik-dynamic/cockpit.yml` (in this folder; real domain again):

```yaml
http:
  routers:
    cockpit:
      rule: Host(`cockpit.<domain>`)
      entryPoints: [websecure]
      service: cockpit
  services:
    cockpit:
      loadBalancer:
        servers:
          - url: http://172.20.0.1:9090
```

Traefik's compose entry needs `--providers.file.directory=/dynamic` in
`command:` and `- ./traefik-dynamic:/dynamic:ro` under `volumes:`.

To apply after changes:

```bash
sudo systemctl daemon-reload && sudo systemctl restart cockpit.socket
docker compose up -d traefik     # only needed when the flag/volume changed;
                                 # edits to files in traefik-dynamic/ are live
```

If the host firewall is active (e.g. ufw), the proxy subnet must be allowed
to reach Cockpit, since Traefik's requests arrive from the bridge:

```bash
sudo ufw allow from 172.20.0.0/24 to any port 9090 proto tcp
```

---

## First-time setup

For rebuilding from scratch (e.g. on a new droplet).

1. **Droplet:** install Docker with the Compose plugin. Set the firewall
   (DigitalOcean Cloud Firewall preferred) to allow inbound **22/tcp** and
   **51820/udp** only.
2. **Cloudflare:** create the DNS records above and an API token from the
   *Edit zone DNS* template, scoped to the domain.
3. **Config:** copy this folder to the droplet, then:
   ```bash
   cp .env.example .env && chmod 600 .env   # then edit .env
   docker compose up -d
   ```
4. **First VPN client:** the wg-easy UI isn't reachable before you're on the
   VPN, so tunnel to it over SSH:
   ```bash
   ssh -L 51821:127.0.0.1:51821 you@<droplet-ip>
   ```
   Open `http://localhost:51821`, log in, create a client, and scan the QR
   code or import the `.conf`.
5. **Connect** and open the service URLs. The first certificate can take a
   minute or two to issue.
6. **App setup:** set the Actual server password; log in to Part-DB with the
   password from its logs and change it.
7. **Cockpit (host admin):** `sudo apt install cockpit`, then create the
   override, `cockpit.conf` and `traefik-dynamic/cockpit.yml` described in
   [Cockpit](#cockpit-host-admin-ui). These are the only parts of the
   setup outside the Compose project.

When restoring from a backup instead, put `data/` and `homepage/` back
before step 3. Existing VPN clients keep working if `data/wg-easy/` is
restored and the droplet keeps the same public IP (otherwise update the
host in the wg-easy admin UI and re-download client configs).

---

## Day-to-day operations

### Applying changes

```bash
docker compose up -d
```

This compares the file with what's running and recreates **only** the
containers whose config changed. No `down` is needed. Use `down` only when
changing network definitions, and then also run `docker network rm proxy`
before `up`.

### Adding a VPN client

Open `https://wg.<domain>` → new client → scan the QR code or download the
config. One client per device.

### Changing a subdomain

1. Edit the `Host(...)` rule in that service's labels.
2. For Homepage, also update `HOMEPAGE_ALLOWED_HOSTS`.
3. Update the link in `homepage/services.yaml` and the table at the top of
   this file.
4. `docker compose up -d`

No DNS or certificate changes are needed: the wildcard covers it.

Cockpit is the exception to the label-based steps above: its hostname is
written literally in `traefik-dynamic/cockpit.yml` and in the `Origins`
line of `/etc/cockpit/cockpit.conf`, so update both (and restart
`cockpit.socket`).

### Adding a new service

1. Add it to `docker-compose.yml`, on the `proxy` network, **without** a
   fixed IP:
   ```yaml
     myapp:
       image: example/myapp:latest
       container_name: myapp
       restart: unless-stopped
       volumes:
         - ./data/myapp:/data
       networks:
         - proxy
       labels:
         - traefik.enable=true
         - traefik.http.routers.myapp.rule=Host(`myapp.${DOMAIN}`)
         - traefik.http.routers.myapp.entrypoints=websecure
         - traefik.http.services.myapp.loadbalancer.server.port=8080
   ```
2. Do **not** add a `ports:` section; that would expose it on the droplet's
   public IP, bypassing the VPN.
3. If the app has a "trusted proxies" or "base URL" setting, set it
   (proxies: `172.20.0.0/24`; URL: `https://myapp.<domain>`).
4. Optionally add a tile in `homepage/services.yaml`.
5. `docker compose up -d`, then check the Traefik dashboard for the new
   router.

### Updating images

```bash
docker compose pull
docker compose up -d
docker image prune -f      # remove old image versions
```

Back up first. Check release notes for breaking changes, especially wg-easy
(pinned to major version 15) and Traefik (pinned to v3). Part-DB migrates
its database automatically on start. Cockpit isn't a container; it updates
with the host (`sudo apt upgrade`).

### Backups

See [Backups and restore](#backups-and-restore) for the full guide. Quick
manual backup:

```bash
sudo ./backup.sh
```

### Useful commands

```bash
docker compose ps                     # status of all services
docker compose logs -f <service>      # follow a service's logs
docker compose restart <service>      # restart one service
docker exec wg-easy wg show           # live WireGuard peers and handshakes
ss -tlnp | grep 9090                  # Cockpit should be bound to 172.20.0.1 only
docker network inspect proxy --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'
```

## Backups and restore

### What needs backing up

| Path | Contains | If lost |
|---|---|---|
| `data/actual/` | Actual server data: budget files, sync data | Budgets gone (unless a device still has a local copy) |
| `data/partdb/` | SQLite database, uploaded attachments, images | Whole parts inventory gone |
| `data/wg-easy/` | WireGuard server keys, clients, admin login | Every device must be re-enrolled |
| `data/traefik/acme.json` | Certificates | Not critical, Traefik re-issues automatically |
| `homepage/` | Dashboard config | Minor, easy to recreate |
| `.env`, `docker-compose.yml`, `README.md`, `traefik-dynamic/` | Configuration and secrets | Stack can't be rebuilt as-is |

Docker images are **not** backed up; they're re-downloaded with
`docker compose pull`.

Cockpit's host files (`/etc/cockpit/cockpit.conf` and the systemd override)
are outside the `services` folder, so the backup doesn't cover them unless
you add them to `backup.sh`. They're small; the [Cockpit](#cockpit-host-admin-ui)
section has everything needed to recreate them.

### Why the stack is stopped during a backup

Part-DB, Actual and wg-easy all use SQLite databases. Copying a SQLite file
while it's being written can produce a corrupt backup. The backup script
stops the containers, takes the backup, and starts them again, typically a
downtime of under a minute.

### The approach: restic to off-site storage

A backup kept only on the droplet doesn't survive the droplet being
destroyed, so backups go **off-site** using
[restic](https://restic.net/):

- **Encrypted** before leaving the droplet. Important, since the backup
  holds VPN private keys and the Cloudflare token.
- **Deduplicated and incremental**: after the first run, only changes are
  uploaded, so daily backups are cheap.
- **Snapshots with retention**: keeps 7 daily, 4 weekly and 6 monthly
  snapshots, so you can go back to before a mistake, not just to last night.
- Works with many storage targets: S3-compatible object storage
  (DigitalOcean Spaces, Backblaze B2, Wasabi), SFTP to another machine, and
  more.

Files involved:

| File | Purpose |
|---|---|
| `backup.sh` | Stops the stack, runs restic, restarts, applies retention |
| `backup.env` | Repository location, restic password, storage credentials |
| `backup.env.example` | Template for `backup.env` |

### One-time setup

1. **Install restic** on the droplet:
   ```bash
   sudo apt update && sudo apt install -y restic
   ```
2. **Create storage.** For example, a DigitalOcean Spaces bucket (in a
   different region from the droplet if you want region-level safety) plus a
   Spaces access key. Any restic-supported backend works.
3. **Configure:**
   ```bash
   cp backup.env.example backup.env && chmod 600 backup.env   # then edit
   chmod +x backup.sh
   ```
4. **Initialise the repository** (once):
   ```bash
   sudo bash -c 'set -a; source backup.env; restic init'
   ```
5. **Save the restic password somewhere off the droplet**, e.g. in your
   password manager. **Without it the backups cannot be decrypted, by
   anyone.** Losing the droplet *and* this password means losing everything.
6. **Run a first backup** and check it worked:
   ```bash
   sudo ./backup.sh
   sudo bash -c 'set -a; source backup.env; restic snapshots'
   ```

Run the script with `sudo`: some files in `data/` are owned by the users
inside the containers, so only root can read all of them.

### Scheduling (daily)

```bash
sudo crontab -e
```

Add (adjust the path to where the `services` folder lives):

```
30 3 * * * /root/services/backup.sh >> /var/log/selfhost-backup.log 2>&1
```

This runs at 03:30 every day, in the droplet's timezone (usually UTC).
Check the log occasionally: `sudo tail -n 50 /var/log/selfhost-backup.log`.

### Restoring

**A single file or folder** (e.g. Part-DB attachments deleted by mistake):

```bash
sudo bash -c 'set -a; source backup.env; restic snapshots'      # pick a snapshot ID, or use "latest"
sudo bash -c 'set -a; source backup.env; restic restore latest --target /tmp/restore --include /root/services/data/partdb'
```

Inspect `/tmp/restore`, then stop the affected service, copy the files back
into place, and start it again:

```bash
docker compose stop partdb
sudo cp -a /tmp/restore/root/services/data/partdb/. data/partdb/
docker compose start partdb
```

Restic stores the full original path, which is why the restored files
appear under `/tmp/restore/root/services/...`.

**Everything, on a new droplet:**

1. Install Docker and restic, and set up the firewall (see
   [First-time setup](#first-time-setup), step 1).
2. Recreate `backup.env` (from your password manager) and restore into the
   original path:
   ```bash
   sudo bash -c 'set -a; source backup.env; restic restore latest --target /'
   ```
3. `cd` into the `services` folder and run `docker compose up -d`.
4. If the new droplet has a **different public IP**: update `WG_HOST` in
   `.env`, change the host in the wg-easy admin UI, and re-import the client
   config on each device. With the same IP (e.g. a DigitalOcean reserved IP),
   existing VPN clients keep working.

### Test your restores

A backup that has never been restored is a hope, not a backup. Every few
months:

- Run `sudo bash -c 'set -a; source backup.env; restic check'` to verify
  the repository's integrity.
- Restore the latest snapshot to `/tmp/restore` and check a few files open,
  e.g. that `data/partdb/db/app.db` is there and non-empty.

### Extra layers (optional)

- **DigitalOcean droplet backups/snapshots** give a quick whole-machine
  rollback. They complement restic but don't replace it: they're in the
  same account and aren't consistent snapshots of running databases.
- **Actual Budget export** (Settings → Export data) gives a portable copy
  of a budget that can be imported into any Actual install.

---

## Troubleshooting

### `failed to set up container networking: Address already in use`

Usually a container IP collision on the `proxy` network.

1. See which container is stuck in `Created`: `docker compose ps -a`
2. Check the IP layout with the `network inspect` command above. Automatic
   IPs should all be **.128 or higher**; only Traefik should be below that
   (at `.10`). If other containers have low addresses, the `ip_range` isn't
   in effect:
   ```bash
   grep -n -E 'ip_range|ipv4_address|gateway' docker-compose.yml
   ```
   This should print exactly three lines: `ip_range: 172.20.0.128/25`,
   `gateway: 172.20.0.1`, and Traefik's `ipv4_address: 172.20.0.10`. Fix the
   file, then:
   ```bash
   docker compose down && docker network rm proxy && docker compose up -d
   ```
3. If the stuck container is wg-easy and the IPs look right, check the port:
   `sudo ss -tulpn | grep -E '51820|51821'`.
4. Check for duplicate containers from another Compose project (from running
   Compose in a different folder):
   ```bash
   docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Label "com.docker.compose.project"}}'
   ```
5. Last resort: `docker compose down --remove-orphans`,
   `sudo systemctl restart docker`, `docker compose up -d`.

### A subdomain doesn't load

- **VPN connected?** Check for a recent handshake: `docker exec wg-easy wg show`
- **DNS resolves to 172.20.0.10?** `nslookup home.<domain>`. If it doesn't
  resolve on some networks, the router or DNS filter may be blocking private
  IPs in DNS answers (DNS rebind protection). The VPN's `1.1.1.1` DNS
  normally avoids this; check the device isn't overriding DNS.
- **Router on the Traefik dashboard?** If missing: check the container is
  `Up` and healthy, and its labels are present:
  ```bash
  docker inspect <container> --format '{{json .Config.Labels}}' | tr ',' '\n' | grep traefik
  ```
  A YAML indentation slip can silently drop labels: `labels:` must line up
  with `networks:`. Right after a restart, wait for health checks to pass.
- **Certificate warning?** Check `docker logs traefik 2>&1 | grep -i acme`
  for Cloudflare token or rate-limit errors.

### Cockpit doesn't load

Work from the inside out:

1. **Is the address on the host?** `ip -br addr | grep 172.20.0.1` must show
   it on a `br-...` interface. If not, the `proxy` network has a different
   gateway (`docker network inspect proxy --format '{{json .IPAM.Config}}'`),
   usually because `gateway:` isn't pinned or the network wasn't recreated
   after pinning it. `ss -tlnp | grep 9090` is **not** proof: with `FreeBind`
   it shows the listener even when the address doesn't exist.
2. **Does it answer on the host?** `curl -kI https://172.20.0.1:9090`
3. **Can containers reach it?**
   `docker run --rm --network proxy curlimages/curl -kI https://172.20.0.1:9090`.
   A timeout here (when step 2 works) means the host firewall; see the ufw
   rule in the [Cockpit](#cockpit-host-admin-ui) section.
4. **Is Traefik routing it?** The dashboard should list a `cockpit@file`
   router. If not, check the file provider flag and volume, that
   `traefik-dynamic/cockpit.yml` exists, and `docker logs traefik --tail 50`.
5. **Page loads but login or the websocket fails?** The `Origins` line in
   `/etc/cockpit/cockpit.conf` must match the hostname exactly.

### Homepage shows "Host validation failed"

`HOMEPAGE_ALLOWED_HOSTS` doesn't match the subdomain you're using.

### Part-DB redirects to `http://` or wrong URLs

Check `TRUSTED_PROXIES` covers the `proxy` subnet.

---

## Security notes

- Only **22/tcp** and **51820/udp** should be open inbound. Docker-published
  ports bypass `ufw`, which is why no service except wg-easy publishes a
  port and the wg-easy UI binds to `127.0.0.1` only. Prefer the DigitalOcean
  Cloud Firewall, which sits outside the droplet and can't be bypassed by
  Docker.
- **Cockpit** is a native host service, so the Docker/ufw port-publishing
  issue above doesn't apply, but it must never listen on a public address
  (its default is all interfaces on 9090). It's bound to `172.20.0.1`;
  verify with `ss -tlnp | grep 9090`. A Cockpit login is effectively root on
  the host, so use a strong password.
- Consider restricting SSH to key-only auth (and ideally to known IPs).
- `.env`, `backup.env`, `data/wg-easy/` and `data/traefik/acme.json` contain secrets. Keep
  them out of git and out of unencrypted backups.
- Anyone with a VPN client config can reach every service. Revoke lost or
  old devices in the wg-easy UI, and keep strong passwords on each app,
  since the VPN is the outer layer, not the only one.
- All services see wg-easy's container IP as the client address (because of
  NAT), so per-user IP restrictions inside apps won't distinguish VPN
  clients.
