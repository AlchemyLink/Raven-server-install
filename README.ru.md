# Raven Server Install

Языки: [English](README.md) | **Русский**

[![CI](https://github.com/AlchemyLink/Raven-server-install/actions/workflows/xray-config-test.yml/badge.svg)](https://github.com/AlchemyLink/Raven-server-install/actions/workflows/xray-config-test.yml)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL_2.0-brightgreen.svg)](LICENSE)
[![Ansible](https://img.shields.io/badge/Ansible-%3E%3D2.14-red?logo=ansible)](https://docs.ansible.com/)
[![Platform](https://img.shields.io/badge/Platform-Debian%2011%2B%20%7C%20Ubuntu%2020.04%2B-blue)](https://www.debian.org/)
[![Status](https://img.shields.io/badge/Status-Alpha%20Testing-orange)](https://github.com/AlchemyLink/Raven-server-install)

Ansible-плейбуки для развёртывания production-ready самохостинг VPN-стека на основе [Xray-core](https://github.com/XTLS/Xray-core) и [Raven-subscribe](https://github.com/AlchemyLink/Raven-subscribe). Весь трафик неотличим от обычного HTTPS.

> [!WARNING]
> **Альфа-тестирование** — проект находится в активной разработке. Между версиями могут меняться имена переменных, API и порядок деплоя. Тщательно тестируйте перед использованием в продакшне. Пожалуйста, [сообщайте об ошибках](https://github.com/AlchemyLink/Raven-server-install/issues), чтобы помочь улучшить проект.

**Что вы получаете:**

- Xray-core с inbound'ами VLESS + XTLS-Reality (TCP) и VLESS + XHTTP (HTTP/2)
- V2 параллельные inbound'ы с изолированными Reality-ключами для прямой секретности
- Опциональное пост-квантовое VLESS Encryption (mlkem768x25519plus, Xray-core ≥ 26.x)
- nginx SNI routing на порту 443 — весь VPN-трафик идёт через стандартный HTTPS-порт
- Опциональный прозрачный цепочечный прокси для RU VPS (`xray_bridge`) — клиенты используют EU-конфиги без изменений
- Опциональный Hysteria2 через [sing-box](https://github.com/SagerNet/sing-box)
- [Raven-subscribe](https://github.com/AlchemyLink/Raven-subscribe) — сервер подписок: автоматически находит пользователей, раздаёт клиентские конфиги по персональным ссылкам
- [xray-stats-exporter](https://github.com/AlchemyLink/xray-stats-exporter) + VictoriaMetrics + Grafana — мониторинг с дашбордами трафика по пользователям и протоколам
- systemd-сервисы с валидацией конфига перед каждым перезапуском
- Блокировка рекламы и публичных трекеров (`geosite:category-ads-all`)
- BBR и тюнинг sysctl (роль `srv_prepare`)

---

## Содержание

- [Архитектура](#архитектура)
- [Требования](#требования)
- [Быстрый старт](#быстрый-старт)
- [Описание ролей](#описание-ролей)
- [Секреты](#секреты)
- [Конфигурация](#конфигурация)
- [Примеры](#примеры)
- [DNS-записи](#dns-записи)
- [VLESS Encryption (опционально)](#vless-encryption-опционально)
- [Hysteria2 / sing-box (опционально)](#hysteria2--sing-box-опционально)
- [Тестирование](#тестирование)
- [Решение проблем](#решение-проблем)
- [Как помочь проекту](#как-помочь-проекту)
- [Связанные проекты](#связанные-проекты)
- [Лицензия](#лицензия)

---

## Архитектура

Поддерживаются две топологии деплоя.

### Один сервер (минимальный вариант)

Один VPS с Xray + Raven-subscribe + nginx. Весь трафик через порт 443 — nginx маршрутизирует по SNI.

```
Клиент  ──VLESS+Reality──►  VPS:443 (nginx SNI) ──► VPS:4443 (Xray)
Клиент  ──VLESS+XHTTP────►  VPS:443 (nginx SNI) ──► VPS:2053 (Xray)
Клиент  ──подписка───────►  VPS:443 (nginx SNI) ──► VPS:8443 (nginx HTTPS) ──► Raven:8080
```

### Два сервера с прозрачным RU-мостом (рекомендуется для пользователей из СНГ)

EU VPS: Xray + nginx_frontend + Raven-subscribe.
RU VPS: SNI relay + xray_bridge. Клиенты используют **существующие EU-конфиги без изменений** — nginx на RU маршрутизирует каждый SNI на мост, который принимает подключения с EU-ключами Reality и цепочкой передаёт трафик на EU через XHTTP.

```
Клиент (EU-конфиг без изменений)
       │ SNI: askubuntu.com / dl.google.com / addons.mozilla.org
       ▼
RU VPS :443 (nginx SNI routing)
  ├─ askubuntu.com      → xray-bridge :5444  (Reality прозрачный inbound, EU v1 ключи)
  ├─ dl.google.com      → xray-bridge :5446  (Reality v2, EU v2 ключи + mldsa65)
  ├─ addons.mozilla.org → xray-bridge :5447  (XHTTP v2, EU v2 ключи)
  └─ www.wikipedia.org  → xray-bridge :5443  (bridge-specific inbound)
       │
       ▼ XHTTP packet-up, EU v2 Reality keys
EU VPS :443 (nginx SNI) → Xray XHTTP :2054 → Интернет
```

Raven-subscribe на EU автоматически синхронизирует пользователей с inbound'ами моста через WireGuard+gRPC.

### Карта ролей

| Роль | VPS | Плейбук | Что делает |
|------|-----|---------|-----------|
| `srv_prepare` | EU | `role_xray.yml` | BBR, sysctl, системный пользователь `xrayuser` |
| `xray` | EU | `role_xray.yml` | Бинарь Xray + split-конфиг в `/etc/xray/config.d/` |
| `raven_subscribe` | EU | `role_raven_subscribe.yml` | Сервер подписок, gRPC-синхронизация с Xray и мостом |
| `nginx_frontend` | EU | `role_nginx_frontend.yml` | nginx SNI routing на :443, HTTPS прокси на :8443 |
| `monitoring` | EU+RU | `role_monitoring.yml` | xray-stats-exporter + VictoriaMetrics + Grafana |
| `wireguard` | EU+RU | `role_wireguard.yml` | WireGuard mesh — туннель EU↔RU для мониторинга и синхронизации моста |
| `sing-box-playbook` | EU | `role_sing-box.yml` | sing-box + Hysteria2 (опционально) |
| `relay` | RU | `role_relay.yml` | nginx SNI relay на :443 — маршрутизирует VPN-трафик |
| `xray_bridge` | RU | `role_xray_bridge.yml` | Xray цепочечный прокси — принимает подключения, цепочкой на EU через XHTTP |

---

## Требования

- **Ansible** >= 2.14 (`ansible-core`)
- **ОС на сервере**: Debian 11+ / Ubuntu 20.04+ с systemd
- **Python 3** на целевых серверах
- **ansible-vault** для управления секретами
- **Docker** (опционально, для локального тестирования конфигов)

> **Примечание:** Роли `nginx_frontend` и `relay` автоматически устанавливают `libnginx-mod-stream`. Если nginx уже установлен без него, выполните: `sudo apt install libnginx-mod-stream && sudo systemctl restart nginx`.

---

## Быстрый старт

### 1. Клонировать репозиторий

```bash
git clone https://github.com/AlchemyLink/Raven-server-install.git
cd Raven-server-install
```

### 2. Создать файл пароля vault

```bash
echo "ваш-сильный-пароль-vault" > vault_password.txt
chmod 600 vault_password.txt
```

### 3. Создать inventory

Скопируйте пример и укажите IP ваших серверов:

```bash
cp roles/hosts.yml.example roles/hosts.yml
```

Отредактируйте `roles/hosts.yml`:

```yaml
all:
  children:
    cloud:
      hosts:
        vm_my_srv:
          ansible_host: "IP_EU_VPS"
          ansible_port: 22
        vm_my_ru2:                        # опционально: RU VPS для relay + bridge
          ansible_host: "IP_RU_VPS"
          ansible_port: 22
          ansible_user: deploy
      vars:
        ansible_user: deploy
        ansible_python_interpreter: /usr/bin/python3
        ansible_ssh_private_key_file: ~/.ssh/id_ed25519
        ansible_ssh_host_key_checking: false
```

### 4. Создать файлы секретов

У каждой роли есть `defaults/secrets.yml.example`. Скопируйте, заполните и зашифруйте:

```bash
# Xray (EU)
cp roles/xray/defaults/secrets.yml.example roles/xray/defaults/secrets.yml
# Заполнить: Reality-ключи (xray x25519), short_id (openssl rand -hex 8), users (uuidgen)
ansible-vault encrypt roles/xray/defaults/secrets.yml --vault-password-file vault_password.txt

# Raven-subscribe (EU)
cp roles/raven_subscribe/defaults/secrets.yml.example roles/raven_subscribe/defaults/secrets.yml
# Заполнить: admin_token (openssl rand -hex 32), server_host (домен/IP EU VPS),
#            base_url (публичный URL подписок, например https://my.yourdomain.com)
ansible-vault encrypt roles/raven_subscribe/defaults/secrets.yml --vault-password-file vault_password.txt

# nginx_frontend (EU)
cp roles/nginx_frontend/defaults/secrets.yml.example roles/nginx_frontend/defaults/secrets.yml
# Заполнить: домен и email для certbot
ansible-vault encrypt roles/nginx_frontend/defaults/secrets.yml --vault-password-file vault_password.txt

# relay (RU) — опционально
cp roles/relay/defaults/secrets.yml.example roles/relay/defaults/secrets.yml
# Заполнить: relay_upstream_host (IP EU VPS) и email для certbot
ansible-vault encrypt roles/relay/defaults/secrets.yml --vault-password-file vault_password.txt
```

Редактировать зашифрованный файл:

```bash
ansible-vault edit roles/xray/defaults/secrets.yml --vault-password-file vault_password.txt
```

### 5. Сгенерировать ключи Reality

```bash
# На любой машине с установленным Xray:
xray x25519
# Вывод: PrivateKey + PublicKey — оба вносим в roles/xray/defaults/secrets.yml

openssl rand -hex 8   # short_id
```

### 6. Задеплоить

Деплоить строго в указанном порядке — каждый шаг зависит от предыдущего:

| # | Роль | Почему этот порядок |
|---|------|---------------------|
| 1 | `role_xray` | Создаёт `/etc/xray/config.d/`, системного пользователя `xrayuser`, запускает Xray с gRPC API на `:10085` |
| 2 | `role_raven_subscribe` | Читает конфиги из `/etc/xray/config.d/` и обращается к gRPC API — без шага 1 не запустится |
| 3 | `role_nginx_frontend` | Проксирует трафик на Xray и Raven-subscribe — без шагов 1–2 некуда форвардить |
| 4 | `role_xray_bridge` | (RU) Цепочечный прокси — нужны EU Reality-ключи из шага 1 |
| 5 | `role_relay` | (RU) nginx relay — маршрутизирует на EU; если включён transparent bridge, xray_bridge из шага 4 должен уже слушать |

```bash
VP=vault_password.txt

# 1. EU — Xray + системная подготовка (ПЕРВЫМ — создаёт xrayuser и config.d)
ansible-playbook roles/role_xray.yml -i roles/hosts.yml --vault-password-file $VP

# 2. EU — Raven-subscribe (требует Xray из шага 1)
ansible-playbook roles/role_raven_subscribe.yml -i roles/hosts.yml --vault-password-file $VP

# 3. EU — nginx TLS frontend + SNI stream routing
ansible-playbook roles/role_nginx_frontend.yml -i roles/hosts.yml --vault-password-file $VP

# 4. RU — xray_bridge (деплоить ДО relay)
ansible-playbook roles/role_xray_bridge.yml -i roles/hosts.yml --vault-password-file $VP

# 5. RU — nginx relay
ansible-playbook roles/role_relay.yml -i roles/hosts.yml --vault-password-file $VP
```

Деплой только конкретной части через теги:

```bash
ansible-playbook roles/role_xray.yml -i roles/hosts.yml --vault-password-file $VP \
  --tags xray_inbounds
```

---

## Описание ролей

### Роль `xray`

Устанавливает и настраивает Xray-core. Конфиг разделён на пронумерованные JSON-файлы в `/etc/xray/config.d/` — Xray загружает их по порядку.

**Теги:**

| Тег | Что делает |
|-----|-----------|
| `xray_install` | Скачивает бинарь Xray с GitHub releases |
| `xray_base` | Записывает `000-log.json`, `010-stats.json` |
| `xray_api` | Записывает `050-api.json` (gRPC API на 127.0.0.1:10085) |
| `xray_inbounds` | Записывает конфиги VLESS Reality + XHTTP inbound'ов |
| `xray_dns` | Записывает `100-dns.json` |
| `xray_outbounds` | Записывает `300-outbounds.json` (Finalmask fragment anti-DPI) |
| `xray_routing` | Записывает `400-routing.json` |
| `xray_service` | Деплоит systemd unit, включает сервис |

**Файлы конфигурации:**

| Файл | Содержимое |
|------|-----------|
| `000-log.json` | Уровни логирования, пути файлов |
| `010-stats.json` | Статистика трафика |
| `050-api.json` | gRPC API (127.0.0.1:10085) |
| `100-dns.json` | DNS-серверы |
| `200-in-vless-reality.json` | VLESS + Reality inbound (порт 4443) |
| `201-in-vless-reality-v2.json` | V2 VLESS + Reality inbound (порт 4444, изолированные ключи) |
| `210-in-xhttp.json` | VLESS + XHTTP inbound (порт 2053) |
| `211-in-xhttp-v2.json` | V2 VLESS + XHTTP inbound (порт 2054) |
| `300-outbounds.json` | Freedom (с Finalmask fragment) + blackhole |
| `400-routing.json` | Правила маршрутизации + блокировка рекламы |

**Безопасность handlers:** `Validate xray` выполняется раньше `Restart xray` — невалидный конфиг никогда не вызовет перезапуск.

---

### Роль `raven_subscribe`

Деплоит [Raven-subscribe](https://github.com/AlchemyLink/Raven-subscribe) — Go-сервис, который автоматически находит пользователей Xray, синхронизирует их через gRPC API и раздаёт персональные ссылки подписки.

- Слушает на `127.0.0.1:8080`, проксируется через nginx_frontend
- Автоматически синхронизирует пользователей с inbound'ами моста через `bridge_transparent_tags` (требует туннель WireGuard)
- Следит за `/etc/xray/config.d/` через fsnotify — подхватывает изменения за секунды

---

### Роль `nginx_frontend`

Деплоит nginx на EU VPS как TLS frontend и SNI router. Порт 443 обрабатывает весь трафик.

- **Stream SNI routing на :443** — маршрутизирует по SNI:
  - `www.adobe.com` → Xray XHTTP `:2053`
  - `addons.mozilla.org` → Xray XHTTP v2 `:2054`
  - `askubuntu.com` → Xray Reality `:4443`
  - `dl.google.com` → Xray Reality v2 `:4444`
  - `your-domain.com` → nginx HTTPS `:8443` (Raven-subscribe)
- **HTTPS на :8443** — проксирует `/sub/`, `/c/`, `/api/` → Raven-subscribe `:8080`

**Важно:** Сначала деплоить **Xray**, потом nginx. nginx сразу начинает отправлять PROXY protocol заголовки — Xray должен быть готов их принять.

---

### Роль `relay`

Деплоит nginx на RU VPS как SNI relay.

- **Stream SNI routing на :443** — маршрутизирует EU VPN SNIs на прозрачные inbound'ы xray_bridge (при `relay_transparent_enabled: true`), всё остальное → EU VPS напрямую
- Отдаёт статический stub-сайт на `relay_domain` (маскировка)
- Проксирует `my.relay_domain` → EU Raven-subscribe

**Порядок деплоя:** Всегда деплоить `xray_bridge` раньше `relay`. Роль relay проверяет, что порты моста 5444–5447 слушают, прежде чем рендерить конфиг stream.

**Экстренный откат:** Установите `relay_transparent_enabled: false` в секретах relay и передеплойте с `--tags relay_stream`. Весь трафик пойдёт напрямую на EU, минуя мост.

---

### Роль `xray_bridge`

Деплоит Xray цепочечный прокси на RU VPS. Принимает подключения клиентов с EU-ключами Reality (прозрачно — клиенты используют существующие конфиги без изменений), затем передаёт трафик на EU через XHTTP.

- Прозрачные inbound'ы на портах 5444–5447 (по одному на каждый EU inbound)
- Outbound: VLESS → EU XHTTP v2 (SNI addons.mozilla.org, mlkem768x25519plus)
- Split routing: `.ru`/`.su`/`.рф` и российские сервисы → прямой выход, всё остальное → цепочка на EU
- Stats API на `bridge_api_address:10086` (доступен через WireGuard с EU для синхронизации Raven)

---

### Роль `wireguard`

Создаёт WireGuard mesh между EU и RU VPS. Требуется для:
- Синхронизации gRPC Raven-subscribe → мост (EU пушит пользователей на RU мост через WireGuard)
- Мониторинга (vmagent на EU пушит метрики на VictoriaMetrics на RU)

---

### Роль `monitoring`

Деплоит полный стек мониторинга:

- **[xray-stats-exporter](https://github.com/AlchemyLink/xray-stats-exporter)** на EU — метрики трафика по пользователям и inbound'ам
- **VictoriaMetrics** на RU — TSDB, совместимая с Prometheus
- **Grafana** на RU — дашборды трафика, состояния серверов, Raven-subscribe, правила алертинга

```bash
ansible-playbook roles/role_monitoring.yml -i roles/hosts.yml --vault-password-file vault_password.txt
```

---

## Секреты

У каждой роли секреты хранятся в `defaults/secrets.yml` (зашифровано ansible-vault, не коммитится). Шаблоны — в `defaults/secrets.yml.example`.

### `roles/xray/defaults/secrets.yml`

```yaml
# Reality-ключи — генерация: xray x25519
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

# Публичный URL для ссылок подписки — должен быть доменом relay, не прямым IP EU
raven_subscribe_base_url: "https://my.yourdomain.com"

# Публичный домен или IP EU VPS
raven_subscribe_server_host: "yourdomain.com"

# Переопределение хоста по inbound (опционально).
# Если не указано — используется raven_subscribe_server_host.
# raven_subscribe_inbound_hosts:
#   vless-reality-in: "askubuntu.com"
#   vless-xhttp-in: "www.adobe.com"

# Переопределение порта по inbound (опционально).
# При SNI-маршрутизации все протоколы идут через порт 443.
# raven_subscribe_inbound_ports:
#   vless-reality-in: 443
#   vless-xhttp-in: 443
#   vless-reality-v2-in: 443
#   vless-xhttp-v2-in: 443

# VLESS Encryption — переопределение ключей по inbound (опционально).
# Нужно только если у v1 и v2 inbound'ов разные ключи шифрования.
# Если не задано — xray_vless_client_encryption из xray secrets применяется ко всем inbound'ам.
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
relay_upstream_host: "IP_EU_VPS"
relay_certbot_email: "admin@example.com"
relay_domain: "example.com"
relay_sub_my: "my.example.com"
```

### `roles/xray_bridge/defaults/secrets.yml`

```yaml
xray_bridge_reality:
  private_key: "BRIDGE_PRIVATE_KEY"   # xray x25519 (отдельно от EU-ключей)
  public_key: "BRIDGE_PUBLIC_KEY"
  spiderX: "/"
  short_id:
    - "b1c2d3e4f5a67890"

xray_bridge_users:                    # те же UUID, что в EU xray_users
  - id: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    flow: "xtls-rprx-vision"
    email: "alice@example.com"

xray_bridge_eu_host: "IP_EU_VPS"
xray_bridge_eu_reality_public_key: "EU_V2_PUBLIC_KEY"
xray_bridge_eu_reality_short_id: "EU_V2_SHORT_ID"
xray_bridge_eu_user_id: "BRIDGE_USER_UUID"   # отдельный UUID, зарегистрированный на EU XHTTP inbound

xray_bridge_transparent_enabled: true
xray_bridge_api_address: "10.10.0.2"         # WireGuard IP RU VPS
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
| `xray_reality_dest` | `askubuntu.com:443` | Camouflage-ресурс Reality |
| `xray_reality_server_names` | `["askubuntu.com"]` | SNI имена для Reality |
| `xray_xhttp.port` | `2053` | Порт XHTTP inbound |
| `xray_v2_inbounds_enabled` | `true` | Включить v2 параллельные inbound'ы (порты 4444/2054) |
| `xray_dns_servers` | `tcp+local://8.8.8.8, ...` | DNS-серверы — не используйте DoH (`https://`) |
| `xray_dns_query_strategy` | `UseIPv4` | `UseIPv4` если нет глобального IPv6, иначе `UseIP` |
| `xray_vless_decryption` | `"none"` | Режим VLESS Encryption — см. [VLESS Encryption](#vless-encryption-опционально) |

### Raven-subscribe (`roles/raven_subscribe/defaults/main.yml`)

| Переменная | По умолчанию | Описание |
|-----------|--------------|---------|
| `raven_subscribe_sync_interval_seconds` | `60` | Интервал пересканирования конфигов Xray |
| `raven_subscribe_xray_api_addr` | `127.0.0.1:10085` | Адрес gRPC API Xray |
| `raven_subscribe_bridge_api_addr` | `""` | gRPC API моста (указать WireGuard IP:10086) |
| `raven_subscribe_bridge_transparent_tags` | `{}` | Маппинг EU inbound tag → прозрачный tag моста |

### relay (`roles/relay/defaults/main.yml`)

| Переменная | По умолчанию | Описание |
|-----------|--------------|---------|
| `relay_transparent_enabled` | `false` | Маршрутизировать EU SNIs на прозрачные inbound'ы xray_bridge |
| `relay_bridge_enabled` | `false` | Включить маршрутизацию bridge-specific SNI (www.wikipedia.org → :5443) |
| `relay_domain` | `example.com` | Домен RU VPS — stub-сайт и SNI routing |
| `relay_sub_my` | `my.example.com` | Поддомен, проксируемый на EU Raven-subscribe |
| `relay_upstream_host` | `EU_VPS_IP` | IP EU сервера (задать в secrets.yml) |

---

## Примеры

### Сгенерировать ключи Reality

```bash
# Пара ключей x25519 для Reality
xray x25519
# PrivateKey: <base64-encoded-private-key>
# PublicKey:  <base64-encoded-public-key>

# short_id (8 байт hex)
openssl rand -hex 8
# a1b2c3d4e5f67890

# UUID для нового пользователя
uuidgen
# f47ac10b-58cc-4372-a567-0e02b2c3d479
```

### Обновить только inbound'ы (без перезапуска если конфиг не изменился)

```bash
ansible-playbook roles/role_xray.yml -i roles/hosts.yml \
  --vault-password-file vault_password.txt \
  --tags xray_inbounds
# Рендерит новые inbound-конфиги, валидирует, перезапускает только если есть изменения
```

### Добавить нового пользователя

Откройте файл секретов:

```bash
ansible-vault edit roles/xray/defaults/secrets.yml --vault-password-file vault_password.txt
```

Добавьте запись в `xray_users`:

```yaml
xray_users:
  - id: "existing-user-uuid"
    flow: "xtls-rprx-vision"
    email: "alice@example.com"
  - id: "f47ac10b-58cc-4372-a567-0e02b2c3d479"   # новый пользователь
    flow: "xtls-rprx-vision"
    email: "bob@example.com"
```

Передеплойте inbound'ы:

```bash
ansible-playbook roles/role_xray.yml -i roles/hosts.yml \
  --vault-password-file vault_password.txt \
  --tags xray_inbounds
```

Raven-subscribe подхватит нового пользователя через fsnotify в течение `sync_interval_seconds` и автоматически сгенерирует персональную ссылку подписки.

### Проверить статус сервисов на удалённом сервере

```bash
# Проверить, что Xray запущен
ansible vm_my_srv -i roles/hosts.yml -m command -a "systemctl status xray" \
  --vault-password-file vault_password.txt

# Проверить Raven-subscribe
ansible vm_my_srv -i roles/hosts.yml -m command -a "systemctl status xray-subscription"

# Посмотреть последние логи Xray
ansible vm_my_srv -i roles/hosts.yml -m command \
  -a "journalctl -u xray -n 50 --no-pager"
```

### Экстренный откат: отключить RU-мост

Если мост сломан и VPN не работает у всех клиентов:

```bash
# 1. Отредактировать секреты relay — отключить прозрачную маршрутизацию
ansible-vault edit roles/relay/defaults/secrets.yml --vault-password-file vault_password.txt
# Установить: relay_transparent_enabled: false

# 2. Передеплоить только stream-конфиг (~30 секунд)
ansible-playbook roles/role_relay.yml -i roles/hosts.yml \
  --vault-password-file vault_password.txt \
  --tags relay_stream
# Весь трафик теперь идёт напрямую на EU VPS
```

### Запустить тесты валидации конфигов локально

```bash
# Полный тест: рендер шаблонов + валидация через xray -test в Docker
./tests/run.sh

# Только Ansible (Docker не нужен)
SKIP_XRAY_TEST=1 ./tests/run.sh
```

---

## DNS-записи

| Домен | → | Сервер | Назначение |
|-------|---|--------|-----------|
| `your-domain.com` | → | IP EU VPS | nginx_frontend (TLS сертификат) |
| `my.your-domain.com` | → | IP EU VPS | Raven-subscribe (одиночный сервер) |
| `example.com` | → | IP RU VPS | Stub-сайт relay (маскировка) |
| `my.example.com` | → | IP RU VPS | Relay → Raven-subscribe (ссылки подписки) |

Клиенты подключаются к RU VPS на порт 443 для всех протоколов — дополнительные DNS-записи для VPN-трафика не нужны.

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

```bash
cp roles/sing-box-playbook/defaults/secrets.yml.example roles/sing-box-playbook/defaults/secrets.yml
ansible-vault encrypt roles/sing-box-playbook/defaults/secrets.yml --vault-password-file vault_password.txt
ansible-playbook roles/role_sing-box.yml -i roles/hosts.yml --vault-password-file vault_password.txt
```

После деплоя установите `raven_subscribe_singbox_enabled: true` в `raven_subscribe/defaults/secrets.yml` и передеплойте Raven-subscribe. Он обнаружит Hysteria2-пользователей и будет раздавать их через `/sub/{token}/singbox` и `/sub/{token}/hysteria2`.

---

## Тестирование

```bash
./tests/run.sh                        # полный: рендер шаблонов + xray -test в Docker
SKIP_XRAY_TEST=1 ./tests/run.sh       # только Ansible, без Docker
```

CI запускается автоматически на каждый push и PR. Подробнее — [tests/README.md](tests/README.md).

---

## Решение проблем

### `unknown directive "stream"` — nginx не запускается

Модуль `stream` не установлен. Исправление:

```bash
sudo apt install libnginx-mod-stream
sudo systemctl start nginx
```

Плейбуки устанавливают `libnginx-mod-stream` автоматически при свежем деплое.

### `unknown directive "http2"` — nginx не запускается

Версия nginx < 1.25.1 (типично для Debian 11 / Ubuntu 20.04 из стандартных репозиториев). Плейбуки автоматически определяют версию и используют правильный синтаксис. Если ошибка возникла на уже установленном nginx, передеплойте:

```bash
ansible-playbook roles/role_nginx_frontend.yml -i roles/hosts.yml \
  --vault-password-file vault_password.txt --tags nginx_frontend_ssl
```

### `chgrp failed: failed to look up group xrayuser` — деплой raven_subscribe падает

Обновите репозиторий — начиная с текущей версии роль `raven_subscribe` создаёт пользователя и группу `xrayuser` самостоятельно:

```bash
git pull
ansible-playbook roles/role_raven_subscribe.yml -i roles/hosts.yml --vault-password-file vault_password.txt
```

Если обновить невозможно — сначала задеплойте Xray, который создаёт `xrayuser` через `srv_prepare`:

```bash
ansible-playbook roles/role_xray.yml -i roles/hosts.yml --vault-password-file vault_password.txt
```

### `raven_subscribe_admin_token must be set` — валидация не проходит

Файл `secrets.yml` для raven_subscribe не создан:

```bash
cp roles/raven_subscribe/defaults/secrets.yml.example roles/raven_subscribe/defaults/secrets.yml
# Заполнить: admin_token (openssl rand -hex 32) и server_host
ansible-vault encrypt roles/raven_subscribe/defaults/secrets.yml --vault-password-file vault_password.txt
```

### `no hosts matched` — плейбук пропускает все хосты

Проверьте, что `roles/hosts.yml` содержит `vm_my_srv` (для EU ролей) и `vm_my_ru2` (для RU ролей). Плейбуки таргетируют именно эти имена хостов.

### nginx не перезапускается после деплоя конфига

Предыдущий неудачный деплой оставил сломанный конфиг. Удалите его и перезапустите:

```bash
sudo rm /etc/nginx/conf.d/<ваш-домен>.conf
sudo systemctl start nginx
# Затем передеплойте:
ansible-playbook roles/role_nginx_frontend.yml -i roles/hosts.yml \
  --vault-password-file vault_password.txt --tags nginx_frontend_ssl
```

---

## Как помочь проекту

Проект находится в **альфа-тестировании**. Мы рады любым contributions и сообщениям об ошибках.

1. Сделайте fork репозитория и создайте ветку с изменениями
2. Перед отправкой PR проверьте изменения через `./tests/run.sh`
3. Откройте pull request с описанием что и почему изменено

**Сообщение об ошибке:** укажите версию Ansible, ОС целевого сервера и полный вывод ошибки.

---

## Связанные проекты

- [Raven-subscribe](https://github.com/AlchemyLink/Raven-subscribe) — сервер подписок (Go): автоматически находит пользователей из конфигов Xray, синхронизирует через gRPC API, раздаёт персональные ссылки подписки в форматах Xray JSON / sing-box JSON / share-ссылки
- [xray-stats-exporter](https://github.com/AlchemyLink/xray-stats-exporter) — Prometheus exporter для метрик трафика Xray по пользователям и inbound'ам
- [Xray-core](https://github.com/XTLS/Xray-core) — ядро VPN
- [sing-box](https://github.com/SagerNet/sing-box) — альтернативное ядро VPN (Hysteria2)

---

## Лицензия

[Mozilla Public License 2.0](LICENSE)
