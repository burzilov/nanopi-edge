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

**Проброс портов:** страница `/ports` — DNAT с WAN/ppp0 на IP в LAN.
Хранение: `/opt/nanopi-edge/port-forwards.json`, nft:
`/etc/nftables.d/nanopi-port-forwards.nft` (подключается из `/etc/nftables.conf`).

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
по очереди: edge → webui).

Или вручную после сборки на хосте:

```bash
make install
make install-unit
```

Открыть: http://10.10.10.1/

## Release

Тег `v*` → Actions собирает бинарь с `-X main.Version=<tag>` и публикует
`nanopi-webui-linux-arm64.tar.gz`.
