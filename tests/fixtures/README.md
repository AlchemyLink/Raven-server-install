# Фикстуры

- **`test_secrets.yml`** — создаётся скриптом `tests/scripts/gen-reality-keys.sh` или полным прогоном `tests/run.sh`. В `.gitignore`, не коммитить.

Для ручного запуска без генерации скопируйте пример и подставьте ключи из `xray x25519`:

```bash
cp tests/fixtures/test_secrets.yml.example tests/fixtures/test_secrets.yml
# отредактируйте private_key / short_id / users
```
