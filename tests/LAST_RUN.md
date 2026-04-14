# Результат последнего прогона `./tests/run.sh`

| Поле | Значение |
|------|----------|
| Дата | 2026-04-14 |
| Команда | `./tests/run.sh` (из корня `Raven-server-install`) |
| Код выхода | 0 (успех) |
| `xray -test` | Локальный бинарь `/usr/local/sbin/xray` (Xray 26.3.27 linux/amd64), Docker не использовался |

## Шаги

1. Генерация `fixtures/test_secrets.yml` и `fixtures/bridge_test_secrets.yml` — OK  
2. `ansible-playbook playbooks/validate_vars.yml` — OK (11 задач, 1 пропуск)  
3. `ansible-playbook playbooks/render_conf.yml` — OK  
4. `ansible-playbook playbooks/render_bridge_conf.yml` — OK  
5. `xray -test` для `tests/.output/conf.d` и `tests/.output/bridge.conf.d` — **Configuration OK**

## Ограничение

Этот сценарий **не** проверяет роль `monitoring` (Grafana, VictoriaMetrics, blackbox). Для неё нужен отдельный деплой или ручная проверка шаблонов.

---

*Обновляйте этот файл после значимых локальных прогонов или копируйте вывод CI.*