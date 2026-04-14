# Тесты конфигурации Xray (роль Ansible)

Проверяют **тот же сервис**, что и прод: переменные из `roles/xray/defaults/main.yml` + секреты, задачи **`validate.yml`**, рендер **`templates/conf/*.j2`** в каталог как на сервере (`conf.d`), затем **`xray -test -confdir`** в Docker.

## Требования

- `ansible-playbook` (ansible-core)
- `curl`, `unzip`, `openssl` (для `gen-reality-keys.sh`)
- Docker (для шага `xray -test`); без Docker: `SKIP_XRAY_TEST=1 ./tests/run.sh` — только Ansible

## Запуск

Из корня репозитория:

```bash
chmod +x tests/run.sh tests/scripts/gen-reality-keys.sh
./tests/run.sh
```

Зафиксированный результат последнего прогона: [LAST_RUN.md](LAST_RUN.md).

Скрипт:

1. Скачивает Xray (кэш в `tests/.cache/`), выполняет `xray x25519`, пишет `tests/fixtures/test_secrets.yml` (в `.gitignore`).
2. Запускает `playbooks/validate_vars.yml` — импорт `roles/xray/tasks/validate.yml`.
3. Рендерит все шаблоны `roles/xray/templates/conf/*/*.j2` в `tests/.output/conf.d/`.
4. Собирает образ из `docker/test/xray-client` (если ещё нет) и выполняет `xray -test -confdir /etc/xray/config.d`.

Только Ansible (без Docker):

```bash
SKIP_XRAY_TEST=1 ./tests/run.sh
```

Отдельные шаги:

```bash
export ANSIBLE_CONFIG="${PWD}/tests/ansible.cfg"
tests/scripts/gen-reality-keys.sh > tests/fixtures/test_secrets.yml
ansible-playbook tests/playbooks/validate_vars.yml
export RAVEN_TEST_CONF_DIR="${PWD}/tests/.output/conf.d"
mkdir -p "$RAVEN_TEST_CONF_DIR"
ansible-playbook tests/playbooks/render_conf.yml
```

## Структура

| Путь | Назначение |
|------|------------|
| `playbooks/validate_vars.yml` | Проверки из роли |
| `playbooks/render_conf.yml` | Рендер `conf.d` |
| `fixtures/test_secrets.yml.example` | Пример секретов |
| `fixtures/render_overrides.yml` | Логи в `/tmp/...`, чтобы `xray -test` не требовал `/var/log/Xray`; без `geosite.dat`/`geoip.dat` в CI задано `xray_direct_ru_enabled: false`, иначе маршрутизация с `geosite:`/`geoip:` падает на «failed to open file: geosite.dat». |
| `scripts/gen-reality-keys.sh` | Генерация валидных ключей Reality (`xray x25519`) |

Рендер **не включает** `templates/conf/users/*.j2` — в роли `users.yml` по умолчанию отключён; фрагменты users только дополняют inbounds по tag вместе с основными файлами, отдельно для `-test` дают ошибку «no Port set».

## CI

Workflow `.github/workflows/xray-config-test.yml` — Ansible + установка Xray на runner + `./tests/run.sh`.

## CI

Пример (GitHub Actions): установить Docker и Ansible, выполнить `./tests/run.sh`.
