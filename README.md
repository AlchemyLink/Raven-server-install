# Raven Server Install

Languages: **English** | [Русский](README.ru.md)

[![CI](https://github.com/AlchemyLink/Raven-server-install/actions/workflows/xray-config-test.yml/badge.svg)](https://github.com/AlchemyLink/Raven-server-install/actions/workflows/xray-config-test.yml)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL_2.0-brightgreen.svg)](LICENSE)
[![Ansible](https://img.shields.io/badge/Ansible-%3E%3D2.14-red?logo=ansible)](https://docs.ansible.com/)
[![Platform](https://img.shields.io/badge/Platform-Debian%2011%2B%20%7C%20Ubuntu%2020.04%2B-blue)](https://www.debian.org/)
[![Status](https://img.shields.io/badge/Status-Alpha%20Testing-orange)](https://github.com/AlchemyLink/Raven-server-install)

Ansible playbooks for deploying a production-ready self-hosted VPN server stack based on [Xray-core](https://github.com/XTLS/Xray-core) and [Raven-subscribe](https://github.com/AlchemyLink/Raven-subscribe). Designed for censorship circumvention with traffic indistinguishable from regular HTTPS.

> [!WARNING]
> **Alpha Testing** — This project is under active development. APIs, variable names, and deployment procedures may change between versions. Test thoroughly before using in production. Please [report issues](https://github.com/AlchemyLink/Raven-server-install/issues) to help us improve.

**What you get:**

- Xray-core with VLESS + XTLS-Reality (TCP) and VLESS + XHTTP (HTTP/2) inbounds
- V2 parallel inbounds with isolated Reality keys for forward secrecy
- Post-quantum VLESS Encryption (mlkem768x25519plus, Xray-core ≥ 26.x)
- nginx SNI routing on port 443 — all VPN traffic goes through standard HTTPS port
- Optional RU chain proxy (`xray_bridge` role) — RU VPS accepts client connections with EU keys, chains to EU via XHTTP
- Optional Hysteria2 via [sing-box](https://github.com/SagerNet/sing-box)
- [Raven-subscribe](https://github.com/AlchemyLink/Raven-subscribe) — subscription server: auto-discovers users, serves client configs via personal URLs
- [xray-stats-exporter](https://github.com/AlchemyLink/xray-stats-exporter) + VictoriaMetrics + Grafana — monitoring with per-user and per-inbound traffic dashboards
- Systemd services with config validation before every reload
- Ad and tracker blocking via geosite routing rules
- BBR congestion control and sysctl tuning (`srv_prepare` role)

---

## Table of Contents

- [Architecture](#architecture)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Role Reference](#role-reference)
- [Secrets](#secrets)
- [Configuration](#configuration)
- [Examples](#examples)
- [DNS Setup](#dns-setup)
- [VLESS Encryption (optional)](#vless-encryption-optional)
- [Hysteria2 / sing-box (optional)](#hysteria2--sing-box-optional)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [Related Projects](#related-projects)
- [License](#license)

---

## Architecture

This repo supports two deployment topologies:

### Single-server (minimal)

One VPS running Xray + Raven-subscribe + nginx frontend. All traffic enters on port 443 — nginx routes by SNI.

```
Client  ──VLESS+Reality──►  VPS:443 (nginx SNI) ──► VPS:4443 (Xray)
Client  ──VLESS+XHTTP────►  VPS:443 (nginx SNI) ──► VPS:2053 (Xray)
Client  ──subscription───►  VPS:443 (nginx SNI) ──► VPS:8443 (nginx HTTPS) ──► Raven:8080
```

### Dual-server with transparent RU bridge (recommended for CIS users)

EU VPS runs Xray + nginx_frontend + Raven-subscribe.
RU VPS runs an SNI relay + xray_bridge. Clients use their **existing EU configs unchanged** — RU nginx routes each SNI to the bridge, which accepts connections using EU Reality keys and chains to EU via XHTTP.

```
Client (unchanged EU config)
       │ SNI: askubuntu.com / dl.google.com / addons.mozilla.org
       ▼
RU VPS :443 (nginx SNI routing)
  ├─ askubuntu.com     → xray-bridge :5444  (Reality transparent inbound, EU v1 keys)
  ├─ dl.google.com     → xray-bridge :5446  (Reality v2, EU v2 keys + mldsa65)
  ├─ addons.mozilla.org→ xray-bridge :5447  (XHTTP v2, EU v2 keys)
  └─ www.wikipedia.org → xray-bridge :5443  (bridge-specific inbound)
       │
       ▼ XHTTP packet-up, EU v2 Reality keys
EU VPS :443 (nginx SNI) → Xray XHTTP :2054 → Internet
```

Raven-subscribe on EU automatically syncs users to bridge inbounds via WireGuard+gRPC.

### Role map

| Role | VPS | Playbook | What it does |
|------|-----|----------|--------------|
| `srv_prepare` | EU | `role_xray.yml` | BBR, sysctl tuning, system user `xrayuser` |
| `xray` | EU | `role_xray.yml` | Xray binary + split config in `/etc/xray/config.d/` |
| `raven_subscribe` | EU | `role_raven_subscribe.yml` | Subscription server, gRPC sync with Xray and bridge |
| `nginx_frontend` | EU | `role_nginx_frontend.yml` | nginx SNI routing on :443, HTTPS proxy on :8443 |
| `monitoring` | EU+RU | `role_monitoring.yml` | xray-stats-exporter + VictoriaMetrics + Grafana |
| `wireguard` | EU+RU | `role_wireguard.yml` | WireGuard mesh — EU↔RU tunnel for monitoring and bridge sync |
| `sing-box-playbook` | EU | `role_sing-box.yml` | sing-box + Hysteria2 (optional) |
| `relay` | RU | `role_relay.yml` | nginx SNI relay on :443 — forwards or routes VPN traffic |
| `xray_bridge` | RU | `role_xray_bridge.yml` | Xray chain proxy — accepts client connections, chains to EU via XHTTP |

---

## Requirements

- **Ansible** >= 2.14 (`ansible-core`)
- **Target OS**: Debian 11+ / Ubuntu 20.04+ with systemd
- **Python 3** on the target server
- **ansible-vault** for secrets management
- **Docker** (optional, for local config validation tests)

> **Note:** The `nginx_frontend` and `relay` roles install `libnginx-mod-stream` automatically. If nginx is already installed without it, run `sudo apt install libnginx-mod-stream && sudo systemctl restart nginx`.

---

## Quick Start

### 1. Clone

```bash
git clone https://github.com/AlchemyLink/Raven-server-install.git
cd Raven-server-install
```

### 2. Create vault password file

```bash
echo "your-strong-vault-password" > vault_password.txt
chmod 600 vault_password.txt
```

### 3. Create inventory

Copy the example and fill in your server IPs:

```bash
cp roles/hosts.yml.example roles/hosts.yml
```

Edit `roles/hosts.yml`:

```yaml
all:
  children:
    cloud:
      hosts:
        vm_my_srv:
          ansible_host: "EU_VPS_IP"
          ansible_port: 22
        vm_my_ru2:                        # optional: RU VPS for relay + bridge
          ansible_host: "RU_VPS_IP"
          ansible_port: 22
          ansible_user: deploy
      vars:
        ansible_user: deploy
        ansible_python_interpreter: /usr/bin/python3
        ansible_ssh_private_key_file: ~/.ssh/id_ed25519
        ansible_ssh_host_key_checking: false
```

### 4. Create secrets files

Each role has a `defaults/secrets.yml.example`. Copy, fill in values, then encrypt:

```bash
# Xray (EU)
cp roles/xray/defaults/secrets.yml.example roles/xray/defaults/secrets.yml
# Edit: add Reality keys (xray x25519), short_id (openssl rand -hex 8), users (uuidgen)
ansible-vault encrypt roles/xray/defaults/secrets.yml --vault-password-file vault_password.txt

# Raven-subscribe (EU)
cp roles/raven_subscribe/defaults/secrets.yml.example roles/raven_subscribe/defaults/secrets.yml
# Edit: set admin_token (openssl rand -hex 32), server_host (EU VPS domain/IP),
#       and base_url (public subscription URL, e.g. https://my.yourdomain.com)
ansible-vault encrypt roles/raven_subscribe/defaults/secrets.yml --vault-password-file vault_password.txt

# nginx_frontend (EU)
cp roles/nginx_frontend/defaults/secrets.yml.example roles/nginx_frontend/defaults/secrets.yml
# Edit: set domain and certbot email
ansible-vault encrypt roles/nginx_frontend/defaults/secrets.yml --vault-password-file vault_password.txt

# relay (RU) — optional
cp roles/relay/defaults/secrets.yml.example roles/relay/defaults/secrets.yml
# Edit: set relay_upstream_host (EU IP) and certbot email
ansible-vault encrypt roles/relay/defaults/secrets.yml --vault-password-file vault_password.txt
```

To edit an encrypted file later:

```bash
ansible-vault edit roles/xray/defaults/secrets.yml --vault-password-file vault_password.txt
```

### 5. Deploy

Deploy strictly in this order — each step depends on the previous one:

| # | Role | Why this order |
|---|------|----------------|
| 1 | `role_xray` | Creates `/etc/xray/config.d/`, the `xrayuser` system user, starts Xray with gRPC API on `:10085` |
| 2 | `role_raven_subscribe` | Reads configs from `/etc/xray/config.d/` and calls gRPC API — won't start without step 1 |
| 3 | `role_nginx_frontend` | Proxies traffic to Xray and Raven-subscribe — nothing to forward without steps 1–2 |
| 4 | `role_xray_bridge` | (RU) Chain proxy — requires EU Reality keys from step 1 |
| 5 | `role_relay` | (RU) nginx relay — routes to EU; if transparent bridge is enabled, xray_bridge from step 4 must already be listening |

```bash
VP=vault_password.txt

# 1. EU — Xray + system preparation (FIRST — creates xrayuser and config.d)
ansible-playbook roles/role_xray.yml -i roles/hosts.yml --vault-password-file $VP

# 2. EU — Raven-subscribe (requires Xray from step 1)
ansible-playbook roles/role_raven_subscribe.yml -i roles/hosts.yml --vault-password-file $VP

# 3. EU — nginx TLS frontend + SNI stream routing
ansible-playbook roles/role_nginx_frontend.yml -i roles/hosts.yml --vault-password-file $VP

# 4. RU — xray_bridge (deploy BEFORE relay)
ansible-playbook roles/role_xray_bridge.yml -i roles/hosts.yml --vault-password-file $VP

# 5. RU — nginx relay
ansible-playbook roles/role_relay.yml -i roles/hosts.yml --vault-password-file $VP
```

Use `--tags` to deploy only a specific part:

```bash
ansible-playbook roles/role_xray.yml -i roles/hosts.yml --vault-password-file $VP \
  --tags xray_inbounds
```

---

## Role Reference

### `xray` role

Installs and configures Xray-core. Config is split across numbered JSON files in `/etc/xray/config.d/` — Xray loads them in order.

**Task tags:**

| Tag | What it does |
|-----|--------------|
| `xray_install` | Downloads Xray binary from GitHub releases |
| `xray_base` | Writes `000-log.json`, `010-stats.json` |
| `xray_api` | Writes `050-api.json` (gRPC API on 127.0.0.1:10085) |
| `xray_inbounds` | Writes VLESS Reality + XHTTP inbound configs |
| `xray_dns` | Writes `100-dns.json` |
| `xray_outbounds` | Writes `300-outbounds.json` (Finalmask fragment anti-DPI) |
| `xray_routing` | Writes `400-routing.json` |
| `xray_service` | Deploys systemd unit, enables service |

**Config files layout:**

| File | Content |
|------|---------|
| `000-log.json` | Log levels, file paths |
| `010-stats.json` | Traffic statistics |
| `050-api.json` | gRPC API (127.0.0.1:10085) |
| `100-dns.json` | DNS servers |
| `200-in-vless-reality.json` | VLESS + Reality inbound (port 4443) |
| `201-in-vless-reality-v2.json` | V2 VLESS + Reality inbound (port 4444, isolated keys) |
| `210-in-xhttp.json` | VLESS + XHTTP inbound (port 2053) |
| `211-in-xhttp-v2.json` | V2 VLESS + XHTTP inbound (port 2054) |
| `300-outbounds.json` | Freedom (with Finalmask fragment) + blackhole |
| `400-routing.json` | Routing rules + ad blocking |

**Handler safety:** `Validate xray` runs before `Restart xray` — invalid config never triggers a restart.

---

### `raven_subscribe` role

Deploys [Raven-subscribe](https://github.com/AlchemyLink/Raven-subscribe) — a Go service that auto-discovers Xray users, syncs them via gRPC API, and serves personal subscription URLs.

- Listens on `127.0.0.1:8080`, proxied by nginx_frontend
- Automatically syncs users to the RU bridge via `bridge_transparent_tags` (requires WireGuard tunnel)
- Watches `/etc/xray/config.d/` via fsnotify — picks up changes within seconds

---

### `nginx_frontend` role

Deploys nginx on the EU VPS as a TLS frontend and SNI router. Port 443 handles all traffic.

- **Stream SNI routing on :443** — routes by SNI:
  - `www.adobe.com` → Xray XHTTP `:2053`
  - `addons.mozilla.org` → Xray XHTTP v2 `:2054`
  - `askubuntu.com` → Xray Reality `:4443`
  - `dl.google.com` → Xray Reality v2 `:4444`
  - `your-domain.com` → nginx HTTPS `:8443` (Raven-subscribe)
- **HTTPS on :8443** — proxies `/sub/`, `/c/`, `/api/` → Raven-subscribe `:8080`

**Important:** Deploy **Xray first**, then nginx. nginx sends PROXY protocol headers immediately — Xray must be ready.

---

### `relay` role

Deploys nginx on the RU VPS as an SNI relay.

- **Stream SNI routing on :443** — routes EU VPN SNIs to xray_bridge transparent inbounds (when `relay_transparent_enabled: true`), everything else → EU VPS directly
- Serves a static stub site on `relay_domain` (camouflage)
- Proxies `my.relay_domain` → EU Raven-subscribe

**Deploy order:** Always deploy `xray_bridge` before `relay`. The relay role checks that bridge ports 5444–5447 are listening before rendering the stream config.

**Emergency rollback:** Set `relay_transparent_enabled: false` in relay secrets and redeploy with `--tags relay_stream`. All traffic goes directly to EU, bypassing the bridge.

---

### `xray_bridge` role

Deploys Xray chain proxy on the RU VPS. Accepts client connections using EU Reality keys (transparent — clients use their existing configs unchanged), then forwards traffic to EU via XHTTP.

- Transparent inbounds on ports 5444–5447 (one per EU inbound)
- Outbound: VLESS → EU XHTTP v2 (addons.mozilla.org SNI, mlkem768x25519plus)
- Split routing: `.ru`/`.su`/`.рф` and Russian services → direct, everything else → EU chain
- Stats API on `bridge_api_address:10086` (accessible via WireGuard from EU for Raven sync)

---

### `wireguard` role

Creates a WireGuard mesh between EU and RU VPS. Required for:
- Raven-subscribe → bridge gRPC sync (EU pushes users to RU bridge via WireGuard)
- Monitoring (vmagent on EU pushes metrics to VictoriaMetrics on RU)

---

### `monitoring` role

Deploys the full monitoring stack:

- **[xray-stats-exporter](https://github.com/AlchemyLink/xray-stats-exporter)** on EU — per-user and per-inbound traffic metrics
- **VictoriaMetrics** on RU — time series database
- **Grafana** on RU — dashboards for traffic, server health, Raven-subscribe status, alerting

```bash
ansible-playbook roles/role_monitoring.yml -i roles/hosts.yml --vault-password-file vault_password.txt
```

---

## Secrets

Each role keeps secrets in `defaults/secrets.yml` (ansible-vault encrypted, gitignored). Copy from `.example`.

### `roles/xray/defaults/secrets.yml`

```yaml
xray_reality:
  private_key: "YOUR_PRIVATE_KEY"    # xray x25519
  public_key: "YOUR_PUBLIC_KEY"
  spiderX: "/"
  short_id:
    - "a1b2c3d4e5f67890"             # openssl rand -hex 8

xray_users:
  - id: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # uuidgen
    flow: "xtls-rprx-vision"
    email: "alice@example.com"
```

### `roles/raven_subscribe/defaults/secrets.yml`

```yaml
raven_subscribe_admin_token: "YOUR_ADMIN_TOKEN"     # openssl rand -hex 32
raven_subscribe_base_url: "https://my.yourdomain.com"  # relay domain, not direct EU IP
raven_subscribe_server_host: "yourdomain.com"       # EU VPS domain or IP

# Per-inbound host overrides (optional).
# Falls back to raven_subscribe_server_host when tag is not listed.
# raven_subscribe_inbound_hosts:
#   vless-reality-in: "askubuntu.com"
#   vless-xhttp-in: "www.adobe.com"

# Per-inbound port overrides (optional).
# With SNI routing all protocols share port 443.
# raven_subscribe_inbound_ports:
#   vless-reality-in: 443
#   vless-xhttp-in: 443
#   vless-reality-v2-in: 443
#   vless-xhttp-v2-in: 443

# VLESS Encryption per-inbound key override (optional).
# Only needed when v1 and v2 inbounds use different encryption keys.
# If omitted, xray_vless_client_encryption from xray secrets is applied to all inbounds.
# raven_subscribe_vless_client_encryption:
#   vless-reality-in: "mlkem768x25519plus.PublicKeyV1..."
#   vless-reality-v2-in: "mlkem768x25519plus.PublicKeyV2..."
```

### `roles/nginx_frontend/defaults/secrets.yml`

```yaml
nginx_frontend_domain: "your-domain.com"
nginx_frontend_certbot_email: "admin@example.com"
```

### `roles/relay/defaults/secrets.yml`

```yaml
relay_upstream_host: "EU_VPS_IP"
relay_certbot_email: "admin@example.com"
relay_domain: "example.com"
relay_sub_my: "my.example.com"
```

### `roles/xray_bridge/defaults/secrets.yml`

```yaml
xray_bridge_reality:
  private_key: "BRIDGE_PRIVATE_KEY"   # xray x25519 (separate from EU keys)
  public_key: "BRIDGE_PUBLIC_KEY"
  spiderX: "/"
  short_id:
    - "b1c2d3e4f5a67890"

xray_bridge_users:                    # same UUIDs as EU xray_users
  - id: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    flow: "xtls-rprx-vision"
    email: "alice@example.com"

xray_bridge_eu_host: "EU_VPS_IP"
xray_bridge_eu_reality_public_key: "EU_V2_PUBLIC_KEY"
xray_bridge_eu_reality_short_id: "EU_V2_SHORT_ID"
xray_bridge_eu_user_id: "BRIDGE_USER_UUID"   # dedicated UUID registered on EU XHTTP inbound

xray_bridge_transparent_enabled: true
xray_bridge_api_address: "10.10.0.2"         # WireGuard IP of RU VPS
```

---

## Configuration

### Xray (`roles/xray/defaults/main.yml`)

| Variable | Default | Description |
|----------|---------|-------------|
| `xray_reality_dest` | `askubuntu.com:443` | Reality camouflage destination |
| `xray_reality_server_names` | `["askubuntu.com"]` | SNI names for Reality |
| `xray_xhttp.port` | `2053` | XHTTP inbound port |
| `xray_v2_inbounds_enabled` | `true` | Enable v2 parallel inbounds (ports 4444/2054) |
| `xray_dns_servers` | `tcp+local://8.8.8.8, ...` | DNS — do not use DoH (`https://`) |
| `xray_dns_query_strategy` | `UseIPv4` | Use `UseIP` if server has IPv6 |
| `xray_vless_decryption` | `"none"` | VLESS Encryption — see [VLESS Encryption](#vless-encryption-optional) |

### Raven-subscribe (`roles/raven_subscribe/defaults/main.yml`)

| Variable | Default | Description |
|----------|---------|-------------|
| `raven_subscribe_sync_interval_seconds` | `60` | Xray config rescan interval |
| `raven_subscribe_xray_api_addr` | `127.0.0.1:10085` | Xray gRPC API address |
| `raven_subscribe_bridge_api_addr` | `""` | Bridge gRPC API (set to WireGuard IP:10086) |
| `raven_subscribe_bridge_transparent_tags` | `{}` | Maps EU inbound tag → bridge transparent tag |

### relay (`roles/relay/defaults/main.yml`)

| Variable | Default | Description |
|----------|---------|-------------|
| `relay_transparent_enabled` | `false` | Route EU SNIs to xray_bridge transparent inbounds |
| `relay_bridge_enabled` | `false` | Enable bridge-specific SNI routing (www.wikipedia.org → :5443) |
| `relay_bridge_sni` | `""` | SNI that routes to xray_bridge main inbound |

---

## Examples

### Generate Reality keys

```bash
# Generate x25519 key pair for Reality
xray x25519
# PrivateKey: <base64-encoded-private-key>
# PublicKey:  <base64-encoded-public-key>

# Generate short_id (8 bytes hex)
openssl rand -hex 8
# a1b2c3d4e5f67890

# Generate user UUID
uuidgen
# f47ac10b-58cc-4372-a567-0e02b2c3d479
```

### Update inbounds only (no restart if config is unchanged)

```bash
ansible-playbook roles/role_xray.yml -i roles/hosts.yml \
  --vault-password-file vault_password.txt \
  --tags xray_inbounds
# Renders new inbound configs, validates, restarts only if changed
```

### Add a new user

Edit the secrets file:

```bash
ansible-vault edit roles/xray/defaults/secrets.yml --vault-password-file vault_password.txt
```

Add to `xray_users`:

```yaml
xray_users:
  - id: "existing-user-uuid"
    flow: "xtls-rprx-vision"
    email: "alice@example.com"
  - id: "f47ac10b-58cc-4372-a567-0e02b2c3d479"   # new user
    flow: "xtls-rprx-vision"
    email: "bob@example.com"
```

Redeploy inbounds:

```bash
ansible-playbook roles/role_xray.yml -i roles/hosts.yml \
  --vault-password-file vault_password.txt \
  --tags xray_inbounds
```

Raven-subscribe picks up the new user via fsnotify within `sync_interval_seconds` and generates a personal subscription URL automatically.

### Check service status on remote server

```bash
# Check Xray is running
ansible vm_my_srv -i roles/hosts.yml -m command -a "systemctl status xray" \
  --vault-password-file vault_password.txt

# Check Raven-subscribe
ansible vm_my_srv -i roles/hosts.yml -m command -a "systemctl status xray-subscription"

# View recent Xray logs
ansible vm_my_srv -i roles/hosts.yml -m command \
  -a "journalctl -u xray -n 50 --no-pager"
```

### Emergency rollback: disable RU bridge

If the bridge is broken and VPN is down for all clients:

```bash
# 1. Edit relay secrets — disable transparent routing
ansible-vault edit roles/relay/defaults/secrets.yml --vault-password-file vault_password.txt
# Set: relay_transparent_enabled: false

# 2. Redeploy only the stream config (fast, ~30 seconds)
ansible-playbook roles/role_relay.yml -i roles/hosts.yml \
  --vault-password-file vault_password.txt \
  --tags relay_stream
# All traffic now routes directly to EU VPS
```

### Run config validation tests locally

```bash
# Full test: render templates + validate with xray -test in Docker
./tests/run.sh

# Ansible-only (no Docker required)
SKIP_XRAY_TEST=1 ./tests/run.sh
```

---

## DNS Setup

| Domain | → | Server | Purpose |
|--------|---|--------|---------|
| `your-domain.com` | → | EU VPS IP | nginx_frontend TLS cert |
| `my.your-domain.com` | → | EU VPS IP | Raven-subscribe subscription links (single-server) |
| `example.com` | → | RU VPS IP | Relay stub site (camouflage) |
| `my.example.com` | → | RU VPS IP | Relay → Raven-subscribe |

Clients connect to the RU VPS on port 443 — no extra DNS records needed for VPN traffic.

---

## VLESS Encryption (optional)

Post-quantum VLESS Encryption (mlkem768x25519plus, Xray-core ≥ 25.x). Disabled by default.

All clients on the inbound **must** support it — do not mix encrypted and plain clients.

```bash
xray vlessenc
# Output: decryption string (server) + encryption string (client)
```

Add to `roles/xray/defaults/secrets.yml`:

```yaml
xray_vless_decryption: "mlkem768x25519plus.PRIVATE..."
xray_vless_client_encryption: "mlkem768x25519plus.PUBLIC..."
```

Both must be set together or both `"none"`. When enabled, `flow` is forced to `xtls-rprx-vision`.

---

## Hysteria2 / sing-box (optional)

```bash
cp roles/sing-box-playbook/defaults/secrets.yml.example roles/sing-box-playbook/defaults/secrets.yml
ansible-vault encrypt roles/sing-box-playbook/defaults/secrets.yml --vault-password-file vault_password.txt
ansible-playbook roles/role_sing-box.yml -i roles/hosts.yml --vault-password-file vault_password.txt
```

Then set `raven_subscribe_singbox_enabled: true` and redeploy Raven-subscribe.

---

## Testing

```bash
./tests/run.sh              # full: render templates + xray -test in Docker
SKIP_XRAY_TEST=1 ./tests/run.sh  # Ansible-only, no Docker
```

CI runs on every push and PR. See [tests/README.md](tests/README.md) for details.

---

## Troubleshooting

### `unknown directive "stream"` — nginx fails to start

The `stream` module is not installed. Fix:

```bash
sudo apt install libnginx-mod-stream
sudo systemctl start nginx
```

The playbooks install `libnginx-mod-stream` automatically on fresh deploys.

### `unknown directive "http2"` — nginx fails to start

Your nginx version is < 1.25.1 (common on Debian 11 / Ubuntu 20.04 stock packages). The playbooks auto-detect the version and use the correct syntax. If you see this error on an older install, redeploy with:

```bash
ansible-playbook roles/role_nginx_frontend.yml -i roles/hosts.yml \
  --vault-password-file vault_password.txt --tags nginx_frontend_ssl
```

### `chgrp failed: failed to look up group xrayuser` — raven_subscribe deploy fails

Update the repository — current version of `raven_subscribe` creates the `xrayuser` group and user automatically:

```bash
git pull
ansible-playbook roles/role_raven_subscribe.yml -i roles/hosts.yml --vault-password-file vault_password.txt
```

If updating is not possible, deploy Xray first — it creates `xrayuser` via `srv_prepare`:

```bash
ansible-playbook roles/role_xray.yml -i roles/hosts.yml --vault-password-file vault_password.txt
```

### `raven_subscribe_admin_token must be set` — validation fails

You haven't created `secrets.yml` for raven_subscribe yet:

```bash
cp roles/raven_subscribe/defaults/secrets.yml.example roles/raven_subscribe/defaults/secrets.yml
# Fill in admin_token (openssl rand -hex 32) and server_host
ansible-vault encrypt roles/raven_subscribe/defaults/secrets.yml --vault-password-file vault_password.txt
```

### `no hosts matched` — playbook skips all hosts

Check that your `roles/hosts.yml` defines `vm_my_srv` (for EU roles) and `vm_my_ru2` (for RU roles). The playbooks target these specific host names.

### nginx reload fails after config deploy

A previous failed deploy left a broken config file. Remove it and restart:

```bash
sudo rm /etc/nginx/conf.d/<your-domain>.conf
sudo systemctl start nginx
# Then redeploy:
ansible-playbook roles/role_nginx_frontend.yml -i roles/hosts.yml \
  --vault-password-file vault_password.txt --tags nginx_frontend_ssl
```

---

## Contributing

This project is in **alpha testing**. Contributions and bug reports are very welcome.

1. Fork the repository and create a feature branch
2. Test your changes with `./tests/run.sh` before submitting
3. Open a pull request with a clear description of what changed and why

**Reporting issues:** Please include your Ansible version, target OS version, and the full error output.

---

## Related Projects

- [Raven-subscribe](https://github.com/AlchemyLink/Raven-subscribe) — subscription server (Go)
- [xray-stats-exporter](https://github.com/AlchemyLink/xray-stats-exporter) — Prometheus exporter for Xray traffic metrics
- [Xray-core](https://github.com/XTLS/Xray-core) — the VPN core
- [sing-box](https://github.com/SagerNet/sing-box) — alternative VPN core (Hysteria2)

---

## License

[Mozilla Public License 2.0](LICENSE)
