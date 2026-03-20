# Ansible Role: xray

Installs and configures [Xray-core](https://github.com/XTLS/Xray-core) with VLESS+REALITY and VLESS+XHTTP inbounds.

## Requirements

- Ansible >= 2.14
- Target: Debian/Ubuntu, RHEL/Fedora, or Alpine Linux
- `ansible.posix` and `community.general` collections

## Role Variables

All defaults are in `defaults/main.yml`. Secrets must be provided via an encrypted `defaults/secrets.yml` (ansible-vault):

```yaml
xray_reality:
  private_key: "..."
  public_key:  "..."
  spiderX:     "..."
  short_id:
    - "abc123ef"

xray_users:
  - id: "UUID"
    flow: "xtls-rprx-vision"
    email: "user@example.com"
```

Generate keys:
```bash
xray x25519                   # private_key / public_key
openssl rand -hex 8           # short_id
```

## Key variables

| Variable | Default | Description |
|---|---|---|
| `xray_vless_port` | `443` | VLESS+REALITY port |
| `xray_xhttp.port` | `2053` | VLESS+XHTTP port |
| `xray_reality_dest` | `askubuntu.com:443` | REALITY handshake destination |
| `xray_reality_server_names` | `[askubuntu.com]` | SNI server names |
| `xray_api.inbound.port` | `10085` | Xray gRPC API port (localhost only) |

## Playbook

```bash
ansible-playbook roles/role_xray.yml -i <inventory> --ask-vault-pass
```

Run only specific steps with tags: `xray_install`, `xray_base`, `xray_api`, `xray_inbounds`, `xray_routing`, `xray_service`, `xray_dns`, `xray_outbounds`, `grpcurl`.

## Config layout on target host

```
/etc/xray/config.d/
  000-log.json
  010-stats.json
  050-api.json
  100-dns.json
  200-in-vless-reality.json
  210-in-xhttp.json
  300-outbounds.json
  400-routing.json
```
