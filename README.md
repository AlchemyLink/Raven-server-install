# Raven Server Install

Languages: **English** | [Русский](README.ru.md)

[![CI](https://github.com/AlchemyLink/Raven-server-install/actions/workflows/xray-config-test.yml/badge.svg)](https://github.com/AlchemyLink/Raven-server-install/actions/workflows/xray-config-test.yml)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL_2.0-brightgreen.svg)](LICENSE)

Ansible playbooks for deploying a production-ready self-hosted VPN server stack based on [Xray-core](https://github.com/XTLS/Xray-core) and [Raven-subscribe](https://github.com/AlchemyLink/Raven-subscribe). Designed for censorship circumvention with traffic indistinguishable from regular HTTPS.

**What you get:**

- Xray-core with VLESS + XTLS-Reality (TCP) and VLESS + XHTTP (HTTP/2) inbounds
- nginx SNI routing on port 443 — all VPN traffic goes through standard HTTPS port
- Optional post-quantum VLESS Encryption (mlkem768x25519plus, Xray-core ≥ 26.x)
- Optional Hysteria2 via [sing-box](https://github.com/SagerNet/sing-box)
- [Raven-subscribe](https://github.com/AlchemyLink/Raven-subscribe) — subscription server: auto-discovers users, serves client configs via personal URLs
- [xray-stats-exporter](https://github.com/AlchemyLink/xray-stats-exporter) + VictoriaMetrics + Grafana — monitoring with per-user and per-inbound traffic dashboards
- nginx TLS frontend on EU VPS (`nginx_frontend` role) with PROXY protocol for real client IPs
- nginx SNI relay on RU VPS — hides EU server IP from clients (`relay` role)
- Systemd services with config validation before every reload
- Ad and tracker blocking via geosite routing rules (`geosite:category-ads-all`)
- BBR congestion control and sysctl tuning (`srv_prepare` role)

---

## Table of Contents

- [Architecture](#architecture)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Role Reference](#role-reference)
- [Secrets](#secrets)
- [Configuration](#configuration)
- [DNS Setup](#dns-setup)
- [VLESS Encryption (optional)](#vless-encryption-optional)
- [Hysteria2 / sing-box (optional)](#hysteria2--sing-box-optional)
- [Testing](#testing)
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

### Dual-server with RU relay (recommended for CIS users)

EU VPS runs Xray + nginx_frontend + Raven-subscribe.
RU VPS runs an SNI relay that hides the EU IP from clients and passes traffic through.

```
EU VPS                               RU VPS (example.com)
┌────────────────────────────────┐   ┌─────────────────────────────────────┐
│ nginx stream :443 (SNI routing)│   │ nginx stream :443 (SNI routing)     │
│   SNI dest.com  → Xray :4443   │◄──│   SNI dest.com  → EU:443            │
│   SNI adobe.com → Xray :2053   │◄──│   SNI adobe.com → EU:443            │
│   SNI my.domain → nginx :8443  │   │   SNI my.domain → local nginx :8443 │
│                                │   │     → EU:8443 → Raven :8080         │
│ Raven-subscribe :8080 (local)  │   └─────────────────────────────────────┘
└────────────────────────────────┘                   ▲
                                                  clients
```

**Client connection flow:**
```
VLESS Reality:  client → RU:443 (SNI relay) → EU:443 (nginx SNI) → Xray:4443
VLESS XHTTP:    client → RU:443 (SNI relay) → EU:443 (nginx SNI) → Xray:2053
Subscription:   client → my.example.com:443 → RU nginx → EU:8443 → Raven:8080
```

### Role map

| Role | VPS | Playbook | What it does |
|------|-----|----------|--------------|
| `srv_prepare` | EU | `role_xray.yml` | BBR, sysctl tuning, system user `xrayuser` |
| `xray` | EU | `role_xray.yml` | Xray binary + split config in `/etc/xray/config.d/` |
| `raven_subscribe` | EU | `role_raven_subscribe.yml` | Subscription server, gRPC sync with Xray |
| `nginx_frontend` | EU | `role_nginx_frontend.yml` | nginx SNI routing on :443, HTTPS proxy on :8443, PROXY protocol |
| `monitoring` | EU | `role_monitoring.yml` | xray-stats-exporter + VictoriaMetrics + Grafana |
| `sing-box-playbook` | EU | `role_sing-box.yml` | sing-box + Hysteria2 (optional) |
| `relay` | RU | `role_relay.yml` | nginx SNI relay on :443 — forwards all VPN traffic to EU |

---

## Requirements

- **Ansible** >= 2.14 (`ansible-core`)
- **Target OS**: Debian/Ubuntu with systemd
- **Python 3** on the target server
- **ansible-vault** for secrets management
- **Docker** (optional, for local config validation tests)

---

## Quick Start

### 1. Clone

```bash
git clone https://github.com/AlchemyLink/Raven-server-install.git
cd Raven-server-install
```

### 2. Create inventory

For the **xray** and **raven_subscribe** roles, edit `roles/hosts.yml.example` (copy to `roles/hosts.yml`):

```yaml
all:
  children:
    cloud:
      hosts:
        vm_my_srv:
          ansible_host: "EU_VPS_IP"
          ansible_port: 22
      vars:
        ansible_user: deploy
        ansible_python_interpreter: /usr/bin/python3
        ansible_ssh_private_key_file: ~/.ssh/id_ed25519
```

For **nginx_frontend** and **relay** roles, edit their respective `inventory.ini` files:

```ini
# roles/nginx_frontend/inventory.ini
[eu]
vpn ansible_host=EU_VPS_IP ansible_user=deploy

# roles/relay/inventory.ini
[relay]
relay ansible_host=RU_VPS_IP ansible_user=deploy
```

### 3. Create secrets files

Each role has a `defaults/secrets.yml.example`. Copy and fill in the values, then encrypt:

```bash
# Xray
cp roles/xray/defaults/secrets.yml.example roles/xray/defaults/secrets.yml
# edit roles/xray/defaults/secrets.yml
ansible-vault encrypt roles/xray/defaults/secrets.yml --vault-password-file vault_password.txt

# Raven-subscribe
cp roles/raven_subscribe/defaults/secrets.yml.example roles/raven_subscribe/defaults/secrets.yml
# edit roles/raven_subscribe/defaults/secrets.yml
ansible-vault encrypt roles/raven_subscribe/defaults/secrets.yml --vault-password-file vault_password.txt

# nginx_frontend (EU VPS)
cp roles/nginx_frontend/defaults/secrets.yml.example roles/nginx_frontend/defaults/secrets.yml
# edit roles/nginx_frontend/defaults/secrets.yml
ansible-vault encrypt roles/nginx_frontend/defaults/secrets.yml --vault-password-file vault_password.txt

# relay (RU VPS)
cp roles/relay/defaults/secrets.yml.example roles/relay/defaults/secrets.yml
# edit roles/relay/defaults/secrets.yml
ansible-vault encrypt roles/relay/defaults/secrets.yml --vault-password-file vault_password.txt
```

To edit an encrypted file later:

```bash
ansible-vault edit roles/xray/defaults/secrets.yml --vault-password-file vault_password.txt
```

### 4. Generate Reality keys

```bash
# On any machine with Xray installed:
xray x25519
# Output: PrivateKey + PublicKey — put both into roles/xray/defaults/secrets.yml

openssl rand -hex 8   # generates a short_id
```

### 5. Deploy

```bash
# EU server: Xray + system preparation
ansible-playbook roles/role_xray.yml -i roles/hosts.yml --vault-password-file vault_password.txt

# EU server: nginx TLS frontend + TCP stream relay
ansible-playbook roles/role_nginx_frontend.yml -i roles/nginx_frontend/inventory.ini --vault-password-file vault_password.txt

# EU server: Raven-subscribe
ansible-playbook roles/role_raven_subscribe.yml -i roles/hosts.yml --vault-password-file vault_password.txt

# RU server: nginx relay
ansible-playbook roles/role_relay.yml -i roles/relay/inventory.ini --vault-password-file vault_password.txt
```

Use `--tags` to deploy only a specific part:

```bash
ansible-playbook roles/role_xray.yml -i roles/hosts.yml --vault-password-file vault_password.txt \
  --tags xray_inbounds
```

---

## Role Reference

### `xray` role

Installs and configures Xray-core. Config is split across numbered JSON files in `/etc/xray/config.d/` — Xray loads them in order.

**Task files and tags:**

| Tag | File | What it does |
|-----|------|--------------|
| `always` | `validate.yml` | Pre-flight assertions — runs before everything |
| `xray_install` | `install.yml` | Downloads Xray binary from GitHub releases |
| `xray_base` | `base.yml` | Writes `000-log.json`, `010-stats.json` |
| `xray_api` | `api.yml` | Writes `050-api.json` (dokodemo-door on 127.0.0.1:10085) |
| `xray_inbounds` | `inbounds.yml` | Writes `200-in-vless-reality.json`, `210-in-xhttp.json` |
| `xray_dns` | `dns.yml` | Writes `100-dns.json` |
| `xray_outbounds` | `outbounds.yml` | Writes `300-outbounds.json` |
| `xray_routing` | `routing.yml` | Writes `400-routing.json` |
| `xray_service` | `service.yml` | Deploys systemd unit, enables service |
| `grpcurl` | `grpcurl.yml` | Installs grpcurl tool |

**Config files layout:**

| File | Content |
|------|---------|
| `000-log.json` | Log levels, file paths |
| `010-stats.json` | Traffic statistics |
| `050-api.json` | gRPC API (127.0.0.1:10085) |
| `100-dns.json` | DNS servers and query strategy |
| `200-in-vless-reality.json` | VLESS + XTLS-Reality inbound (TCP :443) |
| `210-in-xhttp.json` | VLESS + XHTTP inbound (:2053) |
| `300-outbounds.json` | Freedom + blackhole outbounds |
| `400-routing.json` | Routing rules + ad blocking |

**Handler safety:** `Validate xray` must be defined before `Restart xray` in `handlers/main.yml`. Ansible executes handlers in definition order — this ensures an invalid config never triggers a restart.

---

### `raven_subscribe` role

Deploys [Raven-subscribe](https://github.com/AlchemyLink/Raven-subscribe) — a Go service that auto-discovers Xray users, syncs them via gRPC API, and serves personal subscription URLs.

Listens on `127.0.0.1:8080`, proxied by nginx_frontend.

---

### `nginx_frontend` role

Deploys nginx on the EU VPS as a TLS frontend and SNI router. Port 443 handles all traffic.

- **Stream SNI routing on :443** — reads SNI from TLS ClientHello, routes by hostname:
  - SNI `xhttp-dest.com` → Xray XHTTP `:2053`
  - SNI `your-domain.com` → nginx HTTPS `:8443` (Raven-subscribe)
  - Default (any other SNI) → Xray VLESS Reality `:4443`
- **PROXY protocol** — passes real client IP to all upstreams (Xray uses `xver: 2`)
- **HTTPS on :8443** — proxies `/sub/`, `/c/`, `/api/` → Raven-subscribe `:8080`
- Obtains Let's Encrypt certificate for `nginx_frontend_domain`

**Important:** When deploying nginx_frontend and Xray inbounds together, always deploy **Xray first** (`--tags xray_inbounds`), then nginx. nginx sends PROXY protocol headers immediately — Xray must be ready to accept them.

---

### `relay` role

Deploys nginx on the RU VPS as an SNI relay. Responsibilities:

- **Stream SNI routing on :443** — forwards all VPN traffic to EU VPS:443 by default
- Serves a static stub site on `relay_domain` (camouflage, Let's Encrypt cert)
- Proxies `my.relay_domain` → EU VPS nginx_frontend `:8443` (Raven-subscribe)

---

### `monitoring` role

Deploys the full monitoring stack on the EU VPS:

- **[xray-stats-exporter](https://github.com/AlchemyLink/xray-stats-exporter)** — Prometheus exporter for per-user and per-inbound traffic metrics
- **VictoriaMetrics** — Prometheus-compatible time series database
- **Grafana** — dashboards for traffic, server health, Raven-subscribe status, and alerting rules

---

### `sing-box-playbook` role

Optional. Deploys [sing-box](https://github.com/SagerNet/sing-box) with a Hysteria2 inbound. When deployed, Raven-subscribe automatically discovers Hysteria2 users and includes them in subscriptions.

---

## Secrets

Each role keeps secrets in `defaults/secrets.yml` (ansible-vault encrypted, not committed). Copy from the `.example` file.

### `roles/xray/defaults/secrets.yml`

```yaml
# Reality keys — generate with: xray x25519
xray_reality:
  private_key: "YOUR_PRIVATE_KEY"
  public_key: "YOUR_PUBLIC_KEY"
  spiderX: "/"
  short_id:
    - "a1b2c3d4e5f67890"   # 8-byte hex — generate: openssl rand -hex 8

# VLESS users
xray_users:
  - id: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"   # UUID — generate: uuidgen
    flow: "xtls-rprx-vision"
    email: "alice@example.com"
```

### `roles/raven_subscribe/defaults/secrets.yml`

```yaml
# Admin token for Raven API — generate: openssl rand -hex 32
raven_subscribe_admin_token: "YOUR_ADMIN_TOKEN"

# Public URL used in subscription links
raven_subscribe_base_url: "https://my.example.com"

# EU VPS public domain or IP
raven_subscribe_server_host: "media.example.com"

# Per-inbound host/port overrides (optional)
# Routes different protocols through different addresses in client configs.
# Useful when clients connect via relay for some protocols.
raven_subscribe_inbound_hosts:
  vless-reality-in: "example.com"    # RU relay domain for Reality
  vless-xhttp-in: "media.example.com"
raven_subscribe_inbound_ports:
  vless-reality-in: 8444             # RU relay TCP port for Reality
```

### `roles/nginx_frontend/defaults/secrets.yml`

```yaml
nginx_frontend_certbot_email: "admin@example.com"
```

### `roles/relay/defaults/secrets.yml`

```yaml
relay_upstream_host: "EU_VPS_IP"       # EU server IP address
relay_certbot_email: "admin@example.com"
```

### `roles/sing-box-playbook/defaults/secrets.yml`

```yaml
singbox_hysteria2_users:
  - name: "alice@example.com"
    password: "STRONG_RANDOM_PASSWORD"

singbox:
  tls_server_name: "media.example.com"
  tls_acme_domain: "media.example.com"
  tls_acme_email: "admin@example.com"
```

---

## Configuration

### Xray (`roles/xray/defaults/main.yml`)

| Variable | Default | Description |
|----------|---------|-------------|
| `xray_vless_port` | `443` | VLESS + Reality listen port |
| `xray_reality_dest` | `askubuntu.com:443` | Reality camouflage destination (must be a real TLS site) |
| `xray_reality_server_names` | `["askubuntu.com"]` | SNI server names for Reality |
| `xray_xhttp.port` | `2053` | XHTTP inbound port |
| `xray_xhttp.xhttpSettings.path` | `/api/v3/data-sync` | XHTTP path (must match nginx_frontend) |
| `xray_dns_servers` | `tcp+local://8.8.8.8, ...` | DNS servers — do not use DoH (`https://`) |
| `xray_dns_query_strategy` | `UseIPv4` | `UseIPv4` if the server has no IPv6, `UseIP` otherwise |
| `xray_vless_decryption` | `"none"` | VLESS Encryption mode — see [VLESS Encryption](#vless-encryption-optional) |
| `xray_blocked_domains` | `[]` | Extra domains to block via routing rules |

### Raven-subscribe (`roles/raven_subscribe/defaults/main.yml`)

| Variable | Default | Description |
|----------|---------|-------------|
| `raven_subscribe_listen_addr` | `:8080` | Listen address |
| `raven_subscribe_sync_interval_seconds` | `60` | Xray config rescan interval |
| `raven_subscribe_api_inbound_tag` | `vless-reality-in` | Default inbound tag for API-created users |
| `raven_subscribe_xray_api_addr` | `127.0.0.1:10085` | Xray gRPC API address |
| `raven_subscribe_inbound_hosts` | `{}` | Per-inbound host overrides (set in secrets.yml) |
| `raven_subscribe_inbound_ports` | `{}` | Per-inbound port overrides (set in secrets.yml) |
| `raven_subscribe_singbox_enabled` | `false` | Enable sing-box/Hysteria2 sync |

### nginx_frontend (`roles/nginx_frontend/defaults/main.yml`)

| Variable | Default | Description |
|----------|---------|-------------|
| `nginx_frontend_domain` | `media.example.com` | EU VPS domain — used for TLS cert and SNI routing |
| `nginx_frontend_listen_port` | `8443` | nginx HTTPS internal port (proxied from :443 stream) |
| `nginx_frontend_raven_port` | `8080` | Raven-subscribe upstream port |
| `nginx_frontend_stream_xhttp_sni` | `www.adobe.com` | SNI that routes to Xray XHTTP inbound |
| `nginx_frontend_stream_xhttp_port` | `2053` | Xray XHTTP inbound port |
| `nginx_frontend_stream_reality_port` | `4443` | Xray VLESS Reality inbound port (default SNI target) |

### relay (`roles/relay/defaults/main.yml`)

| Variable | Default | Description |
|----------|---------|-------------|
| `relay_domain` | `example.com` | RU VPS domain — stub site + SNI routing |
| `relay_sub_my` | `my.example.com` | Subdomain proxied to EU Raven-subscribe |
| `relay_upstream_host` | `EU_VPS_IP` | EU server IP (set in secrets.yml) |
| `relay_upstream_raven_port` | `8443` | EU nginx HTTPS port for Raven-subscribe |
| `relay_stub_title` | `Welcome` | Stub site page title |
| `relay_stub_description` | `Personal website` | Stub site meta description |

---

## DNS Setup

Point the following DNS A records to the correct servers:

| Domain | → | Server | Purpose |
|--------|---|--------|---------|
| `media.example.com` | → | EU VPS IP | nginx_frontend (SNI routing, TLS cert) |
| `example.com` | → | RU VPS IP | Relay stub site (camouflage) |
| `my.example.com` | → | RU VPS IP | Relay → Raven-subscribe (subscription links) |

Clients connect to the RU VPS on port 443 for all protocols — no additional DNS records needed for VPN traffic.

---

## Monitoring (optional)

The `monitoring` role deploys a full observability stack on the EU VPS:

```bash
ansible-playbook roles/role_monitoring.yml -i roles/hosts.yml --vault-password-file vault_password.txt
```

**Grafana dashboards included:**
- **Xray — per-user traffic** — upload/download timeseries, top users, per-inbound breakdown (Reality vs XHTTP)
- **Servers EU/RU — status** — CPU, RAM, network, disk, Xray health, Raven-subscribe latency

**Alerting rules** (Grafana alerts via VictoriaMetrics):
- Xray down
- Raven-subscribe down
- EU/RU server unreachable
- Disk usage > 85%

To deploy only the binary for [xray-stats-exporter](https://github.com/AlchemyLink/xray-stats-exporter):

```bash
ansible-playbook roles/role_monitoring.yml -i roles/hosts.yml --vault-password-file vault_password.txt \
  --tags xray_stats_exporter \
  -e "xray_stats_exporter_local_binary=/path/to/xray-stats-exporter"
```

---

## VLESS Encryption (optional)

Xray-core >= 25.x supports post-quantum VLESS Encryption (mlkem768x25519plus). Disabled by default.

When enabled, all clients connecting to the inbound **must** support it — do not mix encrypted and plain clients on the same inbound.

**Generate keys:**

```bash
xray vlessenc
# Output: decryption string (server private) + encryption string (client public)
```

**Add to `roles/xray/defaults/secrets.yml`:**

```yaml
xray_vless_decryption: "mlkem768x25519plus.PRIVATE..."    # server — keep secret
xray_vless_client_encryption: "mlkem768x25519plus.PUBLIC..." # sent to clients via Raven
```

Both must be set together or both left as `"none"`. When enabled, `flow` is forced to `xtls-rprx-vision` for all users.

---

## Hysteria2 / sing-box (optional)

Deploy sing-box alongside Xray to provide Hysteria2 (QUIC-based protocol with Salamander obfuscation).

```bash
# Copy and fill in secrets
cp roles/sing-box-playbook/defaults/secrets.yml.example roles/sing-box-playbook/defaults/secrets.yml
ansible-vault encrypt roles/sing-box-playbook/defaults/secrets.yml --vault-password-file vault_password.txt

# Deploy
ansible-playbook roles/role_sing-box.yml -i roles/hosts.yml --vault-password-file vault_password.txt
```

After deployment, set `raven_subscribe_singbox_enabled: true` in `raven_subscribe/defaults/secrets.yml` and redeploy Raven-subscribe. It will discover Hysteria2 users and serve them via `/sub/{token}/singbox` and `/sub/{token}/hysteria2` endpoints.

**Note:** Hysteria2 uses ACME (Let's Encrypt) directly in sing-box. Set `singbox.tls_acme_domain` and `singbox.tls_acme_email` in secrets.

---

## Testing

Run the full test suite — renders all Ansible templates and validates them with `xray -test` in Docker:

```bash
./tests/run.sh
```

Ansible-only (no Docker needed):

```bash
SKIP_XRAY_TEST=1 ./tests/run.sh
```

**Pipeline steps:**
1. Downloads Xray binary (cached in `tests/.cache/`)
2. Generates ephemeral Reality keys → `tests/fixtures/test_secrets.yml`
3. Runs `validate.yml` assertions
4. Renders all `templates/conf/*.j2` → `tests/.output/conf.d/`
5. Runs `xray -test -confdir` in Docker

CI runs on every push and PR via `.github/workflows/xray-config-test.yml`.

**Run individual steps manually:**

```bash
export ANSIBLE_CONFIG="${PWD}/tests/ansible.cfg"
tests/scripts/gen-reality-keys.sh > tests/fixtures/test_secrets.yml
ansible-playbook tests/playbooks/validate_vars.yml
ansible-playbook tests/playbooks/render_conf.yml
```

---

## Related Projects

- [Raven-subscribe](https://github.com/AlchemyLink/Raven-subscribe) — subscription server (Go): auto-discovers users from Xray config, syncs via gRPC API, serves personal subscription URLs in Xray JSON / sing-box JSON / share link formats
- [xray-stats-exporter](https://github.com/AlchemyLink/xray-stats-exporter) — Prometheus exporter for per-user and per-inbound Xray traffic metrics
- [Xray-core](https://github.com/XTLS/Xray-core) — the VPN core
- [sing-box](https://github.com/SagerNet/sing-box) — alternative VPN core (Hysteria2)

---

## License

[Mozilla Public License 2.0](LICENSE)
