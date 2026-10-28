# NanoPi web UI

Go + `html/template` + HTMX. Слушает `WEBUI_LISTEN` из `/opt/nanopi-edge/.env`
(по умолчанию `10.10.10.1:80`). Без auth (LAN trust). clash_api только через
backend на `127.0.0.1:9090`.

На статусе: sing-box / VLESS и блок **WAN к ISP** (DHCP | PPPoE + login/password/VLAN).
API: `GET|POST /api/wan` → скрипты `wan-status` / `wan-dhcp` / `wan-pppoe`.
Пароль ISP хранится в `/etc/ppp/nanopi-wan.secret` (0600), в форму подставляется
целиком (LAN trust).

Домены → proxy и секция `dns` в `/etc/sing-box/config.json` правятся в панели
**Конфиг** (или вручную): домены — правило `outbound=proxy` + `domain_suffix`
(страница **Домены** пишет тот же список и в DNS-правило `server=dns-proxy`, если оно есть;
пустой список не сохраняется); DNS — `dns.servers` / `dns.rules`. Перед перезапуском — `sing-box check`.

**Проброс портов:** страница `/port-forwards` — общая таблица правил DNAT
(вкл/выкл, TCP/UDP/оба, внешний порт → внутренний IP:порт, комментарий), столбец
«Подключений / трафик» из
`nft -j list table inet nanopi_portforward` и ограничение частоты новых соединений
с одного IP на WAN (по умолчанию 120/мин, запас 240; drop + счётчик, опционально
лог `nanopi-pf-ratelimit:`). Код — `internal/portfwd`: валидация, рендер nft,
`nft -c` → атомарная запись → `nft -f` только этой таблицы (без перезапуска
sing-box/nftables), откат при ошибке. `GET /api/port-forwards` — JSON.

Все порты пробрасываются на домашний роутер (Keenetic) — единственный клиент
NanoPi в `10.10.10.0/24`; дальше (на NAS и др.) — на самом роутере. Отдельной
страницы Nginx Proxy Manager нет: правила 80/443 (комментарий `nginx-proxy-manager`)
— обычные строки таблицы, `/proxy-manager` редиректит на `/port-forwards`. Поля
`home_net`/`home_via` из старых `port-forwards.json` игнорируются.

Блок **DNS hairpin** на той же странице: адрес `HAIRPIN_DNS_TARGET` (IPv4 в
домашней сети, например `192.168.1.137`), на который dnsmasq NanoPi подменяет
белый IP в DNS-ответах (`alias=` в `/etc/dnsmasq.d/hairpin-alias.conf`), чтобы
домены на белый IP из дома открывались сразу внутри сети, а не по кругу через WAN.
Адрес действует для имени целиком, на всех портах. У нас это локальный IP Nginx Proxy
Manager за роутером (сейчас `192.168.1.137`), т.к. имена на :80/:443 должны попадать
на NPM; то же имя на другом порту (например, DSM :5001) из дома тоже пойдёт на NPM.
«Сохранить и применить»
пишет ключ в `/opt/nanopi-edge/.env` и запускает `scripts/hairpin-dns-refresh`
(перегенерация alias + `systemctl restart dnsmasq`; без скрипта — то же самое из
панели). Пустое поле или «Отключить» — ключ удаляется, alias снимается. Статус —
также в `GET /api/port-forwards` (поле `hairpin`). `POST /port-forwards/hairpin`
(`target=…`, `disable=1`).

**Исключения hairpin** (подблок «Исключения» там же): таблица «Имя → Адрес». Имя и
все его поддомены из дома резолвятся не в адрес NPM, а в указанный IPv4 — например
`nas.example.com → 192.168.1.90` (DSM на NAS). Хранение —
`/opt/nanopi-edge/hairpin-overrides.json` (`{"overrides":[{"name":…,"ip":…}]}`,
путь переопределяется `HAIRPIN_OVERRIDES`), отдельно от `.env`, поэтому установщик
его не теряет. В `hairpin-alias.conf` каждое исключение — `address=/имя/адрес`
перед `alias=`: dnsmasq отвечает на такие имена сам, не спрашивая upstream, так что
`alias=` их не переписывает; исключения применяются и при пустом
`HAIRPIN_DNS_TARGET`. Проверка: DNS-имя (ASCII/punycode, без схемы, порта и пути,
минимум два label, `*.` в начале отбрасывается), IPv4, без дублей, не больше 50.
Применение — тот же `scripts/hairpin-dns-refresh` (читает JSON через `jq`); при
ошибке файл откатывается. `POST /port-forwards/hairpin/override/add`
(`name`, `ip`) и `POST /port-forwards/hairpin/override/delete` (`name`); список —
в `GET /api/port-forwards` → `hairpin.overrides` (с флагом `applied`).

**Мобильный VLESS:** страница `/mobile-vless` — сначала создание профиля (метка + порт),
затем маскировочный сайт и включение inbound (TCP/8443). Секреты в
`/etc/sing-box/inbound-vless-reality.json` (`0600`). URI/QR — только по кнопке
«Показать URI и QR» (`Cache-Control: no-store`). `GET /api/mobile-vless` — статус
без UUID/ключей/URI. Панель без auth (LAN trust): не открывайте WebUI в интернет.

Смена VLESS на статусе пишет `default` в selector `proxy` в `config.json` и
перезапускает sing-box.

## Оформление и тема

Стили — один файл `static/app.css` без внешних шрифтов, CDN и картинок (иконки —
inline SVG в шаблонах, шрифт системный, адреса и порты — моноширинным). Цвета,
радиусы, тени и отступы заданы CSS-переменными (`--bg`, `--surface`, `--fg`,
`--muted`, `--accent`, `--danger`, `--ok-bg`/`--ok-fg`, …) в `:root`; тёмная тема
переопределяет те же переменные.

Каркас как у типовых админ-панелей: слева меню с иконками и группами разделов
(внизу — версия и переключатель темы), сверху — полоса с названием раздела и
кнопкой «Перезапустить sing-box», контент — на всю ширину окна (до 1600px,
`--content-max`). Уже 960px меню прячется и открывается кнопкой-бургером
(`static/nav.js`: подсветка текущего раздела, название раздела в верхней полосе,
закрытие по Esc/фону/ссылке).

Переключатель темы — кнопка в нижней части меню: **светлая** ⇄ **тёмная**.
Пока пользователь ни разу не нажимал её, тема берётся из системной
(`prefers-color-scheme`) и следует за её сменой; ничего не сохраняется. После
нажатия выбор хранится в браузере, в `localStorage["nanopi-theme"]` (`light` |
`dark`); вернуть «как в системе» можно из консоли: `nanopiTheme.reset()`.
Тема применяется до отрисовки: общий шаблон `head` (`templates/head.html`)
содержит маленький inline-скрипт, который ставит `data-theme` на `<html>` раньше
подключения стилей, поэтому вспышки светлой темы нет. CSS:
`:root[data-theme="dark"]` — тёмная, `@media (prefers-color-scheme: dark)
{ :root:not([data-theme]) … }` — запасной вариант, если JS выключен. Логика
кнопки — `static/theme.js` (синхронизация между вкладками через событие
`storage`). Каждая страница подключает `{{template "head"}}` в `<head>`; статика
подключается с `?v=<версия>`, чтобы после обновления панели браузер не держал
старые стили.

## Сборка локально

```bash
cd webui
make build          # → dist/nanopi-webui (текущая машина)
make build-arm64    # → dist/nanopi-webui-linux-arm64 (NanoPi, aarch64)
make build-amd64    # → dist/nanopi-webui-linux-amd64 (x86_64, напр. N100)
make build-all      # оба
./dist/nanopi-webui --version   # nanopi-webui vX.Y.Z linux/amd64
go vet ./... && go test ./...
```

## Установка на плату / хост

См. корневой `install-webui.sh` (скачивает release с GitHub). Архив выбирается по
`uname -m`: `x86_64` → `nanopi-webui-linux-amd64.tar.gz`, `aarch64` →
`nanopi-webui-linux-arm64.tar.gz`, другое — ошибка. Нет `curl`/`jq` — поставит
из apt вместе с `ca-certificates`.
`WEBUI_GITHUB_REPO` берётся из `/opt/nanopi-edge/.env`.

```bash
bash install-webui.sh
# обновление конкретной версии:
WEBUI_VERSION=v0.0.2 bash install-webui.sh --noninteractive
```

После установки `install-webui.sh` выставляет `EDGE_VERSION` в
`/opt/nanopi-edge/.env` равным тегу поставленного релиза: строка заменяется
на месте или дописывается, остальные переменные, порядок строк и права файла
не меняются. Метка не понижается — если в `.env` уже версия новее (поставили
старую панель отдельно), она остаётся. Проверка: `bash tests/install-webui-env.test.sh`.

В панели на статусе: «Проверить обновления» → при наличии релиза — «Обновить»
(скачивает `install-singbox.sh` и `install-webui.sh` из ассетов и проверяет, что в
релизе есть архив панели **своей** архитектуры — `nanopi-webui-linux-<GOARCH>.tar.gz`;
edge-установщик
подтягивает `nanopi-edge-scripts.tar.gz` с того же тега; запускает
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

Тег `v*` → Actions прогоняет `go vet`/`go test`, собирает бинари linux/amd64 и
linux/arm64 с `-X main.Version=<tag>` (проверка `file` и `--version`) и публикует
`nanopi-webui-linux-amd64.tar.gz`, `nanopi-webui-linux-arm64.tar.gz`,
`nanopi-edge-scripts.tar.gz`, `install-singbox.sh`, `install-webui.sh`.

Без WAN_IF/LAN_IF в `.env` (не должно быть после установщика) панель берёт WAN
из маршрута по умолчанию (`internal/netif`), LAN-подсеть — `10.10.10.0/24`.
