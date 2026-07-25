# nanopi-edge

Edge-роутер на **NanoPi R3S LTS** (Armbian): устройство ставится в разрыв между
кабелем провайдера и домашним роутером. На краю — **sing-box** (TUN + VLESS+Reality),
минимальный NAT и DHCP для WAN домашнего роутера.

```text
ISP (белый IP)
  → WAN NanoPi          sing-box · ip_forward · MASQUERADE · DHCP LAN
  → LAN NanoPi 10.10.10.1/24
  → WAN домашнего роутера (серый 10.10.10.x)
  → LAN роутера 192.168.1.0/24 → клиенты
```

Белый IP остаётся на NanoPi. Double NAT здесь нормален: роутер «видит» NanoPi
как провайдера.

## Возможности

- Выборочный прокси: remote ruleset’ы + домены → VLESS, остальное — direct
- Несколько VLESS+Reality узлов, переключение через clash_api / CLI / WebUI
- DNS: AdGuard DoH в sing-box; dnsmasq на LAN → AdGuard
- Лёгкая веб-панель (Go + HTMX): статус, логи, proxy, домены, редактор конфига
- Одноразовые установщики: скопировал скрипт на плату — запустил

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

Скрипт интерактивный: пакеты, sing-box, мастер VLESS, приёмочные тесты.
Врезку ISP **не** делает — в конце печатает чеклист кабелей и
`/opt/nanopi-edge/scripts/router-on`.

После успеха `install-singbox.sh` можно удалить. Остаётся:

```text
/opt/nanopi-edge/.env
/opt/nanopi-edge/scripts/{router-on,lab-on,proxy-select}
/etc/sing-box/config.json
```

### 2. Врезка (вручную)

1. У клиентов роутера: gateway/DNS = сам роутер (не старый прокси/VM).
2. `/opt/nanopi-edge/scripts/router-on`
3. Кабели: ISP → WAN NanoPi; LAN NanoPi → WAN роутера.
4. WAN роутера: DHCP → `10.10.10.x`, шлюз `10.10.10.1`.
5. SSH после врезки: `root@10.10.10.1`

Откат: ISP обратно в WAN роутера, NanoPi WAN в LAN роутера,
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
В шапке — версия и кнопка «Обновления» (проверка GitHub Release и установка
через `install-webui.sh --noninteractive`).

## Репозиторий

| Путь                 | Назначение                                           |
| -------------------- | ---------------------------------------------------- |
| `install-singbox.sh` | Одноразовая установка edge                           |
| `install-webui.sh`   | Установка панели с GitHub Release                    |
| `release.sh`         | Patch-релиз: `VERSION` ↑, commit, tag, push          |
| `webui/`             | Исходники панели (Go)                                |
| `.github/workflows/` | Сборка `nanopi-webui-linux-arm64.tar.gz` на тег `v*` |
| `VERSION`            | Текущая версия релиза                                |

Секреты (UUID, Reality keys, белые IP, боевой `config.json`) в git **не**
хранятся. Они появляются только на плате при установке.

## Управление на хосте

```bash
# профиль сети
/opt/nanopi-edge/scripts/router-on
/opt/nanopi-edge/scripts/lab-on

# активный VLESS в selector «proxy»
/opt/nanopi-edge/scripts/proxy-select get
/opt/nanopi-edge/scripts/proxy-select set vless-germany

# сервисы
systemctl status sing-box
systemctl status nanopi-webui   # если ставил UI
journalctl -u sing-box -f
```

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
