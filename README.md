# nanopi-edge

Edge-роутер на **NanoPi R3S LTS** (Armbian, aarch64) или **x86_64-мини-ПК** с двумя
Ethernet (Debian 12/13, напр. Intel N100): устройство ставится в разрыв между
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

|                 | NanoPi                       | x86_64 (напр. N100)                        |
| --------------- | ---------------------------- | ------------------------------------------ |
| Железо          | NanoPi R3S LTS (2× Ethernet) | мини-ПК с 2× Ethernet                       |
| ОС              | Armbian (Debian), aarch64    | Debian 12/13, amd64                         |
| Порты (типично) | WAN = `end0`, LAN = `enp1s0` | WAN = `enp1s0`, LAN = `enp2s0` (как найдёт) |
| Сеть            | netplan → systemd-networkd   | ifupdown (`/etc/network/interfaces`) + dhcpcd |
| Ассет панели    | `nanopi-webui-linux-arm64`   | `nanopi-webui-linux-amd64`                  |

Другие архитектуры (armv7, i386, …) не поддерживаются: `install-webui.sh` скажет об
этом сразу.

### Интерфейсы WAN/LAN

Имена не зашиты. Порядок выбора (`install-singbox.sh`, а при пустом `.env` — и `scripts/`):

1. `NANOPI_WAN_IF` / `NANOPI_LAN_IF` в окружении установщика;
2. `WAN_IF` / `LAN_IF` из `/opt/nanopi-edge/.env` (upgrade);
3. автоопределение: **WAN** = интерфейс маршрута по умолчанию (lab-кабель в LAN
   домашнего роутера), кроме `ppp*`/`tun*`/`sb-*`/`wg*`; **LAN** = первый другой
   физический проводной Ethernet (`/sys/class/net/*/device`, без Wi‑Fi, мостов и
   docker).

Мастер показывает таблицу физических интерфейсов и подсказку; при свежей установке
несуществующее имя, `WAN = LAN` или один NIC без `NANOPI_LAN_IF` — остановка с
ошибкой. Итог пишется в `.env` и дальше не угадывается.

```bash
NANOPI_WAN_IF=enp1s0 NANOPI_LAN_IF=enp2s0 bash install-singbox.sh
```

### Сетевой стек: netplan или ifupdown

`router-on`, `lab-on`, `wan-dhcp`, `wan-pppoe` пишут одни и те же роли файлов в
активный стек:

| Роль | netplan (`/etc/netplan/`) | ifupdown (`/etc/network/interfaces.d/`) |
| --- | --- | --- |
| lab: WAN по DHCP в LAN роутера | `30-ethernets-dhcp.yaml` | `nanopi-30-ethernets-dhcp` |
| WAN DHCP от ISP / L2 под PPPoE | `40-router-wan-dhcp.yaml` | `nanopi-40-router-wan-dhcp` |
| WAN + VLAN под PPPoE | `45-router-wan-vlan.yaml` | `nanopi-45-router-wan-vlan` |
| LAN `10.10.10.1/24` | `50-router-lan.yaml` | `nanopi-50-router-lan` |

Определение: есть `netplan` и `/etc/netplan/*.yaml` → **netplan** (NanoPi — как
раньше, без изменений); активен NetworkManager → **стоп** (не поддерживается);
есть `/etc/network/interfaces` и `ifup` → **ifupdown**. Принудительно:
`NET_STACK=netplan|ifupdown` (окружение установщика → запишется в `.env`).

ifupdown (Debian без netplan):

- в `/etc/network/interfaces` стензы WAN/LAN (и `WAN.*`) комментируются префиксом
  `#nanopi-edge# `, `iface WAN inet6 …` остаётся; оригинал один раз сохраняется в
  `/etc/network/interfaces.nanopi-orig`; добавляется `source /etc/network/interfaces.d/*`;
- перед каждой сменой профиля — снимок `/etc/network/interfaces` + `interfaces.d/` в
  `/var/backups/nanopi-edge/net-*` (хранятся 10 последних);
- переподнимаются **только** интерфейсы, чья стенза изменилась: в lab WAN по DHCP
  совпадает с дефолтом Debian, поэтому `router-on` не рвёт SSH по WAN-кабелю;
- `ifup` упал → файлы откатываются из снимка, интерфейсы поднимаются по-старому,
  скрипт завершается с ошибкой. Таймерного авто-отката (если связь пропала, а `ifup`
  «успешен») нет — держите консоль/второй путь при первой врезке.

Ручной откат к исходному Debian:

```bash
cp /etc/network/interfaces.nanopi-orig /etc/network/interfaces
rm -f /etc/network/interfaces.d/nanopi-*
systemctl restart networking   # или ifdown/ifup нужных интерфейсов
```

DHCP-клиент для `inet dhcp`: если нет `dhcpcd`/`dhclient`/`udhcpc`, установщик
ставит `dhcpcd-base`.

### Пакеты

`install-singbox.sh` сам ставит недостающее через apt (неинтерактивно, конфиги
не перетирает): `curl jq ca-certificates nftables dnsmasq ppp pppoe openssl
iproute2 procps kmod tar gzip` (+ `dhcpcd-base` на ifupdown).
`install-webui.sh` при отсутствии ставит `curl`, `jq`, `ca-certificates`.

Если **sing-box стоит пакетом** (`dpkg`: `sing-box` / `sing-box-beta`) — свежая
установка предупреждает и останавливается: пакетный `/usr/bin/sing-box` и его unit
конфликтуют с нашим `/usr/local/bin/sing-box`. Удалить пакет: вручную
`apt-get remove sing-box`, ответ «да» в мастере или `NANOPI_REMOVE_SINGBOX_PKG=1`
(`remove`, не `purge`; `/etc/sing-box` предварительно копируется в
`/etc/sing-box.bak-*`). При upgrade уже работающей установки — только предупреждение.

PPPoE-клиент: плагин pppd выбирается по наличию — `pppoe.so` (ppp ≥ 2.5, Debian 13)
или `rp-pppoe.so` (старые ppp, Armbian на bookworm).

### SSH с WAN

`router-on` (и upgrade в router-режиме) пишет в `/etc/nftables.conf` цепочку
`input`: **новые** TCP-соединения на порт(ы) sshd с WAN и `ppp0` — `drop`
(порты из `sshd -T`, иначе 22). Уже открытая сессия не рвётся, остальной входящий
трафик не меняется (policy accept). После врезки заходить с LAN:
`ssh root@10.10.10.1`. `router-on` предупреждает, если текущая SSH-сессия идёт
через WAN.

Оставить SSH с WAN открытым (на свой риск; лучше ключи и нестандартный порт):
`SSH_ALLOW_WAN=1` в `/opt/nanopi-edge/.env`, затем `router-on` (или
`SSH_ALLOW_WAN=1` в окружении установщика). Проверка: `nft list chain inet filter input`.

## Быстрый старт

### 1. Edge (sing-box)

На **чистой** Armbian (NanoPi) или Debian 12/13 (x86_64), пока WAN в LAN домашнего роутера (lab, нужны
**интернет и SSH**). Установщик скачивает `nanopi-edge-scripts.tar.gz` с GitHub
Release — для первой установки нужен уже опубликованный тег с этим ассетом.

```bash
scp install-singbox.sh root@<lab-ip>:
ssh root@<lab-ip>
bash install-singbox.sh
```

Скрипт интерактивный: пакеты (`ppp`/`pppoe` и др.), sing-box, hairpin DNS
(шаг 6b, опционально), мастер VLESS, приёмочные тесты. Врезку ISP **не** делает —
в конце печатает чеклист кабелей и `/opt/nanopi-edge/scripts/router-on`.

**Узлы VLESS — ссылкой из 3x-ui.** В 3x-ui: Inbounds → клиент → «Копировать
ссылку», вставить в мастер целиком:

```text
vless://UUID@host:port?type=tcp&security=reality&pbk=…&fp=chrome&sni=…&sid=…&spx=%2F&flow=xtls-rprx-vision#remark
```

Мастер разберёт адрес, порт, UUID, `pbk`/`sni`/`sid`, `fp`, `flow`, покажет
сводку (UUID и ключ замаскированы) и спросит подтверждение; имя узла по умолчанию —
из `#remark` (латиница/цифры/дефис, префикс `vless-` добавится сам). Узлов можно
несколько, затем выбирается default для selector `proxy`. Enter вместо ссылки —
ввод по полям, как раньше.

- Поддерживается только **VLESS + Reality поверх TCP** (`type=tcp`/`raw`,
  `security=reality`, `encryption=none`); `pbk`, `sni`, `sid` обязательны.
  `grpc`/`ws`/`xhttp`/`httpupgrade`, `security=tls`/`none` — ошибка (шаблон их не
  умеет). `spx`, `pqv` и прочие неизвестные параметры игнорируются (видно в сводке).
- `flow`: `xtls-rprx-vision` или пусто (тогда без flow); `fp` — из ссылки
  (неизвестный → `chrome`). IPv6-адрес — в `[...]`.
- IPv4-адрес узла получает route-правило `direct`; hostname и IPv6 — нет
  (как и раньше).

Без вопросов (свежая установка / пересборка `config.json`):

```bash
NANOPI_YES=1 \
NANOPI_VLESS_LINKS='vless://…#Finland
germany vless://…' \
NANOPI_VLESS_DEFAULT=finland \
NANOPI_HAIRPIN_DNS_TARGET=192.168.1.10 \
bash install-singbox.sh
```

| Переменная | Что |
| --- | --- |
| `NANOPI_VLESS_LINKS` | ссылки по одной на строку: `vless://…` или `имя vless://…` |
| `NANOPI_VLESS_LINKS_FILE` | файл с такими строками (`#` — комментарий); лучше `0600` |
| `NANOPI_VLESS_DEFAULT` | default для `proxy` (иначе первый узел) |
| `NANOPI_HAIRPIN_DNS_TARGET` | hairpin, только если в `.env` его ещё нет |
| `NANOPI_WAN_IF` / `NANOPI_LAN_IF` | имена WAN/LAN (иначе `.env` или автоопределение) |
| `NANOPI_REMOVE_SINGBOX_PKG=1` | разрешить `apt-get remove` пакетного sing-box |
| `NET_STACK` | `netplan` \| `ifupdown` — стек сети принудительно |
| `SSH_ALLOW_WAN=1` | не закрывать SSH с WAN в nftables |

`NANOPI_YES=1` без ссылок при необходимости собрать `config.json` — понятная ошибка.

**Что происходит при установке (порядок):** скрипты и templates (`root:root`) →
пакеты через apt (в lab dnsmasq заранее `mask`, а на время apt ставится временный
`/usr/sbin/policy-rc.d` — пакеты не стартуют свои службы; файл убирается сразу после
apt) → бинарник sing-box (скачивание с повторами и строкой прогресса раз в ~10 с —
**может занять несколько минут**) → только теперь unit `sing-box` и drop-in dnsmasq
(`Requires=sing-box`) → `.env` → `config.json` → запуск. После запуска установщик
ждёт готовности до 90 с (`NANOPI_READY_TIMEOUT`): `sb-tun`, clash_api `:9090` и первый
запрос через proxy — на первом старте sing-box качает remote rule-set'ы. Не дождался —
печатает диагностику (`journalctl`, `sb-tun`, `:9090`), тесты ниже покажут, что не так.

**Приёмочные тесты** (`bash install-singbox.sh test`): proxy проверяется не по «IP ≠ WAN»
(в lab за роутером с VPN внешний IP и так чужой), а по цепочке соединения к
`api.ipify.org` в clash_api: должна быть `<узел> ← proxy`, где узел = выбранный в
selector; внешний IP дополнительно сверяется с адресом узла.

**Порт auto_redirect** (в `ss` — sing-box на `0.0.0.0:<случайный>`, напр. `39439`):
это redirect-сервер TUN. Снаружи он закрыт: sing-box сам добавляет в
`table inet sing-box` / `chain input` правило
`tcp dport <порт> ct status ! dnat reject with tcp reset` (принимаются только
перенаправленные им же соединения). После перезапуска nftables (`router-on`,
`flush ruleset`) таблица восстанавливается рестартом sing-box. Тест
`redirect-порт … закрыт снаружи` это проверяет; вручную:
`nft list chain inet sing-box input`.
При upgrade существующий `config.json` по умолчанию не трогается, ссылки не нужны.

**Hairpin DNS (шаг 6b).** Мастер спрашивает LAN IP Nginx Proxy Manager:
Enter без значения — пропустить (если уже задан — оставить), `-` — выключить.
Значение пишется в `.env` и сразу применяется (`/etc/dnsmasq.d/hairpin-alias.conf`,
перезапуск dnsmasq — только если он уже запущен и значение изменилось). При
`NANOPI_YES=1` вопросов нет: значение из `.env` не меняется, при его отсутствии
берётся `NANOPI_HAIRPIN_DNS_TARGET` (унаследованный `HAIRPIN_DNS_TARGET` из
окружения игнорируется).

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

**До `router-on`** (lab, свежая плата) адреса `10.10.10.1` на LAN ещё нет. Это
нормально: `install-webui.sh` завершается успешно и пишет «панель запущена и ждёт
адрес 10.10.10.1: он появится после router-on». Панель уже `active` (слушает с
`IP_FREEBIND`), без петли перезапусков, и сама начнёт отвечать, когда `router-on`
назначит адрес; `router-on` в конце дополнительно запускает панель, если она
установлена и не работает. Unit: `RestartSec=5s`, не больше 10 стартов за 5 минут.
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
- drop-in dnsmasq (`Requires=sing-box`), unit sing-box (оба — после бинарника),
  sysctl/conntrack, nftables;
- панель (`install-webui.sh`) можно ставить до врезки — откроется после `router-on`.

Руками:

1. Armbian (NanoPi) или Debian 12/13 amd64, доступ root по SSH (ключ); настройки sshd —
   по вкусу. SSH с WAN после `router-on` закрыт (см. «SSH с WAN»).
2. Мастер VLESS в `install-singbox.sh`: для каждого VPS — ссылка `vless://` из
   3x-ui (или поля вручную), имя узла; выбор узла по умолчанию. Hairpin — там же,
   шаг 6b: LAN IP Nginx Proxy Manager (Enter — пропустить).
3. Врезка и `router-on` (раздел 2), PPPoE-креды ISP, если нужны.
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
DNS hairpin (`HAIRPIN_DNS_TARGET` в `.env`, спрашивает `install-singbox.sh` на шаге 6b) работает
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
| `templates/`         | Шаблоны (dnsmasq, netplan, ifupdown, nftables, sing-box.config.json.tpl, …) |
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
make build          # → dist/nanopi-webui (под текущую машину)
make build-arm64    # → dist/nanopi-webui-linux-arm64 (NanoPi)
make build-amd64    # → dist/nanopi-webui-linux-amd64 (x86_64)
make build-all      # оба
./dist/nanopi-webui --version   # nanopi-webui vX.Y.Z linux/amd64
```

Тесты: `bash tests/*.test.sh` (без root и платы: сетевой слой, установщики),
`cd webui && go vet ./... && go test ./...`.

Подробности: [`webui/README.md`](webui/README.md).

Релиз:

```bash
./release.sh --dry-run
./release.sh          # например 0.0.0 → 0.0.1, tag v0.0.1, push
```

Actions прогонит `go vet`/`go test`, соберёт артефакты (`nanopi-webui-linux-amd64.tar.gz`,
`nanopi-webui-linux-arm64.tar.gz`, `nanopi-edge-scripts.tar.gz`, `install-singbox.sh`,
`install-webui.sh`) и приложит к GitHub Release. Панель и `install-webui.sh` берут
архив своей архитектуры (`runtime.GOARCH` / `uname -m`).

## Лицензия

Код в этом репозитории — для личного/домашнего использования и изучения.
Проверяй лицензии зависимостей (sing-box, ruleset’ы третьих сторон) отдельно.
