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
xray mldsa65                  # mldsa65_seed + mldsa65_verify (postquantum)
```

### Postquantum MLDSA65 + new VLESS encryption (optional)

MLDSA65 adds ML-DSA-65 post-quantum signatures to the REALITY handshake (Xray-core >= 25.x).
New VLESS encryption adds postquantum payload encryption on top of REALITY.

To enable both, add to `secrets.yml`:

```yaml
xray_reality:
  private_key: "..."
  public_key:  "..."
  spiderX:     "..."
  short_id:
    - "abc123ef"
  mldsa65_seed:   "..."    # Server secret — never share, encrypt with ansible-vault
  mldsa65_verify: "..."    # Public key   — give to clients alongside public_key

xray_vless_decryption: "mlkem768x25519plus.native.0rtt.100-111-1111-1111-1111-111"
```

**Client config** must include `mldsa65Verify` in `realitySettings` and matching `encryption` in VLESS user settings.

> Postquantum encryption requires ALL clients connecting to the inbound to support it.
> Do not mix legacy and postquantum clients on the same inbound.

## Key variables

| Variable | Default | Description |
|---|---|---|
| `xray_vless_port` | `443` | VLESS+REALITY port |
| `xray_xhttp.port` | `2053` | VLESS+XHTTP port |
| `xray_reality_dest` | `askubuntu.com:443` | REALITY handshake destination |
| `xray_reality_server_names` | `[askubuntu.com]` | SNI server names |
| `xray_api.inbound.port` | `10085` | Xray gRPC API port (localhost only) |
| `xray_vless_decryption` | `none` | VLESS payload decryption mode (`none` or postquantum cipher string) |
| `xray_reality.mldsa65_seed` | — | ML-DSA-65 server seed (secrets.yml only) |
| `xray_reality.mldsa65_verify` | — | ML-DSA-65 public verification key (share with clients) |

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
