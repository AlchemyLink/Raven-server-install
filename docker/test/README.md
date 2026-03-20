# Docker: тест подписок и Xray-клиента

Стек для проверки **HTTP-подписки** (base64 → JSON или share links) и **Xray в Docker** (клиент с SOCKS).

## Быстрый тест (mock подписка + клиент)

```bash
cd docker/test
docker compose up -d --build
```

- Мок подписки: `http://127.0.0.1:18088/sub` — отдаёт base64 от `mock-sub/sample-client-config.json` (минимальный JSON: SOCKS 1080 → direct).
- Клиент Xray: SOCKS на хосте **`127.0.0.1:11080`** (контейнер `xray-client` подтягивает ту же подписку и запускает Xray).

Проверка подписки (ручной прогон скрипта в одноразовом контейнере):

```bash
docker compose run --rm -v "$(pwd)/scripts:/scripts:ro" alpine:3.20 \
  sh -c "apk add --no-cache curl jq bash >/dev/null && chmod +x /scripts/test-subscription.sh && /scripts/test-subscription.sh http://subscription-mock/sub"
```

Проверка SOCKS:

```bash
curl -x socks5h://127.0.0.1:11080 -sI --max-time 15 https://example.com
```

Остановка:

```bash
docker compose down
```

## Панель 3x-ui (Xray + БД + подписки в UI)

Отдельный compose — веб-панель, встроенный Xray и SQLite:

```bash
cd docker/test
docker compose -f docker-compose.3x-ui.yml up -d
```

Откройте в браузере **`http://127.0.0.1:2053/`** (если порт занят — смотрите логи контейнера и документацию [3x-ui](https://github.com/MHSanaei/3x-ui)).

1. Войдите (часто `admin` / `admin` — **сразу смените пароль**).
2. Создайте inbound (VLESS и т.д.).
3. Скопируйте **ссылку подписки** для клиента.

### Почему `import_sub` / `premature_eof`?

Типичные причины:

- URL подписки открывается не полностью (обрыв по таймауту, TLS, прокси).
- Подписка не base64 или не тот формат (ожидается то, что отдаёт панель).
- Блокировка или редирект без тела ответа.

Проверьте с хоста:

```bash
curl -vS --max-time 60 'https://YOUR_PANEL/sub/YOUR_TOKEN'
```

Должен прийти **текст** (часто одна строка base64). Декод:

```bash
curl -fsS 'URL' | base64 -d | head -c 200
```

### Клиент в Docker и подписка 3x-ui

Образ `xray-client` умеет брать **только JSON** из base64 (как в моке). У **3x-ui** подписка часто — **набор `vless://...` строк**, а не готовый `config.json`; такой формат нужно импортировать в приложении (v2rayN, Nekobox и т.д.) или собрать конфиг вручную.

Для проверки только «подписка отдаётся и декодится» используйте `test-subscription.sh` с URL от панели.

## Перегенерация мока `sub.b64`

После правки `mock-sub/sample-client-config.json`:

```bash
./scripts/generate-mock-subscription.sh
```

## Переменные

| Переменная        | Описание |
|-------------------|----------|
| `SUBSCRIPTION_URL` | URL для `xray-client` (по умолчанию `http://subscription-mock/sub`) |

Пример с внешней подпиской (если отдаёт **JSON в base64**):

```bash
SUBSCRIPTION_URL='https://example.com/sub/xxx' docker compose up -d --build xray-client
```
