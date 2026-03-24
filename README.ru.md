# Raven Server Install

Языки: [English](README.md) | **Русский**

[![CI](https://github.com/AlchemyLink/Raven-server-install/actions/workflows/xray-config-test.yml/badge.svg)](https://github.com/AlchemyLink/Raven-server-install/actions/workflows/xray-config-test.yml)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL_2.0-brightgreen.svg)](LICENSE)

Ansible-плейбуки для развёртывания самохостинг VPN-стека на основе [Xray-core](https://github.com/XTLS/Xray-core) и [Raven-subscribe](https://github.com/AlchemyLink/Raven-subscribe).

**Что вы получаете:**

- Xray-core с inbound'ами VLESS + XTLS-Reality и VLESS + XHTTP
- Опциональное пост-квантовое VLESS Encryption (mlkem768x25519plus)
- Опциональный Hysteria2 через [sing-box](https://github.com/SagerNet/sing-box)
- [Raven-subscribe](https://github.com/AlchemyLink/Raven-subscribe) — сервер подписок: автоматически находит пользователей, раздаёт клиентские конфиги по персональным ссылкам
- nginx TLS frontend на EU VPS (роль `nginx_frontend`)
- nginx relay + TCP stream proxy на RU VPS для маршрутизации через второй сервер (роль `relay`)
- systemd-сервисы с валидацией конфига перед каждым перезапуском
- Блокировка рекламы и публичных трекеров через правила маршрутизации geosite
- BBR и тюнинг sysctl (роль `srv_prepare`)

---

## Содержание

- [Архитектура](#архитектура)
- [Требования](#требования)
- [Быстрый старт](#быстрый-старт)
- [Описание ролей](#описание-ролей)
- [Секреты](#секреты)
- [Конфигурация](#конфигурация)
- [DNS-записи](#dns-записи)
- [VLESS Encryption (опционально)](#vless-encryption-опционально)
- [Hysteria2 / sing-box (опционально)](#hysteria2--sing-box-опционально)
- [Тестирование](#тестирование)
- [Связанные проекты](#связанные-проекты)
- [Лицензия](#лицензия)

---

## Архитектура

Поддерживаются две топологии деплоя.

### Один сервер (минимальный вариант)

Один VPS с Xray + Raven-subscribe + nginx.

```
Клиент  ──VLESS+Reality──►  VPS:443  (Xray)
Клиент  ──VLESS+XHTTP────►  VPS:443  (nginx) ──► VPS:2053 (Xray)
Клиент  ──подписка───────►  VPS:443  (nginx) ──► VPS:8080 (Raven)
```

### Два сервера с RU-relay (рекомендуется для пользователей из СНГ)

EU VPS: Xray + nginx_frontend + Raven-subscribe.
RU VPS: relay — скрывает EU IP от клиентов.

```
EU VPS (media.example.com)         RU VPS (example.com)
┌───────────────────────────┐      ┌─────────────────────────────┐
│ Xray        :443 TCP      │      │ nginx relay                 │
│ nginx XHTTP :443 HTTPS    │◄─────│   my.example.com → EU:8443  │
│ nginx stream:8445 TCP     │◄─────│   :8444 TCP → EU:8445 TCP   │
│ Raven       :8080 local   │      └─────────────────────────────┘
│ nginx front :8443 HTTPS   │                 ▲
└───────────────────────────┘                 │
                                           клиенты
```

**Маршруты подключения клиентов:**
```
VLESS Reality:  клиент → RU:8444 (TCP relay) → EU:8445 (nginx stream) → Xray:443
VLESS XHTTP:    клиент → EU:443 (nginx HTTPS) → Xray:2053
Подписка:       клиент → my.example.com (RU relay) → EU:8443 → Raven:8080
```

### Карта ролей

| Роль | VPS | Плейбук | Что делает |
|------|-----|---------|-----------|
| `srv_prepare` | EU | `role_xray.yml` | BBR, sysctl, системный пользователь |
| `xray` | EU | `role_xray.yml` | Бинарь Xray + split-конфиг в `/etc/xray/config.d/` |
| `raven_subscribe` | EU | `role_raven_subscribe.yml` | Сервер подписок, gRPC-синхронизация с Xray |
| `nginx_frontend` | EU | `role_nginx_frontend.yml` | nginx TLS proxy + TCP stream relay (порты 8443/8445) |
| `sing-box-playbook` | EU | `role_sing-box.yml` | sing-box + Hysteria2 (опционально) |
| `relay` | RU | `role_relay.yml` | nginx reverse proxy + TCP stream relay (порт 8444) |

---

## Требования

- **Ansible** >= 2.14 (`ansible-core`)
- **ОС на сервере**: Debian/Ubuntu с systemd
- **Python 3** на целевых серверах
- **ansible-vault** для управления секретами
- **Docker** (опционально, для локального тестирования конфигов)

---

## Быстрый старт

### 1. Клонировать репозиторий

```bash
git clone https://github.com/AlchemyLink/Raven-server-install.git
cd Raven-server-install
```

### 2. Создать inventory

Для ролей **xray** и **raven_subscribe** — отредактируйте `roles/hosts.yml.example` (скопируйте в `roles/hosts.yml`):

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

Для ролей **nginx_frontend** и **relay** — отредактируйте соответствующие файлы `inventory.ini`:

```ini
# roles/nginx_frontend/inventory.ini
[eu]
vpn ansible_host=EU_VPS_IP ansible_user=deploy

# roles/relay/inventory.ini
[relay]
relay ansible_host=RU_VPS_IP ansible_user=deploy
```

### 3. Создать файлы секретов

У каждой роли есть `defaults/secrets.yml.example`. Скопируйте, заполните и зашифруйте:

```bash
# Xray
cp roles/xray/defaults/secrets.yml.example roles/xray/defaults/secrets.yml
# заполнить roles/xray/defaults/secrets.yml
ansible-vault encrypt roles/xray/defaults/secrets.yml --vault-password-file vault_password.txt

# Raven-subscribe
cp roles/raven_subscribe/defaults/secrets.yml.example roles/raven_subscribe/defaults/secrets.yml
# заполнить roles/raven_subscribe/defaults/secrets.yml
ansible-vault encrypt roles/raven_subscribe/defaults/secrets.yml --vault-password-file vault_password.txt

# nginx_frontend (EU VPS)
cp roles/nginx_frontend/defaults/secrets.yml.example roles/nginx_frontend/defaults/secrets.yml
# заполнить roles/nginx_frontend/defaults/secrets.yml
ansible-vault encrypt roles/nginx_frontend/defaults/secrets.yml --vault-password-file vault_password.txt

# relay (RU VPS)
cp roles/relay/defaults/secrets.yml.example roles/relay/defaults/secrets.yml
# заполнить roles/relay/defaults/secrets.yml
ansible-vault encrypt roles/relay/defaults/secrets.yml --vault-password-file vault_password.txt
```

Редактировать зашифрованный файл:

```bash
ansible-vault edit roles/xray/defaults/secrets.yml --vault-password-file vault_password.txt
```

### 4. Сгенерировать ключи Reality

```bash
# На любой машине с установленным Xray:
xray x25519
# Вывод: PrivateKey + PublicKey — оба вносим в roles/xray/defaults/secrets.yml

openssl rand -hex 8   # short_id
```

### 5. Задеплоить

```bash
# EU сервер: Xray + системная подготовка
ansible-playbook roles/role_xray.yml -i roles/hosts.yml --vault-password-file vault_password.txt

# EU сервер: nginx TLS frontend + TCP stream relay
ansible-playbook roles/role_nginx_frontend.yml -i roles/nginx_frontend/inventory.ini --vault-password-file vault_password.txt

# EU сервер: Raven-subscribe
ansible-playbook roles/role_raven_subscribe.yml -i roles/hosts.yml --vault-password-file vault_password.txt

# RU сервер: nginx relay
ansible-playbook roles/role_relay.yml -i roles/relay/inventory.ini --vault-password-file vault_password.txt
```

Деплой только конкретной части через теги:

```bash
ansible-playbook roles/role_xray.yml -i roles/hosts.yml --vault-password-file vault_password.txt \
  --tags xray_inbounds
```

---

## Описание ролей

### Роль `xray`

Устанавливает и настраивает Xray-core. Конфиг разделён на пронумерованные JSON-файлы в `/etc/xray/config.d/` — Xray загружает их по порядку.

**Файлы тасков и теги:**

| Тег | Файл | Что делает |
|-----|------|-----------|
| `always` | `validate.yml` | Проверки переменных — всегда |
| `xray_install` | `install.yml` | Скачивает бинарь с GitHub |
| `xray_base` | `base.yml` | `000-log.json`, `010-stats.json` |
| `xray_api` | `api.yml` | `050-api.json` (dokodemo на 127.0.0.1:10085) |
| `xray_inbounds` | `inbounds.yml` | `200-in-vless-reality.json`, `210-in-xhttp.json` |
| `xray_dns` | `dns.yml` | `100-dns.json` |
| `xray_outbounds` | `outbounds.yml` | `300-outbounds.json` |
| `xray_routing` | `routing.yml` | `400-routing.json` |
| `xray_service` | `service.yml` | systemd unit, запуск сервиса |
| `grpcurl` | `grpcurl.yml` | Установка grpcurl |

**Файлы конфигурации:**

| Файл | Содержимое |
|------|-----------|
| `000-log.json` | Уровни логирования, пути файлов |
| `010-stats.json` | Статистика трафика |
| `050-api.json` | gRPC API (127.0.0.1:10085) |
| `100-dns.json` | DNS-серверы и стратегия запросов |
| `200-in-vless-reality.json` | VLESS + XTLS-Reality inbound (TCP :443) |
| `210-in-xhttp.json` | VLESS + XHTTP inbound (:2053) |
| `300-outbounds.json` | Freedom + blackhole outbound'ы |
| `400-routing.json` | Правила маршрутизации + блокировка рекламы |

**Безопасность handlers:** `Validate xray` должен быть определён раньше `Restart xray` в `handlers/main.yml`. Ansible выполняет handlers в порядке определения — это гарантирует, что невалидный конфиг никогда не вызовет перезапуск.

---

### Роль `raven_subscribe`

Деплоит [Raven-subscribe](https://github.com/AlchemyLink/Raven-subscribe) — Go-сервис, который автоматически находит пользователей Xray, синхронизирует их через gRPC API и раздаёт персональные ссылки подписки.

Слушает на `127.0.0.1:8080`, проксируется через nginx_frontend.

---

### Роль `nginx_frontend`

Деплоит nginx на EU VPS как TLS reverse proxy. Функции:

- Получает Let's Encrypt сертификат для `nginx_frontend_domain`
- Слушает на порту **8443** (порт 443 занят Xray VLESS Reality)
- Проксирует XHTTP path → Xray `:2053`
- Проксирует пути подписки/API → Raven-subscribe `:8080`
- **TCP stream relay**: порт 8445 → `127.0.0.1:443` (проброс VLESS Reality через nginx)

---

### Роль `relay`

Деплоит nginx на RU VPS как relay. Функции:

- Получает Let's Encrypt сертификаты для `relay_domain` и `relay_sub_my`
- Отдаёт статический stub-сайт на `relay_domain` (маскировка)
- Проксирует `my.relay_domain` → EU VPS nginx_frontend `:8443` (Raven-subscribe)
- **TCP stream relay**: порт 8444 → EU VPS `:8445` (проброс VLESS Reality)

---

### Роль `sing-box-playbook`

Опционально. Деплоит [sing-box](https://github.com/SagerNet/sing-box) с inbound'ом Hysteria2. После деплоя Raven-subscribe автоматически находит Hysteria2-пользователей и включает их в подписки.

---

## Секреты

У каждой роли секреты хранятся в `defaults/secrets.yml` (зашифровано ansible-vault, не коммитится). Шаблоны — в `defaults/secrets.yml.example`.

### `roles/xray/defaults/secrets.yml`

```yaml
# Ключи Reality — генерация: xray x25519
xray_reality:
  private_key: "ВАШ_ПРИВАТНЫЙ_КЛЮЧ"
  public_key: "ВАШ_ПУБЛИЧНЫЙ_КЛЮЧ"
  spiderX: "/"
  short_id:
    - "a1b2c3d4e5f67890"   # 8-байтный hex — генерация: openssl rand -hex 8

# VLESS пользователи
xray_users:
  - id: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"   # UUID — генерация: uuidgen
    flow: "xtls-rprx-vision"
    email: "alice@example.com"
```

### `roles/raven_subscribe/defaults/secrets.yml`

```yaml
# Токен admin API — генерация: openssl rand -hex 32
raven_subscribe_admin_token: "ВАШ_ADMIN_ТОКЕН"

# Публичный URL для ссылок подписки
raven_subscribe_base_url: "https://my.example.com"

# Публичный домен или IP EU VPS
raven_subscribe_server_host: "media.example.com"

# Переопределение host/port по inbound (опционально)
# Позволяет разные адреса для разных протоколов в клиентских конфигах.
# Полезно когда клиенты подключаются через relay для части протоколов.
raven_subscribe_inbound_hosts:
  vless-reality-in: "example.com"    # RU relay для Reality
  vless-xhttp-in: "media.example.com"
raven_subscribe_inbound_ports:
  vless-reality-in: 8444             # TCP порт RU relay для Reality
```

### `roles/nginx_frontend/defaults/secrets.yml`

```yaml
nginx_frontend_certbot_email: "admin@example.com"
```

### `roles/relay/defaults/secrets.yml`

```yaml
relay_upstream_host: "EU_VPS_IP"       # IP-адрес EU сервера
relay_certbot_email: "admin@example.com"
```

### `roles/sing-box-playbook/defaults/secrets.yml`

```yaml
singbox_hysteria2_users:
  - name: "alice@example.com"
    password: "СИЛЬНЫЙ_СЛУЧАЙНЫЙ_ПАРОЛЬ"

singbox:
  tls_server_name: "media.example.com"
  tls_acme_domain: "media.example.com"
  tls_acme_email: "admin@example.com"
```

---

## Конфигурация

### Xray (`roles/xray/defaults/main.yml`)

| Переменная | По умолчанию | Описание |
|-----------|--------------|---------|
| `xray_vless_port` | `443` | Порт VLESS + Reality |
| `xray_reality_dest` | `askubuntu.com:443` | Camouflage-ресурс Reality (должен быть реальным TLS-сайтом) |
| `xray_reality_server_names` | `["askubuntu.com"]` | SNI имена для Reality |
| `xray_xhttp.port` | `2053` | Порт XHTTP inbound |
| `xray_xhttp.xhttpSettings.path` | `/api/v3/data-sync` | Путь XHTTP (должен совпадать с nginx_frontend) |
| `xray_dns_servers` | `tcp+local://8.8.8.8, ...` | DNS-серверы — не используйте DoH (`https://`) |
| `xray_dns_query_strategy` | `UseIPv4` | `UseIPv4` если нет глобального IPv6, иначе `UseIP` |
| `xray_vless_decryption` | `"none"` | Режим VLESS Encryption — см. [VLESS Encryption](#vless-encryption-опционально) |
| `xray_blocked_domains` | `[]` | Дополнительные домены для блокировки |

### Raven-subscribe (`roles/raven_subscribe/defaults/main.yml`)

| Переменная | По умолчанию | Описание |
|-----------|--------------|---------|
| `raven_subscribe_listen_addr` | `:8080` | Адрес для прослушивания |
| `raven_subscribe_sync_interval_seconds` | `60` | Интервал пересканирования конфигов Xray |
| `raven_subscribe_api_inbound_tag` | `vless-reality-in` | Inbound по умолчанию для пользователей через API |
| `raven_subscribe_xray_api_addr` | `127.0.0.1:10085` | Адрес gRPC API Xray |
| `raven_subscribe_inbound_hosts` | `{}` | Переопределение host по inbound (задать в secrets.yml) |
| `raven_subscribe_inbound_ports` | `{}` | Переопределение port по inbound (задать в secrets.yml) |
| `raven_subscribe_singbox_enabled` | `false` | Включить синхронизацию sing-box/Hysteria2 |

### nginx_frontend (`roles/nginx_frontend/defaults/main.yml`)

| Переменная | По умолчанию | Описание |
|-----------|--------------|---------|
| `nginx_frontend_domain` | `media.example.com` | Домен EU VPS — заменить на свой |
| `nginx_frontend_listen_port` | `8443` | Порт HTTPS nginx (не 443 — занят Xray) |
| `nginx_frontend_xhttp_port` | `2053` | Порт upstream Xray XHTTP |
| `nginx_frontend_xhttp_path` | `/api/v3/data-sync` | Путь XHTTP (должен совпадать с конфигом Xray) |
| `nginx_frontend_reality_port` | `8445` | Порт TCP stream relay для Reality |

### relay (`roles/relay/defaults/main.yml`)

| Переменная | По умолчанию | Описание |
|-----------|--------------|---------|
| `relay_domain` | `example.com` | Домен RU VPS — заменить на свой |
| `relay_upstream_raven_port` | `8443` | Порт nginx_frontend на EU (должен совпадать с `nginx_frontend_listen_port`) |
| `relay_stream_port` | `8444` | TCP порт RU relay для Reality (открытый для клиентов) |
| `relay_upstream_xray_port` | `8445` | Порт nginx stream на EU (должен совпадать с `nginx_frontend_reality_port`) |
| `relay_stub_title` | `Welcome` | Заголовок страницы stub-сайта |
| `relay_stub_description` | `Personal website` | Мета-описание stub-сайта |

---

## DNS-записи

Направьте следующие DNS A-записи на нужные серверы:

| Домен | → | Сервер | Назначение |
|-------|---|--------|-----------|
| `media.example.com` | → | IP EU VPS | nginx_frontend (XHTTP, Raven) |
| `example.com` | → | IP RU VPS | Stub-сайт relay |
| `my.example.com` | → | IP RU VPS | Relay → Raven-subscribe |

TCP relay Reality (порт 8444 на RU VPS) работает по IP — DNS-запись не нужна.

---

## VLESS Encryption (опционально)

Xray-core >= 25.x поддерживает пост-квантовое VLESS Encryption (mlkem768x25519plus). По умолчанию отключено.

При включении **все** клиенты, подключающиеся к inbound, должны поддерживать шифрование — нельзя смешивать зашифрованных и обычных клиентов на одном inbound.

**Генерация ключей:**

```bash
xray vlessenc
# Вывод: decryption string (приватный, для сервера) + encryption string (публичный, для клиентов)
```

**Добавить в `roles/xray/defaults/secrets.yml`:**

```yaml
xray_vless_decryption: "mlkem768x25519plus.PRIVATE..."    # сервер — держать в секрете
xray_vless_client_encryption: "mlkem768x25519plus.PUBLIC..." # передаётся клиентам через Raven
```

Оба значения задаются одновременно или оба остаются `"none"`. При включении `flow` принудительно устанавливается в `xtls-rprx-vision` для всех пользователей.

---

## Hysteria2 / sing-box (опционально)

Задеплойте sing-box рядом с Xray для поддержки Hysteria2 (QUIC-протокол с обфускацией Salamander).

```bash
# Скопировать и заполнить секреты
cp roles/sing-box-playbook/defaults/secrets.yml.example roles/sing-box-playbook/defaults/secrets.yml
ansible-vault encrypt roles/sing-box-playbook/defaults/secrets.yml --vault-password-file vault_password.txt

# Задеплоить
ansible-playbook roles/role_sing-box.yml -i roles/hosts.yml --vault-password-file vault_password.txt
```

После деплоя установите `raven_subscribe_singbox_enabled: true` в `raven_subscribe/defaults/secrets.yml` и передеплойте Raven-subscribe. Он обнаружит Hysteria2-пользователей и будет раздавать их через эндпоинты `/sub/{token}/singbox` и `/sub/{token}/hysteria2`.

**Примечание:** Hysteria2 использует ACME (Let's Encrypt) напрямую в sing-box. Задайте `singbox.tls_acme_domain` и `singbox.tls_acme_email` в секретах.

---

## Тестирование

Полный тестовый прогон — рендер всех Ansible-шаблонов и валидация через `xray -test` в Docker:

```bash
./tests/run.sh
```

Только Ansible (без Docker):

```bash
SKIP_XRAY_TEST=1 ./tests/run.sh
```

**Шаги пайплайна:**
1. Скачивает бинарь Xray (кэшируется в `tests/.cache/`)
2. Генерирует временные ключи Reality → `tests/fixtures/test_secrets.yml`
3. Запускает проверки `validate.yml`
4. Рендерит все `templates/conf/*.j2` → `tests/.output/conf.d/`
5. Запускает `xray -test -confdir` в Docker

CI запускается автоматически на каждый push и PR через `.github/workflows/xray-config-test.yml`.

**Запуск отдельных шагов вручную:**

```bash
export ANSIBLE_CONFIG="${PWD}/tests/ansible.cfg"
tests/scripts/gen-reality-keys.sh > tests/fixtures/test_secrets.yml
ansible-playbook tests/playbooks/validate_vars.yml
ansible-playbook tests/playbooks/render_conf.yml
```

---

## Связанные проекты

- [Raven-subscribe](https://github.com/AlchemyLink/Raven-subscribe) — сервер подписок (Go): автоматически находит пользователей из конфигов Xray, синхронизирует через gRPC API, раздаёт персональные ссылки подписки в форматах Xray JSON / sing-box JSON / share-ссылки
- [Xray-core](https://github.com/XTLS/Xray-core) — ядро VPN
- [sing-box](https://github.com/SagerNet/sing-box) — альтернативное ядро VPN (Hysteria2)

---

## Лицензия

[Mozilla Public License 2.0](LICENSE)
