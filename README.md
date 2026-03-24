# Raven Server Install

Ansible role that installs and configures [Xray-core](https://github.com/XTLS/Xray-core) with [Raven-subscribe](https://github.com/alchemylink/raven-subscribe) on a VPS.

**What you get:**
- Xray with VLESS + XTLS-Reality and XHTTP inbounds
- Optional VLESS Encryption (post-quantum, mlkem768x25519plus)
- Raven-subscribe — subscription server for client config distribution
- nginx TLS frontend on EU server (`nginx_frontend` role)
- nginx relay on RU server with TCP stream proxy for VLESS Reality (`relay` role)
- Systemd services with auto-restart and config validation before reload
- Ad/tracker blocking via geosite routing rules
- BBR congestion control and kernel tuning via `srv_prepare` role

## Requirements

- Ansible >= 2.14 (ansible-core)
- Target: Debian/Ubuntu VPS with systemd
- `ansible-vault` for secrets management

## Quick Start

### 1. Inventory

Edit `roles/hosts.yml` and point `vm_my_srv` at your server.

### 2. Secrets

Create and encrypt secrets files for each role you deploy:

```bash
# Xray role (Reality keys, users)
cp roles/xray/defaults/secrets.yml.example roles/xray/defaults/secrets.yml
ansible-vault encrypt roles/xray/defaults/secrets.yml --vault-password-file vault_password.txt

# Raven-subscribe role (admin token, server host, per-inbound overrides)
cp roles/raven_subscribe/defaults/secrets.yml.example roles/raven_subscribe/defaults/secrets.yml
ansible-vault encrypt roles/raven_subscribe/defaults/secrets.yml --vault-password-file vault_password.txt

# nginx_frontend role (certbot email) — EU server
cp roles/nginx_frontend/defaults/secrets.yml.example roles/nginx_frontend/defaults/secrets.yml
ansible-vault encrypt roles/nginx_frontend/defaults/secrets.yml --vault-password-file vault_password.txt

# relay role (upstream EU IP, certbot email) — RU server
cp roles/relay/defaults/secrets.yml.example roles/relay/defaults/secrets.yml
ansible-vault encrypt roles/relay/defaults/secrets.yml --vault-password-file vault_password.txt
```

To edit later:

```bash
ansible-vault edit roles/xray/defaults/secrets.yml --vault-password-file vault_password.txt
```

### 3. Generate Reality keys

```bash
# On any machine with Xray installed:
xray x25519
# Output: PrivateKey + PublicKey — put both into secrets.yml
```

### 4. Deploy

```bash
# EU server: Xray
ansible-playbook roles/role_xray.yml -i roles/hosts.yml --vault-password-file vault_password.txt

# EU server: nginx TLS frontend
ansible-playbook roles/role_nginx_frontend.yml -i roles/nginx_frontend/inventory.ini --vault-password-file vault_password.txt

# EU server: Raven-subscribe
ansible-playbook roles/role_raven_subscribe.yml -i roles/hosts.yml --vault-password-file vault_password.txt

# RU server: nginx relay
ansible-playbook roles/role_relay.yml -i roles/relay/inventory.ini --vault-password-file vault_password.txt
```

Deploy only a specific component using tags:

```bash
# Update inbound configs only
ansible-playbook roles/role_xray.yml -i roles/hosts.yml --vault-password-file vault_password.txt --tags xray_inbounds
```

## Secrets

Each role has its own `defaults/secrets.yml` (ansible-vault encrypted).

**`roles/xray/defaults/secrets.yml`** — Reality keys and VLESS users:

```yaml
# Reality keys — generate with: xray x25519
xray_reality:
  private_key: "..."
  public_key: "..."
  spiderX: "/"
  short_id:
    - "a1b2c3d4e5f67890"   # 8-byte hex — generate: openssl rand -hex 8

# VLESS users
xray_users:
  - id: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"   # UUID — generate: uuidgen
    flow: "xtls-rprx-vision"
    email: "user@example.com"
```

**`roles/raven_subscribe/defaults/secrets.yml`** — Raven-subscribe settings:

```yaml
raven_subscribe_admin_token: ""             # openssl rand -hex 32
raven_subscribe_server_host: "media.zirgate.com"
raven_subscribe_base_url: "https://media.zirgate.com"

# Per-inbound host/port overrides (optional)
# Useful when clients should connect through a relay instead of the EU server directly
raven_subscribe_inbound_hosts:
  vless-reality-in: "media.zirgate.com"
  vless-xhttp-in: "media.zirgate.com"
raven_subscribe_inbound_ports:
  vless-reality-in: 8445   # nginx stream relay port on EU server
```

**`roles/relay/defaults/secrets.yml`** — RU server relay:

```yaml
relay_upstream_host: "1.2.3.4"   # EU server IP
relay_certbot_email: "admin@example.com"
```

## Configuration

Key variables in `roles/xray/defaults/main.yml`:

| Variable | Default | Description |
|----------|---------|-------------|
| `xray_vless_port` | `443` | VLESS + Reality listen port |
| `xray_reality_dest` | `askubuntu.com:443` | Reality camouflage destination |
| `xray_reality_server_names` | `["askubuntu.com"]` | SNI names for Reality |
| `xray_xhttp.port` | `2053` | XHTTP inbound port |
| `xray_dns_servers` | `tcp+local://8.8.8.8, ...` | DNS servers (no DoH — see note below) |
| `xray_dns_query_strategy` | `UseIPv4` | DNS query strategy — use `UseIPv4` if the server has no IPv6 |
| `xray_vless_decryption` | `"none"` | VLESS Encryption (optional, see below) |

Key variables in `roles/raven_subscribe/defaults/main.yml`:

| Variable | Default | Description |
|----------|---------|-------------|
| `raven_subscribe_listen_addr` | `:8080` | Raven-subscribe listen address |
| `raven_subscribe_sync_interval_seconds` | `60` | User sync interval |
| `raven_subscribe_inbound_hosts` | `{}` | Per-inbound host overrides (set in secrets.yml) |
| `raven_subscribe_inbound_ports` | `{}` | Per-inbound port overrides (set in secrets.yml) |

> **DNS note:** Do not use `https://` (DoH) in `xray_dns_servers` — DoH queries route through the proxy and fail. Use `tcp+local://` instead.

## Architecture

```
EU server
  role_xray.yml
    └── srv_prepare   — system packages, BBR, sysctl tuning
    └── xray          — Xray binary + config
          ├── validate.yml       (always)         — pre-flight assertions
          ├── install.yml        (xray_install)   — download Xray binary
          ├── base.yml           (xray_base)      — log + stats config
          ├── api.yml            (xray_api)       — gRPC API on 127.0.0.1:10085
          ├── inbounds.yml       (xray_inbounds)  — VLESS+Reality, XHTTP
          ├── dns.yml            (xray_dns)       — DNS config
          ├── outbounds.yml      (xray_outbounds) — direct + block outbounds
          ├── routing.yml        (xray_routing)   — routing rules + ad blocking
          ├── service.yml        (xray_service)   — systemd unit
          └── grpcurl.yml        (grpcurl)        — installs grpcurl tool

  role_nginx_frontend.yml
    └── nginx_frontend — nginx TLS proxy on media.zirgate.com
          ├── listens on port 8443 (not 443, reserved by Xray Reality)
          ├── proxies /sub/* → Raven-subscribe :8080
          └── stream TCP relay: port 8445 → 127.0.0.1:443 (Xray Reality)

  role_raven_subscribe.yml
    └── raven_subscribe — subscription server
          ├── listens on 127.0.0.1:8080
          ├── syncs users to Xray via gRPC API
          └── serves client configs with per-inbound host/port overrides

RU server
  role_relay.yml
    └── relay — nginx reverse proxy on zirgate.com
          ├── my.zirgate.com → https://media.zirgate.com:8443 (Raven)
          └── stream TCP relay: port 8444 → media.zirgate.com:8445 (Reality)
```

Client connection flow:
```
VLESS Reality:  client → zirgate.com:8444 (RU TCP relay) → media.zirgate.com:8445 (EU nginx stream) → 127.0.0.1:443 (Xray)
VLESS XHTTP:    client → media.zirgate.com:443/path → nginx_frontend:8443 → Xray :2053
Subscription:   client → my.zirgate.com (RU relay) → media.zirgate.com:8443 → Raven-subscribe :8080
```

Xray config is split across `/etc/xray/config.d/` — files are loaded in numeric order:

| File | Content |
|------|---------|
| `000-log.json` | Logging |
| `010-stats.json` | Statistics |
| `050-api.json` | gRPC API |
| `100-dns.json` | DNS |
| `200-in-vless-reality.json` | VLESS + XTLS-Reality inbound |
| `210-in-xhttp.json` | VLESS + XHTTP inbound |
| `300-outbounds.json` | Outbounds |
| `400-routing.json` | Routing rules |

**Handler safety:** `Validate xray` runs before `Restart xray` — invalid config never causes a service restart.

## VLESS Encryption (optional)

Xray-core >= 25.x supports post-quantum VLESS Encryption (PR #5067, mlkem768x25519plus). Disabled by default (`"none"`).

To enable:

```bash
# Generate key pair on the server
xray vlessenc
# Output: decryption string (private, for server) + encryption string (public, for clients)
```

Then in `secrets.yml`:

```yaml
xray_vless_decryption: "mlkem768x25519plus...."    # server private string
xray_vless_client_encryption: "mlkem768x25519plus...." # client public string
```

Both must be set together or both left as `"none"`. When enabled, all users are forced to `flow: xtls-rprx-vision`.

## Testing

Run the full test suite (Ansible render + `xray -test` via Docker):

```bash
./tests/run.sh
```

Ansible-only (no Docker required):

```bash
SKIP_XRAY_TEST=1 ./tests/run.sh
```

The pipeline:
1. Downloads Xray binary (cached in `tests/.cache/`)
2. Generates test Reality keys
3. Runs `validate.yml` assertions
4. Renders all `templates/conf/*.j2` to `tests/.output/conf.d/`
5. Runs `xray -test -confdir` in Docker

CI runs automatically via `.github/workflows/xray-config-test.yml`.

## Related Projects

- [Raven-subscribe](https://github.com/alchemylink/raven-subscribe) — subscription server (Go) that syncs users via Xray gRPC API and serves client configs

## License

[Mozilla Public License 2.0](LICENSE)
