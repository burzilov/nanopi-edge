# NanoPi web UI

Go + `html/template` + HTMX. Слушает `WEBUI_LISTEN` из `/opt/nanopi-edge/.env`
(по умолчанию `10.10.10.1:80`). Без auth (LAN trust). clash_api только через
backend на `127.0.0.1:9090`.

Домены → proxy правятся прямо в `/etc/sing-box/config.json` (правило
`outbound=proxy` + `domain_suffix`), без отдельного `domains-proxy.json`.

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

В панели: номер версии в шапке → «Обновления» → проверка GitHub → «Установить»
(вызывает `/opt/nanopi-edge/install-webui.sh --noninteractive`).

Или вручную после сборки на хосте:

```bash
make install
make install-unit
```

Открыть: http://10.10.10.1/

## Release

Тег `v*` → Actions собирает бинарь с `-X main.Version=<tag>` и публикует
`nanopi-webui-linux-arm64.tar.gz`.
