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
- **Мобильный VLESS+Reality** (TCP/8443): один Hiddify-профиль, трафик через те же route-правила
- DNS: клиенты → `10.10.10.1` (dnsmasq) → AdGuard `94.140.14.14/15.15:53`, перехват в sing-box (hijack-dns) → AdGuard DoH через proxy (фолбэк — напрямую); hairpin alias в dnsmasq
- WAN к ISP: **DHCP** или **PPPoE** (логин/пароль, опциональный VLAN) — CLI и WebUI
- LAN к роутеру: одновременно DHCP и PPPoE-server (accept-any) — роутер может
  оставаться в своём WAN-режиме
- Лёгкая веб-панель (Go + HTMX): статус, WAN, логи, proxy, домены, мобильный VLESS, проброс портов, конфиг; светлая и тёмная тема (авто по системе), без внешних зависимостей
- Установщики: `install-singbox.sh` + scripts bundle из GitHub Release (`nanopi-edge-scripts.tar.gz`)

**Не цель проекта:** тяжёлый firewall, WireGuard как основной транспорт,
IPv6 в первой итерации, раздача белого IP роутеру (passthrough).

## DNS

Клиенты с дефолтными настройками (DHCP/PPPoE от NanoPi) получают **DNS = 10.10.10.1**.
Дальше цепочка такая:

```text
клиент → 10.10.10.1:53 (dnsmasq: кеш, DHCP-имена, hairpin)
       → server=94.140.14.14 / 94.140.15.15 (UDP/53)
       → TUN sing-box: route «port 53 → hijack-dns» (запрос не уходит в сеть как есть)
       → dns.rules:
           домены из списка прокси, geosite ru-blocked / category-ai-!cn / telegram
                                   → dns-proxy  (AdGuard DoH 94.140.14.14, SNI dns.adguard-dns.com, detour proxy)
           .ru / .su / .рф (xn--p1ai) → dns-direct (тот же AdGuard DoH напрямую)
           всё остальное            → evaluate dns-proxy (таймаут 3 с):
                                      NOERROR/NXDOMAIN → ответ; ошибка/таймаут/SERVFAIL → dns-direct
```

- Список доменов прокси один: `domain_suffix` route-правила `outbound=proxy`.
  Инсталлятор копирует его в DNS-правило `server=dns-proxy`, панель **Домены** при
  сохранении обновляет оба места.
- В DNS-правилах нет geoip-наборов (ответ ещё неизвестен на момент выбора сервера).
- Резолв доменов самих outbound'ов (VLESS-узлы, rule-set) — `route.default_domain_resolver: dns-direct`.
- DoH/DoT клиентов LAN напрямую на IP AdGuard/Quad9 (`94.140.14.14/15.15`, `9.9.9.9`, порт 443)
  идёт через proxy; порт 853 (DoT) режется, чтобы клиенты откатывались на обычный DNS.

**dnsmasq ↔ sing-box.** Drop-in `/etc/systemd/system/dnsmasq.service.d/sing-box.conf`:
`After=sing-box.service` + `Requires=sing-box.service`. На `Wants=` **не** менять:
`ExecStartPost` unit'а sing-box синхронно делает `systemctl try-restart dnsmasq`, а
dnsmasq ждёт sing-box (`After=`) — запуск взаимно блокируется, sing-box висит в
`activating`, в LAN нет DNS и DHCP. Следствия `Requires=`:

- `systemctl stop sing-box` останавливает и dnsmasq — **в LAN пропадают DNS и DHCP**.
  «Аварийного пути» (sing-box выключен → dnsmasq ходит в AdGuard напрямую) штатно нет.
- `systemctl restart sing-box` перезапускает и dnsmasq (это нормально, кеш сбрасывается).
- Если sing-box не стартует, dnsmasq тоже не стартует. Чинить конфиг: `sing-box check -c
  /etc/sing-box/config.json`, откат на бэкап `config.json.bak.*`, затем
  `systemctl restart sing-box dnsmasq`.

Если нужно временно жить **без** sing-box (DNS напрямую в AdGuard `94.140.14.14/15.15:53`,
без прокси и без DoH), сначала снять зависимость:

```bash
mkdir -p /root/dnsmasq-dropin-off
mv /etc/systemd/system/dnsmasq.service.d/sing-box.conf /root/dnsmasq-dropin-off/
systemctl daemon-reload && systemctl stop sing-box && systemctl restart dnsmasq
dig @10.10.10.1 ya.ru +short
# вернуть:
mv /root/dnsmasq-dropin-off/sing-box.conf /etc/systemd/system/dnsmasq.service.d/
systemctl daemon-reload && systemctl restart sing-box
```

Локальные подмены (hairpin для Nginx Proxy Manager) по-прежнему в **dnsmasq**
(`hairpin-alias.conf`), до форварда в upstream: общий `alias=` (белый IP → NPM) и
исключения `address=/имя/адрес` (имя и поддомены → свой адрес, например NAS).

Upstream и failover sing-box правятся в `/etc/sing-box/config.json` (панель **Конфиг** или
вручную) → `sing-box check` → перезапуск sing-box; dnsmasq перезапустится сам
(`ExecStartPost` в unit sing-box) и сбросит кеш.

Upgrade (`install-singbox.sh` повторно) по умолчанию **не** трогает ни
`/etc/sing-box/config.json`, ни `/etc/dnsmasq.d/lan.conf` (его пишет только `router-on`).
Свежая установка (мастер + `router-on`) сразу даёт эту схему. Конфиг со старой схемой
(`server=127.0.0.1#5353` + inbound `dns-in`) нельзя пересобирать мастером, оставив
старый `lan.conf`: `config.json` и `lan.conf` меняются только вместе.

## Железо и ОС

|                 |                              |
| --------------- | ---------------------------- |
| Плата           | NanoPi R3S LTS (2× Ethernet) |
| ОС              | Armbian (Debian), aarch64    |
| Порты (типично) | WAN = `end0`, LAN = `enp1s0` |
| Сеть на плате   | netplan → systemd-networkd   |

## Быстрый старт

### 1. Edge (sing-box)

На **чистой** Armbian, пока WAN NanoPi в LAN домашнего роутера (lab, нужны
**интернет и SSH**). Установщик скачивает `nanopi-edge-scripts.tar.gz` с GitHub
Release — для первой установки нужен уже опубликованный тег с этим ассетом.

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
/opt/nanopi-edge/hairpin-overrides.json   # если заданы исключения hairpin (webui)
/opt/nanopi-edge/scripts/{router-on,lab-on,wan-dhcp,wan-pppoe,wan-status,proxy-select,hairpin-dns-refresh,inbound-status,common.sh}
/opt/nanopi-edge/templates/
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

Установщик панели заодно выставляет в `.env` метку `EDGE_VERSION` = тег
поставленного релиза (не понижает её и не трогает остальные переменные).

Панель: `http://10.10.10.1/` (без auth — доверяй только LAN).
На статусе — переключатель WAN DHCP|PPPoE, креды, VLAN; пароль ISP в
`/etc/ppp/nanopi-wan.secret` (0600). В шапке — версия и «Обновления».

### 4. Новая плата: что автоматически, а что руками

Автоматически (`install-singbox.sh` + `router-on`):

- `/etc/dnsmasq.d/lan.conf` с `server=94.140.14.14` / `server=94.140.15.15` (без `:5353`);
- `/etc/sing-box/config.json` с DNS `dns-proxy` (AdGuard DoH через proxy) / `dns-direct`
  (фолбэк и `.ru/.su/.рф`), без `dns-in`;
- IPv4 VLESS-узлов — одно отдельное route-правило `direct` (не в reject/DNS-правилах);
- список доменов прокси один: route `outbound=proxy` → DNS-правило `dns-proxy`
  (и при сохранении в панели **Домены**);
- drop-in dnsmasq (`Requires=sing-box`), unit sing-box, sysctl/conntrack, nftables.

Руками:

1. Armbian, доступ root по SSH (ключ); настройки sshd — по вкусу.
2. Мастер VLESS в `install-singbox.sh`: для каждого VPS — адрес, порт, UUID,
   Reality public key, short_id, SNI; выбор узла по умолчанию.
3. Врезка и `router-on` (раздел 2), PPPoE-креды ISP, если нужны; hairpin —
   `HAIRPIN_DNS_TARGET=<IP NPM>` в `/opt/nanopi-edge/.env` (если не задан) и
   `scripts/hairpin-dns-refresh`.
4. `install-webui.sh`; в панели — проброс портов и исключения hairpin
   (или перенести `/opt/nanopi-edge/port-forwards.json`, `hairpin-overrides.json`
   со старой платы).
5. Мобильный VLESS — новый профиль в панели (новый QR для телефона). Чтобы оставить
   старый профиль: перенести `/etc/sing-box/inbound-vless-reality.json` (`0600`) до
   запуска мастера — inbound `vless-mobile` восстановится сам.
6. Свои правила маршрутизации (личные IP/подсети → proxy/direct) — панель **Конфиг**;
   в шаблоне их нет.
7. Диагностические пакеты по желанию: `apt install dnsutils tcpdump htop rsync`.

### Проброс портов

Страница панели **Проброс портов** (`/port-forwards`): таблица правил
вкл/выкл · протокол TCP/UDP/оба · внешний порт · внутренний IP · внутренний порт ·
комментарий; добавление, правка, выключение, удаление. Хранится в
`/opt/nanopi-edge/port-forwards.json` (формат прежний, новые поля опциональны),
применяется в `/etc/nftables.d/nanopi-port-forwards.nft` — это отдельная таблица
`inet nanopi_portforward`, которую `nft -f` пересоздаёт атомарно (`add`/`delete table`
в начале файла). Остальной ruleset и sing-box **не** перезапускаются, проверка
`nft -c` до применения; при ошибке старые файлы возвращаются. После перезагрузки
правила поднимаются через `include` в `/etc/nftables.conf`.

- Внутренний IP — WAN-адрес домашнего роутера (Keenetic): он единственный клиент
  NanoPi в `10.10.10.0/24`, других устройств за NanoPi нет. Дальше (на NAS и т.п.)
  порты пробрасываются на самом роутере. Поля `home_net`/`home_via` старых версий
  игнорируются (маршрута и masquerade в домашнюю сеть больше нет).
- Столбец **«Подключений / трафик»** — nft-счётчики правила (новые соединения
  в DNAT и байты обоих направлений в forward); обнуляются при каждом применении.
- **Ограничение частоты подключений** с WAN: новые соединения с одного IP на все
  проброшенные порты, по умолчанию 120/мин с запасом 240 (с запасом под Synology
  Photos/Drive и CGNAT). Лишние отбрасываются и считаются (`pf_ratelimit_drop`),
  опционально пишутся в журнал с префиксом `nanopi-pf-ratelimit:` (не чаще 6/мин):
  `journalctl -k | grep nanopi-pf-ratelimit`. Действует только на WAN-интерфейсах,
  LAN и hairpin не трогает.
- При старте панель сама переписывает nft-файл, если он не совпадает с JSON
  (обновление формата, смена WAN-интерфейса).
- `GET /api/port-forwards` — правила, действующий лимит и счётчики.

Проброс 80/443 на Nginx Proxy Manager — обычные правила на странице **Проброс
портов** (на роутер; комментарий `nginx-proxy-manager` остался от прежней страницы
`/proxy-manager`, которая теперь редиректит сюда), а с роутера — на NPM.
DNS hairpin (`HAIRPIN_DNS_TARGET` в `.env`, ставится `install-singbox.sh`) работает
как раньше; адрес подмены меняется или отключается в блоке **DNS hairpin** на
странице **Проброс портов** (сохраняет `.env` и запускает `hairpin-dns-refresh`). На Keenetic: DNS клиентов = `10.10.10.1`.
Там же — **исключения** «имя → адрес»: имя и его поддомены из дома ведут не на NPM,
а на указанный IPv4 (например `nas.example.org → 192.168.1.90`, чтобы DSM :5001
открывался на NAS). Хранятся в `/opt/nanopi-edge/hairpin-overrides.json` (не в
`.env`, переживают переустановку), до 50 штук, в dnsmasq — строки
`address=/имя/адрес`, которые срабатывают раньше `alias=` и работают даже при
выключенной общей подмене. Нужны webui и скрипты одной версии: старый
`hairpin-dns-refresh` исключений не знает, панель покажет «не применено».

### Мобильный VLESS (Hiddify)

Страница панели **Мобильный VLESS**: входящий VLESS+Reality на отдельном TCP-порте
(по умолчанию `8443`; `80`/`443` остаются у NPM). Один профиль для телефона.

1. **Создать профиль** — метка и порт (ключи Reality и UUID; inbound ещё не слушает).
2. Выбрать/проверить маскировочный TLS-сайт → **Сохранить и включить**.
3. **Показать URI и QR** → импорт в Hiddify.
4. Проверка из домашнего Wi‑Fi, затем с выключенным Wi‑Fi (мобильная сеть).

Трафик телефона идёт по тем же правилам sing-box (proxy / direct), что и домашний TUN.
Секреты: `/etc/sing-box/inbound-vless-reality.json` (`0600`), не в git. При явной
пересборке `config.json` мастером inbound восстанавливается из этого файла.
Панель без auth: любой с доступом к `http://10.10.10.1/` может выдать/отозвать профиль —
не слушайте WebUI на WAN. Диагностика без секретов:
`/opt/nanopi-edge/scripts/inbound-status | jq .`

## Репозиторий

| Путь                 | Назначение                                           |
| -------------------- | ---------------------------------------------------- |
| `install-singbox.sh` | Установка / upgrade edge (скачивает scripts bundle)    |
| `scripts/`           | Операционные скрипты (в релизе: `nanopi-edge-scripts.tar.gz`) |
| `templates/`         | Шаблоны (dnsmasq, netplan, sing-box.config.json.tpl, …) |
| `lab/`               | Fake ISP/CPE и чеклист PPPoE-стенда                  |
| `install-webui.sh`   | Установка панели с GitHub Release                    |
| `tests/`             | Shell-тесты установщиков (`bash tests/*.test.sh`)     |
| `release.sh`         | Patch-релиз: `VERSION` ↑, commit, tag, push          |
| `webui/`             | Исходники панели (Go)                                |
| `.github/workflows/` | Сборка артефактов на тег `v*` (webui, scripts, установщики) |
| `VERSION`            | Текущая версия релиза                                |

Ядро: `templates/99-nanopi-forward.conf` (forwarding, `nf_conntrack_max=65536`,
TCP established 7200 с) и conntrack `hashsize=16384`
(`/etc/modprobe.d/nanopi-conntrack.conf` + запись в `/sys` без перезагрузки,
`nf_conntrack` в `/etc/modules-load.d/`) ставит `install-singbox.sh` при установке и
upgrade; старый дубль `/etc/sysctl.d/98-nanopi-conntrack.conf` удаляется, если все
его значения уже есть в 99-м.

Секреты (UUID, Reality keys, белые IP, боевой `config.json`, пароль PPPoE,
`HAIRPIN_DNS_TARGET`, `hairpin-overrides.json`, `inbound-vless-reality.json`) в git **не** хранятся.

## Управление на хосте

```bash
# профиль сети
/opt/nanopi-edge/scripts/router-on
/opt/nanopi-edge/scripts/lab-on
/opt/nanopi-edge/scripts/wan-dhcp
/opt/nanopi-edge/scripts/wan-pppoe <user> <pass> [vlan]
/opt/nanopi-edge/scripts/wan-status | jq .
/opt/nanopi-edge/scripts/hairpin-dns-refresh   # если задан HAIRPIN_DNS_TARGET
/opt/nanopi-edge/scripts/inbound-status | jq . # мобильный VLESS (без секретов)

# DNS клиентов (dnsmasq → AdGuard:53 → перехват sing-box)
dig @10.10.10.1 google.com +short
journalctl -u sing-box -n 50 | grep -i dns   # какой сервер (dns-proxy/dns-direct) ответил

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

Actions соберёт артефакты (`nanopi-webui-linux-arm64.tar.gz`, `nanopi-edge-scripts.tar.gz`, установщики) и приложит к GitHub Release.

## Лицензия

Код в этом репозитории — для личного/домашнего использования и изучения.
Проверяй лицензии зависимостей (sing-box, ruleset’ы третьих сторон) отдельно.
