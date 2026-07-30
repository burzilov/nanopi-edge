# NanoPi web UI

Go + `html/template` + HTMX. Слушает `WEBUI_LISTEN` из `/opt/nanopi-edge/.env`
(по умолчанию `10.10.10.1:80`). Без auth (LAN trust). clash_api только через
backend на `127.0.0.1:9090`.

На статусе: sing-box / VLESS и блок **WAN к ISP** (DHCP | PPPoE + login/password/VLAN).
API: `GET|POST /api/wan` → скрипты `wan-status` / `wan-dhcp` / `wan-pppoe`.
Пароль ISP хранится в `/etc/ppp/nanopi-wan.secret` (0600), в форму подставляется
целиком (LAN trust).

Домены → proxy правятся прямо в `/etc/sing-box/config.json` (правило
`outbound=proxy` + `domain_suffix`), без отдельного `domains-proxy.json`.

**NPM:** страница `/npm` — IP виртуалки в домашней LAN; NanoPi сам ставит
DNAT 80/443, маршрут за CPE и DNS hairpin. Пустое сохранение всё снимает.
На Keenetic: DNS = `10.10.10.1`, МЭ с `10.10.10.0/24` на NPM.

Смена VLESS на статусе пишет `default` в selector `proxy` в `config.json` и
перезапускает sing-box.

## Сборка локально

```bash
cd webui
make build          # → dist/nanopi-webui
make build-arm64    # кросс для NanoPi
```

## Установка на плату

См. корневой `install-webui.sh` (скачивает release с GitHub).
`WEBUI_GITHUB_REPO` берётся из `/opt/nanopi-edge/.env`.

```bash
bash install-webui.sh
# обновление конкретной версии:
WEBUI_VERSION=v0.0.2 bash install-webui.sh --noninteractive
```

В панели на статусе: «Проверить обновления» → при наличии релиза — «Обновить»
(скачивает `install-singbox.sh` и `install-webui.sh` из ассетов, запускает
в **отдельном процессе**: edge → webui). Страница перезагружается только когда
`/api/updates/status` = ok и обе версии (webui + EDGE_VERSION) совпали с тегом.
Прогресс: `GET /api/updates/status`, лог: `/opt/nanopi-edge/update.log`.

Или вручную после сборки на хосте:

```bash
make install
make install-unit
```

Открыть: http://10.10.10.1/

## Release

Тег `v*` → Actions собирает бинарь с `-X main.Version=<tag>` и публикует
`nanopi-webui-linux-arm64.tar.gz`.
