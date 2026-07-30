# nanopi-edge

Edge-роутер на **NanoPi R3S LTS** (Armbian): устройство ставится в разрыв между
кабелем провайдера и домашним роутером. На краю — **sing-box** (TUN + VLESS+Reality),
минимальный NAT и dual-serve на LAN (DHCP + PPPoE-server).

```text
ISP (DHCP или PPPoE ± VLAN)
  → WAN NanoPi          sing-box · ip_forward · MASQUERADE
  → LAN NanoPi 10.10.10.1/24   DHCP и/или PPPoE-server (accept-any)
  → WAN домашнего роутера
  → LAN роутера → клиенты
```

Белый IP остаётся на NanoPi. Double NAT здесь нормален: роутер «видит» NanoPi
как провайдера.

## Возможности

- Выборочный прокси: remote ruleset’ы + домены → VLESS, остальное — direct
- Несколько VLESS+Reality узлов, переключение через clash_api / CLI / WebUI
- DNS: AdGuard DoH в sing-box; dnsmasq на LAN → AdGuard
- WAN к ISP: **DHCP** или **PPPoE** (логин/пароль, опциональный VLAN) — CLI и WebUI
- LAN к роутеру: одновременно DHCP и PPPoE-server (accept-any) — роутер может
  оставаться в своём WAN-режиме
- Лёгкая веб-панель (Go + HTMX): статус, WAN, логи, proxy, домены, проброс портов, конфиг
- Установщики: один файл `install-singbox.sh` (на плате пишет `/opt/nanopi-edge/scripts/`)

**Не цель проекта:** тяжёлый firewall, WireGuard как основной транспорт,
IPv6 в первой итерации, раздача белого IP роутеру (passthrough).

## Железо и ОС

|                 |                              |
| --------------- | ---------------------------- |
| Плата           | NanoPi R3S LTS (2× Ethernet) |
| ОС              | Armbian (Debian), aarch64    |
| Порты (типично) | WAN = `end0`, LAN = `enp1s0` |
| Сеть на плате   | netplan → systemd-networkd   |

## Быстрый старт

### 1. Edge (sing-box)

На **чистой** Armbian, пока WAN NanoPi в LAN домашнего роутера (lab, есть
интернет и SSH):

```bash
scp install-singbox.sh root@<lab-ip>:
ssh root@<lab-ip>
bash install-singbox.sh
```

Скрипт интерактивный: пакеты (`ppp`/`pppoe` и др.), sing-box, мастер VLESS,
приёмочные тесты. Врезку ISP **не** делает — в конце печатает чеклист кабелей и
`/opt/nanopi-edge/scripts/router-on`.

**Повторный запуск безопасен (upgrade):** обновляет scripts/пакеты/бинарь,
не гасит dnsmasq/nftables в router-режиме, по умолчанию не трогает
`config.json`. Без вопросов (WebUI / cron): `NANOPI_YES=1 bash install-singbox.sh`.

После успеха `install-singbox.sh` можно удалить. Остаётся:

```text
/opt/nanopi-edge/.env
/opt/nanopi-edge/scripts/{router-on,lab-on,wan-dhcp,wan-pppoe,wan-status,proxy-select,common.sh}
/etc/sing-box/config.json
```

### 2. Врезка (вручную)

1. У клиентов роутера: gateway/DNS = сам роутер (не старый прокси/VM).
2. `/opt/nanopi-edge/scripts/router-on` — LAN dual-serve + WAN DHCP.
3. Кабели: ISP → WAN NanoPi; LAN NanoPi → WAN роутера.
4. WAN роутера: DHCP → `10.10.10.x`, шлюз `10.10.10.1`, **или** PPPoE с любыми
   кредами (NanoPi принимает).
5. Если у ISP на NanoPi нужен PPPoE: панель `http://10.10.10.1/` или
   `wan-pppoe <user> <pass> [vlan]`. Откат: `wan-dhcp`.
6. SSH / панель: `root@10.10.10.1`, `http://10.10.10.1/`.

Если панель недоступна с LAN роутера до поднятия его WAN — ноут патчкордом в
LAN NanoPi.

Откат lab: ISP обратно в WAN роутера, NanoPi WAN в LAN роутера,
`/opt/nanopi-edge/scripts/lab-on`.

### 3. WebUI (опционально)

Нужен уже установленный edge. Репозиторий релизов задаётся в
`/opt/nanopi-edge/.env` как `WEBUI_GITHUB_REPO` (пишет `install-singbox.sh`,
по умолчанию `burzilov/nanopi-edge`):

```bash
scp install-webui.sh root@10.10.10.1:
ssh root@10.10.10.1
bash install-webui.sh
```

Панель: `http://10.10.10.1/` (без auth — доверяй только LAN).
На статусе — переключатель WAN DHCP|PPPoE, креды, VLAN; пароль ISP в
`/etc/ppp/nanopi-wan.secret` (0600). В шапке — версия и «Обновления».

Проброс 80/443 на NPM (и др.) — страница **Порты** в панели
(`/opt/nanopi-edge/port-forwards.json` + nft). Если dest за домашним роутером
(`192.168.1.x`), задай там же маршрут home_net / home_via.

## Репозиторий

| Путь                 | Назначение                                           |
| -------------------- | ---------------------------------------------------- |
| `install-singbox.sh` | Одноразовая установка edge (+ вшитые scripts/)       |
| `lab/`               | Fake ISP/CPE и чеклист PPPoE-стенда                  |
| `install-webui.sh`   | Установка панели с GitHub Release                    |
| `release.sh`         | Patch-релиз: `VERSION` ↑, commit, tag, push          |
| `webui/`             | Исходники панели (Go)                                |
| `.github/workflows/` | Сборка `nanopi-webui-linux-arm64.tar.gz` на тег `v*` |
| `VERSION`            | Текущая версия релиза                                |

Секреты (UUID, Reality keys, белые IP, боевой `config.json`, пароль PPPoE)
в git **не** хранятся. Они появляются только на плате при установке / в UI /
в `.env` на устройстве.

## Управление на хосте

```bash
# профиль сети
/opt/nanopi-edge/scripts/router-on
/opt/nanopi-edge/scripts/lab-on
/opt/nanopi-edge/scripts/wan-dhcp
/opt/nanopi-edge/scripts/wan-pppoe <user> <pass> [vlan]
/opt/nanopi-edge/scripts/wan-status | jq .

# обновить edge (scripts/бинарь; config.json не трогает)
# NANOPI_YES=1 bash install-singbox.sh
# или из панели «Статус» → «Проверить обновления» → «Обновить»

# активный VLESS в selector «proxy»
/opt/nanopi-edge/scripts/proxy-select get
/opt/nanopi-edge/scripts/proxy-select set vless-germany

# сервисы
systemctl status sing-box
systemctl status nanopi-pppoe-server
systemctl status nanopi-wan-pppoe   # только в режиме WAN PPPoE
systemctl status nanopi-webui       # если ставил UI
journalctl -u sing-box -f
```

Lab без PPPoE у домашнего ISP: [`lab/CHECKLIST.md`](lab/CHECKLIST.md).

## Разработка WebUI

```bash
cd webui
make build          # → dist/nanopi-webui
make build-arm64    # кросс для платы
```

Подробности: [`webui/README.md`](webui/README.md).

Релиз:

```bash
./release.sh --dry-run
./release.sh          # например 0.0.0 → 0.0.1, tag v0.0.1, push
```

Actions соберёт артефакт и приложит к GitHub Release.

## Лицензия

Код в этом репозитории — для личного/домашнего использования и изучения.
Проверяй лицензии зависимостей (sing-box, ruleset’ы третьих сторон) отдельно.
