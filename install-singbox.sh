#!/bin/bash
# install-singbox.sh — установка и безопасное обновление edge-роутера
# (NanoPi R3S LTS / aarch64 Armbian или x86_64 Debian, напр. N100).
#
#   bash install-singbox.sh           # fresh или upgrade (авто)
#   bash install-singbox.sh status
#   bash install-singbox.sh test
#   NANOPI_YES=1 bash install-singbox.sh   # без вопросов (для WebUI / cron)
#
# Узлы VLESS+Reality — ссылкой vless:// из 3x-ui (мастер спросит; Enter — ввод по полям).
# Без вопросов (свежая установка / пересборка config.json):
#   NANOPI_VLESS_LINKS        ссылки по одной на строку («vless://…» или «имя vless://…»)
#   NANOPI_VLESS_LINKS_FILE   файл с такими строками (# — комментарий)
#   NANOPI_VLESS_DEFAULT      default для selector proxy (иначе — первый узел)
#   NANOPI_HAIRPIN_DNS_TARGET LAN IP для hairpin DNS, если в .env его ещё нет
#   NANOPI_WAN_IF / NANOPI_LAN_IF  имена WAN/LAN (иначе .env или автоопределение:
#                             WAN = интерфейс default route, LAN = другой физический Ethernet)
#   NANOPI_REMOVE_SINGBOX_PKG=1  разрешить apt-get remove пакета sing-box (dpkg), если он стоит
#   NET_STACK=netplan|ifupdown   стек сети принудительно (иначе автоопределение; запишется в .env)
#   SSH_ALLOW_WAN=1           не закрывать SSH с WAN в nftables (запишется в .env)
#
# Повторный запуск не гасит router-режим (dnsmasq/nftables) и по умолчанию
# не пересобирает /etc/sing-box/config.json.
#
# Повседневное управление — /opt/nanopi-edge/scripts/ (из release bundle):
#   router-on | lab-on | wan-dhcp | wan-pppoe | wan-status | proxy-select | hairpin-dns-refresh
#   inbound-status   # метаданные мобильного VLESS (без секретов)
#
set -euo pipefail

SINGBOX_VERSION="${SINGBOX_VERSION:-1.14.4}"
SINGBOX_BIN=/usr/local/bin/sing-box
OPT_ROOT=/opt/nanopi-edge
SCRIPTS_DIR="$OPT_ROOT/scripts"
OPT_ENV="$OPT_ROOT/.env"
SB_DIR=/etc/sing-box
SB_CFG="$SB_DIR/config.json"
MOBILE_VLESS_STATE="$SB_DIR/inbound-vless-reality.json"
UNIT_DST=/etc/systemd/system/sing-box.service
DNSMASQ_DROPIN=/etc/systemd/system/dnsmasq.service.d/sing-box.conf
NETPLAN_DIR=/etc/netplan
SELF_INSTALL="$OPT_ROOT/install-singbox.sh"

EDGE_GITHUB_REPO="${WEBUI_GITHUB_REPO:-${EDGE_GITHUB_REPO:-burzilov/nanopi-edge}}"
SCRIPTS_ASSET=nanopi-edge-scripts.tar.gz
_SCRIPTS_INSTALL_TMP=

WAN_IF=""
LAN_IF=""
CLASH_SECRET_VALUE=""
# fresh | upgrade — выставляет detect_install_mode
INSTALL_MODE=fresh
# 1 если dnsmasq/nftables уже в router-режиме — packages их не трогает
ROUTER_LIVE=0
# 1 если на этом прогоне пересобрали config.json
CONFIG_REBUILT=0

# --- вывод ---

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
ok() { echo "    OK: $*"; }
fail() { echo "    FAIL: $*"; }

step() {
  local n="$1" title="$2"
  echo
  echo "════════════════════════════════════════════════════════════"
  echo " Шаг $n: $title"
  echo "════════════════════════════════════════════════════════════"
}

explain() {
  echo
  echo "── Что сделаю ──"
  echo "$1"
  if [[ -n "${2:-}" ]]; then
    echo
    echo "── Ожидаемый результат ──"
    echo "$2"
  fi
  echo
}

ask() {
  local prompt="$1" default="${2:-}"
  local reply
  if [[ "${NANOPI_YES:-}" == "1" ]]; then
    echo "${default}"
    return 0
  fi
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " reply || true
    echo "${reply:-$default}"
  else
    read -r -p "$prompt: " reply || true
    echo "$reply"
  fi
}

yesno() {
  local prompt="$1" default="${2:-n}"
  local reply hint
  if [[ "${NANOPI_YES:-}" == "1" ]]; then
    [[ "$default" =~ ^[Yy]$ ]]
    return $?
  fi
  if [[ "$default" =~ ^[Yy]$ ]]; then hint="Y/n"; else hint="y/N"; fi
  read -r -p "$prompt [$hint]: " reply || true
  reply=${reply:-$default}
  [[ "$reply" =~ ^[Yy]$ ]]
}

need_root() { [[ $(id -u) -eq 0 ]] || die "нужен root (sudo -i / sudo bash install-singbox.sh)"; }

load_env() {
  [[ -f "$OPT_ENV" ]] || return 0
  # Не затирать EDGE_VERSION из окружения (WebUI Apply передаёт тег релиза).
  local keep_edge_version="${EDGE_VERSION:-}"
  # shellcheck disable=SC1090
  source "$OPT_ENV"
  WAN_IF=${WAN_IF:-}
  LAN_IF=${LAN_IF:-}
  if [[ -n "$keep_edge_version" ]]; then
    EDGE_VERSION="$keep_edge_version"
  fi
}

is_installed() {
  [[ -f "$OPT_ENV" && -f "$SB_CFG" && -x "$SCRIPTS_DIR/router-on" ]]
}

# Router-режим: не гасить dnsmasq/nftables при apt-шаге.
detect_router_live() {
  ROUTER_LIVE=0
  if systemctl is-active --quiet nftables 2>/dev/null; then
    ROUTER_LIVE=1
    return 0
  fi
  if systemctl is-active --quiet dnsmasq 2>/dev/null; then
    ROUTER_LIVE=1
    return 0
  fi
  if systemctl is-active --quiet nanopi-pppoe-server 2>/dev/null; then
    ROUTER_LIVE=1
    return 0
  fi
  if [[ -n "${LAN_IF:-}" ]] && ip -4 -br addr show "$LAN_IF" 2>/dev/null | grep -q '10\.10\.10\.1'; then
    ROUTER_LIVE=1
    return 0
  fi
  return 0
}

detect_install_mode() {
  if is_installed; then
    INSTALL_MODE=upgrade
  else
    INSTALL_MODE=fresh
  fi
}

# Выставить/обновить один ключ в .env, остальные строки сохранить.
env_set_kv() {
  local key="$1" val="$2"
  local tmp
  tmp=$(mktemp)
  if [[ -f "$OPT_ENV" ]]; then
    grep -v "^${key}=" "$OPT_ENV" >"$tmp" || true
  else
    : >"$tmp"
  fi
  val=${val//$'\n'/}
  printf '%s=%s\n' "$key" "$val" >>"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$OPT_ENV"
}

# --- инвентарь ---

show_inventory() {
  echo "Hostname: $(hostname)"
  echo "OS: $(grep -E '^(NAME|VERSION)=' /etc/os-release | tr '\n' ' ')"
  uname -a
  echo
  echo "Интерфейсы:"
  ip -br link || true
  echo
  echo "Адреса:"
  ip -br addr || true
  echo
  echo "Маршрут по умолчанию:"
  ip route | awk '/^default/ {print}' || true
  echo
  echo "Backend сети:"
  systemctl is-active systemd-networkd NetworkManager 2>/dev/null || true
  echo "Сетевой стек для scripts/: $(detect_net_stack)"
  echo
  echo "Физические Ethernet:"
  show_physical_ifaces
}

# --- интерфейсы: автоопределение (те же правила, что scripts/common.sh) ---

# Интерфейс default route (IPv4), кроме ppp*/tun*/sb-*/wg*/lo.
default_route_if() {
  ip -4 route show default 2>/dev/null | awk '
    { for (i = 1; i < NF; i++) if ($i == "dev") { d = $(i + 1)
        if (d !~ /^(ppp|tun|tap|sb-|wg|lo)/) { print d; exit } } }'
}

# Физические проводные Ethernet (есть device/, не Wi-Fi, ARPHRD_ETHER).
physical_ifaces() {
  local root="${NANOPI_SYS_CLASS_NET:-/sys/class/net}" d n
  for d in "$root"/*; do
    n=${d##*/}
    [[ -e "$d/device" ]] || continue
    [[ -e "$d/wireless" || -e "$d/phy80211" ]] && continue
    [[ "$(cat "$d/type" 2>/dev/null)" == "1" ]] || continue
    echo "$n"
  done
}

guess_lan_if() {
  local wan="$1" n
  while read -r n; do
    [[ -n "$n" && "$n" != "$wan" ]] && { echo "$n"; return 0; }
  done < <(physical_ifaces)
  return 0
}

show_physical_ifaces() {
  local root="${NANOPI_SYS_CLASS_NET:-/sys/class/net}" n carrier mac def
  def=$(default_route_if)
  while read -r n; do
    [[ -n "$n" ]] || continue
    carrier=$(cat "$root/$n/carrier" 2>/dev/null || echo "?")
    case "$carrier" in 1) carrier="кабель есть" ;; 0) carrier="нет кабеля" ;; *) carrier="link down" ;; esac
    mac=$(cat "$root/$n/address" 2>/dev/null || echo "?")
    printf '  %-12s %-17s %-12s %s\n' "$n" "$mac" "$carrier" "$([[ "$n" == "$def" ]] && echo "← default route")"
  done < <(physical_ifaces)
}

# netplan | ifupdown | networkmanager | unknown (как nanopi_net_stack в common.sh).
detect_net_stack() {
  case "${NET_STACK:-}" in netplan|ifupdown) echo "$NET_STACK"; return 0 ;; esac
  if command -v netplan >/dev/null 2>&1 && compgen -G "${NETPLAN_DIR}/*.yaml" >/dev/null; then
    echo netplan
  elif systemctl is-active --quiet NetworkManager 2>/dev/null; then
    echo networkmanager
  elif [[ -f /etc/network/interfaces ]] && command -v ifup >/dev/null 2>&1; then
    echo ifupdown
  elif command -v netplan >/dev/null 2>&1; then
    echo netplan
  else
    echo unknown
  fi
}

# Стек сети должен поддерживаться scripts/ (router-on, wan-*, lab-on).
check_net_stack() {
  local st
  st=$(detect_net_stack)
  case "$st" in
    netplan|ifupdown) ok "сетевой стек: ${st}" ;;
    networkmanager)
      die "сетью управляет NetworkManager — router-on/wan-* его не поддерживают.
Нужен netplan (networkd) или Debian ifupdown (/etc/network/interfaces).
Если уверен, задай NET_STACK=netplan|ifupdown в окружении." ;;
    *) die "не найден сетевой стек (нужен netplan или ifupdown)" ;;
  esac
}

# sing-box из apt/.deb конфликтует с нашим ${SINGBOX_BIN} и unit:
# apt upgrade перезапишет /usr/bin/sing-box и unit пакета. Стоп или remove.
check_singbox_pkg() {
  command -v dpkg-query >/dev/null 2>&1 || return 0
  local pkg found=""
  for pkg in sing-box sing-box-beta; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
      found+=" $pkg"
    fi
  done
  [[ -n "$found" ]] || return 0
  found=${found# }
  echo
  echo "    ВНИМАНИЕ: sing-box установлен пакетом (dpkg): ${found}"
  echo "    Установщик ставит свой бинарь ${SINGBOX_BIN} и unit ${UNIT_DST};"
  echo "    пакетный /usr/bin/sing-box и его unit будут конфликтовать (apt upgrade, автозапуск)."
  echo "    Рекомендация: apt-get remove ${found}  (без purge — /etc/sing-box сохранится)."
  if [[ "${NANOPI_REMOVE_SINGBOX_PKG:-}" == "1" ]] \
     || { [[ "${NANOPI_YES:-}" != "1" ]] && yesno "Удалить пакет(ы) ${found} сейчас (apt-get remove, без purge)?" n; }; then
    local bak
    if [[ -d "$SB_DIR" ]]; then
      bak="${SB_DIR}.bak-$(date +%Y%m%d-%H%M%S)"
      cp -a "$SB_DIR" "$bak" && ok "копия ${SB_DIR} → ${bak}"
    fi
    systemctl disable --now sing-box 2>/dev/null || true
    export DEBIAN_FRONTEND=noninteractive
    # shellcheck disable=SC2086
    apt-get remove -y $found
    ok "пакет(ы) ${found} удалены"
    return 0
  fi
  if [[ "$INSTALL_MODE" == "upgrade" ]]; then
    # уже работающую установку (в т.ч. upgrade из панели) не роняем — только предупреждение
    echo "    WARN: upgrade продолжается; удали пакет вручную, когда будет удобно"
    return 0
  fi
  die "останавливаюсь: сначала удали пакет sing-box (apt-get remove ${found})
или запусти с NANOPI_REMOVE_SINGBOX_PKG=1"
}

cmd_status() {
  load_env
  echo "WAN_IF=$WAN_IF  LAN_IF=$LAN_IF"
  echo "OPT_ENV=$OPT_ENV"
  local st
  st=$(detect_net_stack)
  echo "=== сеть: ${st} ==="
  if [[ "$st" == ifupdown ]]; then
    ls -la /etc/network/interfaces /etc/network/interfaces.d/ 2>/dev/null || true
  else
    ls -la "$NETPLAN_DIR"/*.yaml 2>/dev/null || true
  fi
  echo "=== addr ==="
  ip -br addr
  echo "=== route ==="
  ip route | head -10
  echo "=== services ==="
  systemctl is-active sing-box nftables dnsmasq nanopi-pppoe-server nanopi-wan-pppoe 2>/dev/null || true
  systemctl is-enabled sing-box nftables dnsmasq 2>/dev/null || true
  echo "=== wan-status ==="
  if [[ -x "$SCRIPTS_DIR/wan-status" ]]; then
    "$SCRIPTS_DIR/wan-status" 2>/dev/null | head -c 2000 || true
    echo
  fi
  echo "=== scripts ==="
  ls -la "$SCRIPTS_DIR" 2>/dev/null || true
}

# --- scripts bundle с GitHub Release ---

edge_api_get() {
  local url="$1"
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "User-Agent: nanopi-edge-installer" \
    "$url"
}

edge_resolve_github_repo() {
  if [[ -n "${WEBUI_GITHUB_REPO:-}" ]]; then
    echo "$WEBUI_GITHUB_REPO"
    return 0
  fi
  if [[ -f "$OPT_ENV" ]]; then
    local r
    r=$(grep -E '^WEBUI_GITHUB_REPO=' "$OPT_ENV" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '
' || true)
    if [[ -n "$r" ]]; then
      echo "$r"
      return 0
    fi
  fi
  echo "${EDGE_GITHUB_REPO:-burzilov/nanopi-edge}"
}

ensure_download_deps() {
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && return 0
  info "Ставлю curl/jq для скачивания scripts bundle"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    curl jq ca-certificates
}

# Скачать url → dest: до 3 попыток (+ curl --retry), прогресс раз в ~10 с (размер, время).
# В логах без tty прогресс-бар curl бесполезен, поэтому печатаем строку сами.
download_file() {
  local url="$1" dest="$2" label="${3:-$(basename "$2")}"
  local attempt pid rc t size
  for attempt in 1 2 3; do
    rm -f "$dest"
    curl -fL -sS --retry 3 --retry-delay 3 --retry-connrefused \
      --connect-timeout 20 --speed-limit 1024 --speed-time 60 \
      -o "$dest" "$url" &
    pid=$!
    t=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep 1
      t=$((t + 1))
      if (( t % 10 == 0 )) && kill -0 "$pid" 2>/dev/null; then
        size=$(stat -c %s "$dest" 2>/dev/null || echo 0)
        info "… ${label}: скачано $((size / 1024)) КБ за ${t} с"
      fi
    done
    rc=0
    wait "$pid" || rc=$?
    if [[ "$rc" -eq 0 && -s "$dest" ]]; then
      return 0
    fi
    info "скачивание ${label} не удалось (попытка ${attempt}/3, curl rc=${rc})"
    [[ "$attempt" -lt 3 ]] && sleep 5
  done
  rm -f "$dest"
  return 1
}

download_scripts_bundle() {
  local tmp="$1" repo version api_base meta download_url tag
  repo=$(edge_resolve_github_repo)
  version="${EDGE_VERSION:-}"
  api_base="https://api.github.com/repos/${repo}"

  if [[ -n "$version" ]]; then
    meta=$(edge_api_get "${api_base}/releases/tags/${version}")
  else
    meta=$(edge_api_get "${api_base}/releases/latest")
  fi

  tag=$(echo "$meta" | jq -r '.tag_name // empty')
  [[ -n "$tag" ]] || die "не удалось получить tag release из ${repo}"

  download_url=$(echo "$meta" | jq -r --arg n "$SCRIPTS_ASSET" \
    '.assets[] | select(.name == $n) | .browser_download_url' | head -1)
  [[ -n "$download_url" && "$download_url" != null ]] \
    || die "в release ${tag} (${repo}) нет ассета ${SCRIPTS_ASSET}"

  info "Скачиваю ${SCRIPTS_ASSET} из ${repo} (${tag})"
  download_file "$download_url" "$tmp/$SCRIPTS_ASSET" "$SCRIPTS_ASSET" \
    || die "не удалось скачать ${SCRIPTS_ASSET} (${download_url})"
  printf '%s\n' "$tag" >"$tmp/BUNDLE_TAG"
}

# conntrack: модуль при загрузке + hashsize (modprobe.d и сразу в /sys). Идемпотентно.
install_conntrack_tuning() {
  local tpl="$1" want cur param=/sys/module/nf_conntrack/parameters/hashsize
  [[ -f "$tpl/nanopi-conntrack.modprobe.conf" ]] || die "в bundle нет templates/nanopi-conntrack.modprobe.conf"
  [[ -f "$tpl/nanopi-conntrack.modules-load.conf" ]] || die "в bundle нет templates/nanopi-conntrack.modules-load.conf"
  mkdir -p /etc/modprobe.d /etc/modules-load.d
  install -m 644 "$tpl/nanopi-conntrack.modprobe.conf" /etc/modprobe.d/nanopi-conntrack.conf
  install -m 644 "$tpl/nanopi-conntrack.modules-load.conf" /etc/modules-load.d/nanopi-conntrack.conf
  modprobe nf_conntrack 2>/dev/null || info "modprobe nf_conntrack не удался — hashsize применится после перезагрузки"
  want=$(sed -n 's/^[[:space:]]*options[[:space:]]\+nf_conntrack[[:space:]].*hashsize=\([0-9]\+\).*/\1/p' \
    /etc/modprobe.d/nanopi-conntrack.conf | head -1)
  if [[ -n "$want" && -w "$param" ]]; then
    cur=$(cat "$param" 2>/dev/null || echo "")
    if [[ "$cur" != "$want" ]]; then
      if echo "$want" >"$param" 2>/dev/null; then
        ok "conntrack hashsize: ${cur:-?} → ${want}"
      else
        info "не удалось записать hashsize=${want} (применится после перезагрузки)"
      fi
    else
      ok "conntrack hashsize=${want}"
    fi
  fi
}

# Убрать старый дубль sysctl, если все его ключи с теми же значениями уже в основном файле.
remove_dup_sysctl() {
  local dup="$1" main="$2" line key val
  [[ -f "$dup" && -f "$main" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%%#*}
    line=$(echo "$line" | tr -d '[:space:]')
    [[ -z "$line" ]] && continue
    [[ "$line" == *=* ]] || return 0
    key=${line%%=*}
    val=${line#*=}
    sed 's/#.*//' "$main" | tr -d ' \t\r' | grep -qxF "${key}=${val}" || return 0
  done <"$dup"
  rm -f "$dup"
  ok "убран дубль ${dup} (значения есть в ${main})"
}

install_scripts_bundle() {
  explain \
    "Скачаю ${SCRIPTS_ASSET} из GitHub Release → ${SCRIPTS_DIR}/
(router-on, lab-on, wan-dhcp, wan-pppoe, wan-status, proxy-select, hairpin-dns-refresh,
inbound-status, common.sh) + templates (sing-box.service, sysctl).
Unit sing-box и drop-in dnsmasq поставлю позже — после бинарника (шаг 5)." \
    "Скрипты executable на месте; templates root:root"

  ensure_download_deps
  mkdir -p "$SCRIPTS_DIR" "$OPT_ROOT"
  _SCRIPTS_INSTALL_TMP=$(mktemp -d)
  download_scripts_bundle "$_SCRIPTS_INSTALL_TMP"

  local stage bundle_root scripts_src templates_src archive
  archive="$_SCRIPTS_INSTALL_TMP/$SCRIPTS_ASSET"
  stage=$(mktemp -d)
  tar --no-same-owner -xzf "$archive" -C "$stage"

  if [[ -f "$stage/nanopi-edge-scripts/scripts/common.sh" ]]; then
    bundle_root="$stage/nanopi-edge-scripts"
  elif [[ -f "$stage/scripts/common.sh" ]]; then
    bundle_root="$stage"
  else
    local common_path
    common_path=$(find "$stage" -type f -path '*/scripts/common.sh' | head -1)
    [[ -n "$common_path" ]] || die "в bundle нет scripts/common.sh"
    bundle_root=$(dirname "$(dirname "$common_path")")
  fi
  scripts_src="$bundle_root/scripts"
  templates_src="$bundle_root/templates"
  [[ -f "$scripts_src/common.sh" ]] || die "в bundle нет scripts/common.sh"

  install -m 644 "$scripts_src/common.sh" "$SCRIPTS_DIR/common.sh"
  for f in router-on lab-on wan-dhcp wan-pppoe wan-status proxy-select hairpin-dns-refresh inbound-status; do
    [[ -f "$scripts_src/$f" ]] || die "в bundle нет scripts/$f"
    install -m 755 "$scripts_src/$f" "$SCRIPTS_DIR/$f"
  done

  local templates_dst="$OPT_ROOT/templates"
  mkdir -p "$templates_dst"
  [[ -d "$templates_src" ]] || die "в bundle нет каталога templates/"
  cp -r "$templates_src/." "$templates_dst/"
  # uid/gid из архива CI (runner 1001) не тащим: всё в /opt/nanopi-edge — root:root
  chown -R root:root "$templates_dst"
  chmod -R u+rwX,go+rX,go-w "$templates_dst"

  [[ -f "$templates_dst/sing-box.service" ]] || die "в bundle нет templates/sing-box.service"
  [[ -f "$templates_dst/dnsmasq-sing-box.conf" ]] || die "в bundle нет templates/dnsmasq-sing-box.conf"
  [[ -f "$templates_dst/99-nanopi-forward.conf" ]] || die "в bundle нет templates/99-nanopi-forward.conf"
  # conntrack до sysctl: без загруженного nf_conntrack ключи net.netfilter.* не применятся
  install_conntrack_tuning "$templates_dst"
  install -m 644 "$templates_dst/99-nanopi-forward.conf" /etc/sysctl.d/99-nanopi-forward.conf
  sysctl -p /etc/sysctl.d/99-nanopi-forward.conf
  remove_dup_sysctl /etc/sysctl.d/98-nanopi-conntrack.conf /etc/sysctl.d/99-nanopi-forward.conf

  rm -rf "$stage" "$_SCRIPTS_INSTALL_TMP"
  _SCRIPTS_INSTALL_TMP=
  ok "scripts bundle установлен"
}


# --- пакеты / sysctl / sing-box ---

# На время apt запретить пакетам стартовать службы (invoke-rc.d / deb-systemd-invoke
# смотрят /usr/sbin/policy-rc.d; 101 = «действие запрещено»). Свой файл ставим только
# если чужого нет; снимаем сразу после apt и на выходе скрипта (trap).
POLICY_RC=/usr/sbin/policy-rc.d
_POLICY_RC_OURS=0
_POLICY_RC_MARK="# nanopi-edge: временный запрет старта служб на время apt"

policy_rc_block() {
  if [[ -e "$POLICY_RC" ]]; then
    info "${POLICY_RC} уже есть — не трогаю"
    return 0
  fi
  printf '#!/bin/sh\n%s\nexit 101\n' "$_POLICY_RC_MARK" >"$POLICY_RC"
  chmod 755 "$POLICY_RC"
  _POLICY_RC_OURS=1
  trap policy_rc_restore EXIT
}

policy_rc_restore() {
  if [[ "$_POLICY_RC_OURS" -eq 1 ]] && grep -qF "$_POLICY_RC_MARK" "$POLICY_RC" 2>/dev/null; then
    rm -f "$POLICY_RC"
  fi
  _POLICY_RC_OURS=0
}

install_packages() {
  detect_router_live
  local -a pkgs=(curl jq ca-certificates nftables dnsmasq ppp pppoe openssl
    iproute2 procps kmod tar gzip)
  # ifupdown: нужен DHCP-клиент для «inet dhcp» (Debian 13 — dhcpcd-base)
  if [[ "$(detect_net_stack)" == ifupdown ]] \
     && ! command -v dhcpcd >/dev/null 2>&1 && ! command -v dhclient >/dev/null 2>&1 \
     && ! command -v udhcpc >/dev/null 2>&1; then
    pkgs+=(dhcpcd-base)
  fi
  local missing=() p
  for p in "${pkgs[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
  done
  if [[ "$ROUTER_LIVE" -eq 1 ]]; then
    explain \
      "apt update и пакеты: ${pkgs[*]}.
Router-режим уже активен — dnsmasq/nftables НЕ останавливаю и не mask." \
      "Пакеты на месте; LAN dual-serve без простоя"
  else
    explain \
      "apt update и минимум пакетов: ${pkgs[*]}.
nftables/dnsmasq сразу выключу — в lab не должны слушать LAN роутера." \
      "Пакеты на месте; dnsmasq masked; nftables не active до router-on."
  fi

  export DEBIAN_FRONTEND=noninteractive
  if [[ ${#missing[@]} -gt 0 ]]; then
    info "Не хватает пакетов: ${missing[*]}"
  fi
  if [[ "$ROUTER_LIVE" -ne 1 ]]; then
    # lab: dnsmasq не должен стартовать даже на секунду (порт 53/67 в LAN роутера).
    systemctl mask dnsmasq 2>/dev/null || true
    policy_rc_block
  fi
  apt-get update -y
  local apt_rc=0
  apt-get install -y --no-install-recommends \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    "${pkgs[@]}" || apt_rc=$?
  policy_rc_restore
  [[ "$apt_rc" -eq 0 ]] || die "apt-get install завершился с ошибкой (rc=${apt_rc})"

  if [[ "$ROUTER_LIVE" -eq 1 ]]; then
    info "router live — пропускаю disable nftables / mask dnsmasq"
    return 0
  fi
  systemctl disable --now nftables 2>/dev/null || true
  systemctl mask dnsmasq 2>/dev/null || true
  systemctl stop dnsmasq 2>/dev/null || true
}


# Unit sing-box + drop-in dnsmasq (After=/Requires=sing-box) — только когда бинарник
# ${SINGBOX_BIN} уже на месте: иначе systemd успеет дёрнуть unit без ExecStart-файла
# (203/EXEC), а dnsmasq потянет за собой несуществующий sing-box.
install_service_units() {
  local tpl="$OPT_ROOT/templates"
  [[ -x "$SINGBOX_BIN" ]] || die "нет ${SINGBOX_BIN} — unit sing-box ставлю только после бинарника"
  [[ -f "$tpl/sing-box.service" ]] || die "нет ${tpl}/sing-box.service (обнови scripts bundle)"
  [[ -f "$tpl/dnsmasq-sing-box.conf" ]] || die "нет ${tpl}/dnsmasq-sing-box.conf (обнови scripts bundle)"
  install -m 644 "$tpl/sing-box.service" "$UNIT_DST"
  mkdir -p "$(dirname "$DNSMASQ_DROPIN")"
  install -m 644 "$tpl/dnsmasq-sing-box.conf" "$DNSMASQ_DROPIN"
  systemctl daemon-reload
  systemctl enable sing-box
  ok "unit sing-box (enabled) и drop-in dnsmasq → sing-box"
}

install_singbox_binary() {
  explain \
    "Скачаю sing-box ${SINGBOX_VERSION} с GitHub Releases → ${SINGBOX_BIN}." \
    "sing-box version содержит ${SINGBOX_VERSION}"

  if command -v sing-box >/dev/null 2>&1 && sing-box version 2>/dev/null | grep -q "$SINGBOX_VERSION"; then
    info "sing-box $SINGBOX_VERSION уже установлен"
    return 0
  fi
  local arch url tmp
  case $(uname -m) in
    aarch64|arm64) arch=arm64 ;;
    x86_64) arch=amd64 ;;
    *) die "неподдерживаемая arch: $(uname -m)" ;;
  esac
  url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${arch}.tar.gz"
  tmp=$(mktemp -d)
  info "Скачиваю sing-box ${SINGBOX_VERSION} (${arch}, ~15 МБ) с GitHub — может занять несколько минут"
  download_file "$url" "$tmp/sb.tgz" "sing-box-${SINGBOX_VERSION}-linux-${arch}.tar.gz" \
    || { rm -rf "$tmp"; die "не удалось скачать sing-box: ${url}"; }
  tar --no-same-owner -xzf "$tmp/sb.tgz" -C "$tmp"
  install -m 755 "$tmp"/sing-box-*/sing-box "$SINGBOX_BIN"
  rm -rf "$tmp"
  "$SINGBOX_BIN" version | head -1
}


write_dotenv_fresh() {
  local secret="$1"
  local wan_mode=${WAN_MODE:-dhcp}
  local pppoe_user=${PPPOE_USER:-}
  local pppoe_vlan=${PPPOE_VLAN:-}
  local keep_hairpin=""
  mkdir -p "$OPT_ROOT" "$SB_DIR"
  umask 077
  # персональный hairpin не в git — сохраняем при перезаписи .env
  if [[ -f "$OPT_ENV" ]]; then
    keep_hairpin=$(grep -E '^HAIRPIN_DNS_TARGET=' "$OPT_ENV" 2>/dev/null | tail -1 || true)
  fi
  cat > "$OPT_ENV" <<EOF
# NanoPi edge — читают scripts/* и webui
CLASH_API=http://127.0.0.1:9090
CLASH_SECRET=${secret}
SINGBOX_CONFIG=${SB_CFG}
SINGBOX_UNIT=sing-box
WEBUI_LISTEN=10.10.10.1:80
WEBUI_GITHUB_REPO=burzilov/nanopi-edge
WAN_IF=${WAN_IF}
LAN_IF=${LAN_IF}
WAN_MODE=${wan_mode}
PPPOE_USER=${pppoe_user}
PPPOE_VLAN=${pppoe_vlan}
# Опционально (не коммитить значение): LAN IP Nginx Proxy Manager → dnsmasq alias белый→этот IP
# HAIRPIN_DNS_TARGET=192.168.x.x
# /opt/nanopi-edge/scripts/hairpin-dns-refresh ; DNS клиентов роутера = 10.10.10.1
EOF
  if [[ -n "$keep_hairpin" ]]; then
    printf '%s\n' "$keep_hairpin" >>"$OPT_ENV"
  fi
  chmod 600 "$OPT_ENV"
  # Не трогаем inbound-vless-reality.json (секреты мобильного VLESS).
  rm -f "$SB_DIR/clash-api.secret" "$SB_DIR/ui.env" "$SB_DIR/.env"
}

# Upgrade: обновить только известные ключи, чужие строки в .env не трогать.
write_dotenv_merge() {
  local secret="$1"
  local wan_mode=${WAN_MODE:-dhcp}
  local pppoe_user=${PPPOE_USER:-}
  local pppoe_vlan=${PPPOE_VLAN:-}
  mkdir -p "$OPT_ROOT" "$SB_DIR"
  touch "$OPT_ENV"
  chmod 600 "$OPT_ENV"
  env_set_kv CLASH_API "http://127.0.0.1:9090"
  env_set_kv CLASH_SECRET "$secret"
  env_set_kv SINGBOX_CONFIG "$SB_CFG"
  env_set_kv SINGBOX_UNIT "sing-box"
  # WEBUI_* — только если ещё нет (не затирать кастом)
  if ! grep -q '^WEBUI_LISTEN=' "$OPT_ENV" 2>/dev/null; then
    env_set_kv WEBUI_LISTEN "10.10.10.1:80"
  fi
  if ! grep -q '^WEBUI_GITHUB_REPO=' "$OPT_ENV" 2>/dev/null; then
    env_set_kv WEBUI_GITHUB_REPO "burzilov/nanopi-edge"
  fi
  env_set_kv WAN_IF "$WAN_IF"
  env_set_kv LAN_IF "$LAN_IF"
  # явный выбор стека/SSH из окружения — запомнить для scripts/ (router-on, wan-*)
  case "${NET_STACK:-}" in netplan|ifupdown) env_set_kv NET_STACK "$NET_STACK" ;; esac
  [[ -n "${SSH_ALLOW_WAN:-}" ]] && env_set_kv SSH_ALLOW_WAN "$SSH_ALLOW_WAN"
  env_set_kv WAN_MODE "$wan_mode"
  env_set_kv PPPOE_USER "$pppoe_user"
  env_set_kv PPPOE_VLAN "$pppoe_vlan"
  # Не трогаем inbound-vless-reality.json (секреты мобильного VLESS).
  rm -f "$SB_DIR/clash-api.secret" "$SB_DIR/ui.env" "$SB_DIR/.env"
}

gen_clash_secrets() {
  if [[ "$INSTALL_MODE" == "upgrade" ]]; then
    explain \
      "Обновлю ключи в ${OPT_ENV} (merge). CLASH_SECRET сохраню.
Чужие переменные в файле не удаляю." \
      "Файл ${OPT_ENV}; clash_api на 127.0.0.1:9090"
  else
    explain \
      "Сгенерирую ${OPT_ENV} (0600): CLASH_API/SECRET, пути, WAN_IF/LAN_IF.
Тот же CLASH_SECRET подставлю в config.json (sing-box читает только JSON)." \
      "Файл ${OPT_ENV}; clash_api на 127.0.0.1:9090"
  fi

  local secret=""
  local saved_wan="$WAN_IF" saved_lan="$LAN_IF"
  # source .env не должен откатить EDGE_VERSION, переданный из WebUI.
  local keep_edge_version="${EDGE_VERSION:-}"
  if [[ -f $OPT_ENV ]] && grep -q '^CLASH_SECRET=' "$OPT_ENV"; then
    # shellcheck disable=SC1090
    source "$OPT_ENV"
    secret=${CLASH_SECRET:-}
    info "Переиспользую CLASH_SECRET из ${OPT_ENV}"
  elif [[ -f $SB_DIR/.env ]] && grep -q '^CLASH_SECRET=' "$SB_DIR/.env"; then
    # shellcheck disable=SC1090
    source "$SB_DIR/.env"
    secret=${CLASH_SECRET:-}
    info "Мигрирую CLASH_SECRET из /etc/sing-box/.env"
  elif [[ -f $SB_DIR/ui.env ]] && grep -q '^CLASH_SECRET=' "$SB_DIR/ui.env"; then
    # shellcheck disable=SC1090
    source "$SB_DIR/ui.env"
    secret=${CLASH_SECRET:-}
    info "Мигрирую CLASH_SECRET из ui.env"
  fi
  # source мог вернуть старые IF — оставляем значения с шага prompt_interfaces
  WAN_IF="$saved_wan"
  LAN_IF="$saved_lan"
  if [[ -n "${keep_edge_version}" ]]; then
    EDGE_VERSION="$keep_edge_version"
  fi
  if [[ -z "${secret:-}" ]]; then
    secret=$(openssl rand -hex 16)
  fi
  if [[ "$INSTALL_MODE" == "upgrade" && -f "$OPT_ENV" ]]; then
    write_dotenv_merge "$secret"
  else
    write_dotenv_fresh "$secret"
  fi
  CLASH_SECRET_VALUE=$secret
}

prompt_interfaces() {
  # Приоритет: NANOPI_WAN_IF/NANOPI_LAN_IF → .env (upgrade) → автоопределение.
  local def_wan="${NANOPI_WAN_IF:-${WAN_IF:-}}"
  local def_lan="${NANOPI_LAN_IF:-${LAN_IF:-}}"
  local src_wan="env/.env" src_lan="env/.env"
  if [[ -z "$def_wan" ]]; then
    def_wan=$(default_route_if); src_wan="default route"
  fi
  if [[ -z "$def_lan" ]]; then
    def_lan=$(guess_lan_if "$def_wan"); src_lan="второй физический Ethernet"
  fi
  if [[ "$INSTALL_MODE" == "upgrade" ]]; then
    explain \
      "Интерфейсы из ${OPT_ENV} (можно поправить)." \
      "WAN_IF / LAN_IF сохранятся в ${OPT_ENV}"
  else
    explain \
      "Уточню имена Ethernet. По умолчанию WAN = интерфейс маршрута по умолчанию
(lab-кабель сейчас в нём), LAN = другой физический Ethernet.
Примеры: NanoPi R3S LTS — WAN=end0, LAN=enp1s0; x86 (N100) — enp1s0/enp2s0." \
      "WAN_IF / LAN_IF сохранятся в ${OPT_ENV}"
  fi

  echo "Сейчас:"
  show_physical_ifaces
  echo "  (подсказка: WAN=${def_wan:-?} [${src_wan}], LAN=${def_lan:-?} [${src_lan}])"
  echo
  WAN_IF=$(ask "WAN interface (к ISP; сейчас lab-кабель)" "$def_wan")
  LAN_IF=$(ask "LAN interface (к домашнему роутеру)" "$def_lan")
  [[ -n "$WAN_IF" ]] || die "WAN не определён: задай NANOPI_WAN_IF (нет default route?)"
  [[ -n "$LAN_IF" ]] || die "LAN не определён: задай NANOPI_LAN_IF (нет второго Ethernet?)"
  [[ "$WAN_IF" != "$LAN_IF" ]] || die "WAN и LAN не должны совпадать"
  validate_iface_names
  ok "WAN_IF=${WAN_IF} LAN_IF=${LAN_IF}"
}

validate_iface_names() {
  local n
  for n in "$WAN_IF" "$LAN_IF"; do
    [[ "$n" =~ ^[A-Za-z0-9._-]{1,15}$ ]] || die "некорректное имя интерфейса: '${n}'"
    if ! ip link show dev "$n" >/dev/null 2>&1; then
      if [[ "$INSTALL_MODE" == "fresh" ]]; then
        die "интерфейса '${n}' нет в системе (ip -br link)"
      fi
      echo "    WARN: интерфейса '${n}' сейчас нет в системе"
    fi
  done
}


# Записать alias hairpin в dnsmasq (тот же код, что scripts/hairpin-dns-refresh) и,
# если dnsmasq уже работает (router live), перезапустить его. В lab dnsmasq замаскирован —
# файл просто ляжет на место, router-on его подхватит.
hairpin_apply_alias() {
  local target="$1"
  if [[ ! -x "$SCRIPTS_DIR/hairpin-dns-refresh" || ! -f "$SCRIPTS_DIR/common.sh" ]]; then
    info "нет ${SCRIPTS_DIR}/hairpin-dns-refresh — alias применится при router-on"
    return 0
  fi
  (
    # shellcheck disable=SC1091
    source "$SCRIPTS_DIR/common.sh"
    nanopi_load_env 2>/dev/null || true
    HAIRPIN_DNS_TARGET=$target
    nanopi_write_hairpin_dns_alias
  ) || { echo "WARN: не удалось записать hairpin alias (повтори: ${SCRIPTS_DIR}/hairpin-dns-refresh)" >&2; return 0; }
  if systemctl is-active --quiet dnsmasq 2>/dev/null; then
    if systemctl restart dnsmasq; then
      info "dnsmasq перезапущен — hairpin alias применён"
    else
      echo "WARN: dnsmasq не перезапустился — проверь: systemctl status dnsmasq" >&2
    fi
  fi
}

hairpin_valid_ipv4() {
  local ip="$1" o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    (( 10#$o <= 255 )) || return 1
  done
}

# Шаг мастера «Hairpin DNS» (после .env).
#   интерактивно: Enter = оставить текущее (или пропустить, если не задано), «-» = выключить;
#   NANOPI_YES=1: не спрашиваем. Значение из .env не трогаем; если в .env ключа нет —
#     берём NANOPI_HAIRPIN_DNS_TARGET (именно его, а не HAIRPIN_DNS_TARGET: WebUI
#     наследует старое значение из EnvironmentFile=.env и вернул бы выключенный hairpin).
prompt_hairpin_dns() {
  local existing=""
  if [[ -f "$OPT_ENV" ]] && grep -q '^HAIRPIN_DNS_TARGET=' "$OPT_ENV" 2>/dev/null; then
    existing=$(grep -E '^HAIRPIN_DNS_TARGET=' "$OPT_ENV" | tail -1 | cut -d= -f2- | tr -d '\r[:space:]')
  fi

  if [[ "${NANOPI_YES:-}" == "1" ]]; then
    local val="$existing"
    if [[ -z "$val" && -n "${NANOPI_HAIRPIN_DNS_TARGET:-}" ]]; then
      val=${NANOPI_HAIRPIN_DNS_TARGET//[[:space:]]/}
      if hairpin_valid_ipv4 "$val"; then
        env_set_kv HAIRPIN_DNS_TARGET "$val"
        info "HAIRPIN_DNS_TARGET=${val} (из NANOPI_HAIRPIN_DNS_TARGET)"
      else
        echo "WARN: NANOPI_HAIRPIN_DNS_TARGET не IPv4 — hairpin пропущен" >&2
        val=""
      fi
    fi
    HAIRPIN_DNS_TARGET=$val
    if [[ -n "$val" && "$val" != "$existing" ]]; then
      hairpin_apply_alias "$val"
      info "Hairpin DNS (NANOPI_YES): ${val}"
    elif [[ -n "$val" ]]; then
      # уже задан — alias ведут wan-*/hairpin-dns-refresh; dnsmasq зря не дёргаем
      info "Hairpin DNS (NANOPI_YES): ${val} (без изменений)"
    else
      info "Hairpin DNS (NANOPI_YES): пропуск"
    fi
    return 0
  fi

  explain \
    "Опционально: hairpin DNS для доменов Nginx Proxy Manager из домашней LAN.
Укажи LAN IP Nginx Proxy Manager (или хоста за роутером). dnsmasq подменит A-записи
с белым IP WAN на этот адрес. Enter без значения = не использовать.
Потом на роутере: DNS клиентов = 10.10.10.1. Значение только в ${OPT_ENV}, не в git.
Если уже задано: Enter = оставить текущее; «-» = выключить.
Позже можно поменять в панели (Проброс портов → DNS hairpin)." \
    "HAIRPIN_DNS_TARGET в ${OPT_ENV} или отсутствует"

  local val try
  for try in 1 2 3; do
    val=$(ask "LAN IP для hairpin DNS (Nginx Proxy Manager, Enter — пропустить)" "$existing")
    val=${val//[[:space:]]/}
    if [[ "$val" == "-" || "$val" == "none" || "$val" == "off" ]]; then
      val=""
    fi
    if [[ -z "$val" ]] || hairpin_valid_ipv4 "$val"; then
      break
    fi
    echo "  нужен IPv4 (например 192.168.1.10), «-» или Enter" >&2
    if [[ "$try" -ge 3 ]]; then
      echo "WARN: hairpin DNS не изменён (настрой позже в панели или перезапусти установщик)" >&2
      HAIRPIN_DNS_TARGET=$existing
      return 0
    fi
  done

  if [[ -z "$val" ]]; then
    HAIRPIN_DNS_TARGET=""
    if [[ -n "$existing" ]]; then
      # выключение: убрать ключ и переписать alias (без подмены; исключения панели остаются)
      local tmp
      tmp=$(mktemp)
      grep -v '^HAIRPIN_DNS_TARGET=' "$OPT_ENV" >"$tmp" || true
      chmod 600 "$tmp"
      mv "$tmp" "$OPT_ENV"
      hairpin_apply_alias ""
      info "Hairpin DNS выключен"
    else
      info "Hairpin DNS пропущен"
    fi
    return 0
  fi
  HAIRPIN_DNS_TARGET=$val
  if [[ "$val" == "$existing" ]]; then
    info "HAIRPIN_DNS_TARGET=${val} (без изменений)"
    return 0
  fi
  env_set_kv HAIRPIN_DNS_TARGET "$val"
  info "HAIRPIN_DNS_TARGET=${val}"
  hairpin_apply_alias "$val"
}

# Рендер config.json из шаблона + узлов VLESS → stdout (без записи в /etc; тестируется отдельно).
#   render_singbox_config <template> <nodes.json> <clash_secret> <default_tag> <wan_if>
# - outbounds: direct + vless-узлы + selector proxy; flow/fingerprint узла — из ссылки
#   (нет поля → xtls-rprx-vision / chrome, как раньше; flow "" → без flow);
# - IPv4 узлов → ОДНО отдельное правило route direct сразу после ip_is_private
#   (клиенты LAN к VPS — мимо туннеля); в другие ip_cidr (reject 169.254/16, DNS IP) не попадают;
# - domain_suffix первого route-правила outbound=proxy (его правит WebUI) копируется
#   в DNS-правило server=dns-proxy с domain_suffix — один источник списка доменов.
render_singbox_config() {
  local tpl="$1" nodes_file="$2" secret="$3" default_tag="$4" wan_if="$5"
  local rendered
  rendered=$(mktemp)
  # Плейсхолдеры @WAN_IF@ / @CLASH_SECRET@ — остальное через jq.
  sed -e "s/@WAN_IF@/${wan_if}/g" \
      -e "s/@CLASH_SECRET@/${secret}/g" \
      "$tpl" >"$rendered"

  jq -n \
    --slurpfile nodes "$nodes_file" \
    --arg default "$default_tag" \
    --slurpfile base "$rendered" '
    ($nodes[0]) as $n |
    ($n | map(select(.server | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")) | .server + "/32") | unique) as $vps_cidrs |
    ($base[0]
      | .outbounds = (
          [ { type: "direct", tag: "direct" } ]
          + ($n | map({
              type: "vless",
              tag: .tag,
              server: .server,
              server_port: .server_port,
              uuid: .uuid,
              network: ["tcp", "udp"],
              flow: (if has("flow") then .flow else "xtls-rprx-vision" end),
              tls: {
                enabled: true,
                server_name: .server_name,
                utls: { enabled: true, fingerprint: ((.fingerprint // "") | if . == "" then "chrome" else . end) },
                reality: {
                  enabled: true,
                  public_key: .public_key,
                  short_id: .short_id
                }
              }
            } | if .flow == "" then del(.flow) else . end))
          + [{
              type: "selector",
              tag: "proxy",
              outbounds: ($n | map(.tag)),
              default: $default
            }]
        )
      | .route.rules = (
          .route.rules as $r
          | if ($vps_cidrs | length) == 0 then $r
            else
              ($r | map(.ip_is_private == true) | index(true)) as $i
              | { action: "route", outbound: "direct", ip_cidr: $vps_cidrs } as $vps
              | if $i == null then [$vps] + $r
                else $r[:($i + 1)] + [$vps] + $r[($i + 1):]
                end
            end
        )
      | ([.route.rules[] | select(.outbound == "proxy" and has("domain_suffix"))][0].domain_suffix // []) as $pd
      | if .dns.rules then
          .dns.rules = [
            .dns.rules[]
            | if (.server == "dns-proxy" and has("domain_suffix")) then
                (if ($pd | length) > 0 then .domain_suffix = $pd else empty end)
              else . end
          ]
        else . end
    )
  '
  local rc=$?
  rm -f "$rendered"
  return $rc
}

build_singbox_config() {
  local nodes_file="$1" secret="$2" default_tag="$3"
  local tpl="$OPT_ROOT/templates/sing-box.config.json.tpl"
  local tmp

  explain \
    "Соберу единый ${SB_CFG} из шаблона + узлы VLESS (мастер).
TUN, DNS: AdGuard DoH через proxy (фолбэк — напрямую), remote ruleset’ы, selector proxy, clash_api.
IP узлов (IPv4) — отдельное правило direct (клиенты LAN к VPS мимо туннеля).
Если есть ${MOBILE_VLESS_STATE} (мобильный VLESS) — восстановлю inbound." \
    "sing-box check успешен; mode 0600"

  [[ -f "$tpl" ]] || die "нет шаблона ${tpl} (обнови scripts bundle)"

  if [[ -f "$SB_CFG" ]]; then
    local bak="${SB_CFG}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$SB_CFG" "$bak"
    info "Бэкап конфига: $bak"
  fi

  mkdir -p "$SB_DIR"
  tmp=$(mktemp)
  render_singbox_config "$tpl" "$nodes_file" "$secret" "$default_tag" "$WAN_IF" >"$tmp" \
    || { rm -f "$tmp"; die "не удалось собрать config.json из шаблона"; }
  mv "$tmp" "$SB_CFG"
  chmod 600 "$SB_CFG"

  apply_mobile_vless_inbound

  "$SINGBOX_BIN" check -c "$SB_CFG"
  ok "config check passed"
  CONFIG_REBUILT=1
}

# Восстановить tagged inbound vless-mobile из отдельного 0600-файла состояния.
# Не создаёт inbound автоматически; неверное состояние — WARN, базовый конфиг без inbound.
apply_mobile_vless_inbound() {
  local state="${MOBILE_VLESS_STATE}"
  if [[ ! -f "$state" ]]; then
    return 0
  fi
  if ! jq -e . "$state" >/dev/null 2>&1; then
    echo "WARN: ${state} невалидный JSON — мобильный VLESS не восстановлен" >&2
    return 0
  fi
  local enabled
  enabled=$(jq -r '.enabled // false' "$state")
  if [[ "$enabled" != "true" ]]; then
    # убедиться, что старый inbound не остался после пересборки (его и так нет в свежем jq)
    info "мобильный VLESS выключен в ${state} — inbound не добавляю"
    return 0
  fi
  local uuid pk sid port hs hsport sni
  uuid=$(jq -r '.uuid // empty' "$state")
  pk=$(jq -r '.private_key // empty' "$state")
  sid=$(jq -r '.short_id // empty' "$state")
  port=$(jq -r '.port // 8443' "$state")
  hs=$(jq -r '.handshake_server // empty' "$state")
  hsport=$(jq -r '.handshake_port // 443' "$state")
  sni=$(jq -r '.server_name // empty' "$state")
  if [[ -z "$uuid" || -z "$pk" || -z "$sid" || -z "$hs" || -z "$sni" ]]; then
    echo "WARN: ${state} enabled, но не хватает полей (uuid/private_key/short_id/handshake/server_name) — inbound не добавлен, файл сохранён" >&2
    return 0
  fi
  if [[ "$port" == "80" || "$port" == "443" ]]; then
    echo "WARN: мобильный VLESS порт ${port} конфликтует с NPM — inbound не добавлен" >&2
    return 0
  fi
  local tmp
  tmp=$(mktemp)
  if ! jq --arg uuid "$uuid" --arg pk "$pk" --arg sid "$sid" \
      --argjson port "$port" --arg hs "$hs" --argjson hsport "$hsport" --arg sni "$sni" '
    (.inbounds // []) as $ins |
    ($ins | map(select(.tag != "vless-mobile"))) as $base |
    .inbounds = ($base + [{
      type: "vless",
      tag: "vless-mobile",
      listen: "0.0.0.0",
      listen_port: $port,
      users: [{ uuid: $uuid, flow: "xtls-rprx-vision" }],
      tls: {
        enabled: true,
        server_name: $sni,
        reality: {
          enabled: true,
          handshake: { server: $hs, server_port: $hsport },
          private_key: $pk,
          short_id: [$sid]
        }
      }
    }])
  ' "$SB_CFG" > "$tmp"; then
    rm -f "$tmp"
    echo "WARN: не удалось вставить vless-mobile в config.json" >&2
    return 0
  fi
  mv "$tmp" "$SB_CFG"
  chmod 600 "$SB_CFG"
  ok "восстановлен inbound vless-mobile (port ${port})"
}

# Короткое имя → outbound tag: germany → vless-germany (уже с префиксом не трогаем).
normalize_vless_tag() {
  local raw="$1"
  if [[ "$raw" == vless-* ]]; then
    echo "$raw"
  else
    echo "vless-${raw}"
  fi
}

# --- ссылки vless:// (3x-ui) ---
#
# Формат 3x-ui (Reality):
#   vless://UUID@host:port?type=tcp&security=reality&pbk=…&fp=chrome&sni=…&sid=…&spx=%2F&flow=xtls-rprx-vision#remark
# Шаблон outbound (render_singbox_config) умеет только VLESS + Reality поверх TCP
# (type=tcp, у Xray он же raw), flow пусто или xtls-rprx-vision, uTLS fingerprint.
# spx (spiderX), pqv (ML-DSA) и прочее sing-box не использует — игнорируем.
# Без eval: значения только через переменные и jq --arg. Секреты в ошибки не попадают.

VLESS_FINGERPRINTS="chrome firefox edge safari 360 qq ios android random randomized"

# URL-decode (%XX, UTF-8 байты). $2=1 — ещё «+» → пробел (query из URLSearchParams).
# rc 1: битый %, %00 или управляющие символы.
vless_urldecode() {
  local s="$1" plus="${2:-0}" out
  [[ "$plus" == "1" ]] && s=${s//+/ }
  if [[ "$s" == *%* ]]; then
    local rest="$s"
    while [[ "$rest" == *%* ]]; do
      rest=${rest#*%}
      [[ "$rest" =~ ^[0-9A-Fa-f]{2} ]] || return 1
      [[ "${rest:0:2}" != "00" ]] || return 1
    done
    s=${s//\\/\\\\}
    s=${s//%/\\x}
    out=$(printf '%b.' "$s") || return 1
    out=${out%.}
  else
    out=$s
  fi
  [[ "$out" != *[[:cntrl:]]* ]] || return 1
  printf '%s' "$out"
}

# Короткое имя узла из #remark: латиница/цифры/дефис, нижний регистр. Пусто — «».
vless_name_from_remark() {
  local r="$1" out=""
  r=$(printf '%s' "$r" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C sed -e 's/[^a-z0-9_-]\{1,\}/-/g' -e 's/--*/-/g' -e 's/^[-_]*//' -e 's/[-_]*$//')
  out=${r:0:40}
  out=${out%-}
  printf '%s' "$out"
}

# parse_vless_link <ссылка> → JSON узла в stdout:
#   {server, server_port, uuid, server_name, public_key, short_id, flow, fingerprint,
#    remark, name, ignored:[…]}
# Ошибка → сообщение в stderr (без секретов), rc 1.
parse_vless_link() {
  local link="$1"
  link=${link//$'\r'/}
  link="${link#"${link%%[![:space:]]*}"}"
  link="${link%"${link##*[![:space:]]}"}"
  local err="ссылка vless://"

  if [[ -z "$link" ]]; then echo "${err}: пустая строка" >&2; return 1; fi
  if [[ "$link" =~ [[:space:]] ]]; then echo "${err}: внутри ссылки пробелы/переносы — скопируй её целиком одной строкой" >&2; return 1; fi
  local lower
  lower=$(printf '%s' "${link:0:8}" | LC_ALL=C tr 'A-Z' 'a-z')
  if [[ "$lower" != "vless://" ]]; then
    echo "${err}: должна начинаться с vless:// (vmess/trojan/ss не поддерживаются)" >&2; return 1
  fi
  local rest="${link:8}" fragment="" query="" authority
  if [[ "$rest" == *"#"* ]]; then fragment=${rest#*#}; rest=${rest%%#*}; fi
  if [[ "$rest" == *"?"* ]]; then query=${rest#*\?}; rest=${rest%%\?*}; fi
  authority=${rest%/}
  if [[ "$authority" != *"@"* ]]; then echo "${err}: нет UUID@адрес" >&2; return 1; fi

  local userinfo hostport uuid host port
  userinfo=${authority%@*}
  hostport=${authority##*@}
  uuid=$(vless_urldecode "$userinfo") || { echo "${err}: битое URL-кодирование в UUID" >&2; return 1; }
  if ! [[ "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    echo "${err}: UUID не в формате xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" >&2; return 1
  fi
  uuid=$(printf '%s' "$uuid" | LC_ALL=C tr 'A-F' 'a-f')

  if [[ "$hostport" == \[* ]]; then
    if ! [[ "$hostport" =~ ^\[([0-9A-Fa-f:.]+)\](:([0-9]*))?$ ]]; then
      echo "${err}: некорректный IPv6-адрес в []" >&2; return 1
    fi
    host=${BASH_REMATCH[1]}
    port=${BASH_REMATCH[3]}
    [[ "$host" == *:* ]] || { echo "${err}: в [] ожидается IPv6" >&2; return 1; }
  else
    if [[ "$hostport" == *:*:* ]]; then echo "${err}: IPv6-адрес должен быть в [] ([2001:db8::1]:443)" >&2; return 1; fi
    host=${hostport%%:*}
    port=""
    [[ "$hostport" == *:* ]] && port=${hostport#*:}
    host=$(vless_urldecode "$host") || { echo "${err}: битое URL-кодирование в адресе" >&2; return 1; }
    if ! [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
      echo "${err}: некорректный адрес сервера" >&2; return 1
    fi
  fi
  [[ -n "$port" ]] || port=443
  if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
    echo "${err}: порт должен быть 1–65535" >&2; return 1
  fi
  port=$((10#$port))

  # query → известные ключи (последнее значение выигрывает), остальные — в ignored
  local security="" type="" pbk="" sni="" sid="" fp="" flow="" encryption="" header_type=""
  local have_pbk=0 have_sni=0 have_sid=0
  local -a ignored=()
  local pair key val
  local IFS='&'
  local -a pairs=()
  read -r -a pairs <<<"$query"
  unset IFS
  for pair in "${pairs[@]}"; do
    [[ -n "$pair" ]] || continue
    key=${pair%%=*}
    val=""
    [[ "$pair" == *=* ]] && val=${pair#*=}
    key=$(vless_urldecode "$key" 1) || { echo "${err}: битое URL-кодирование в параметрах" >&2; return 1; }
    val=$(vless_urldecode "$val" 1) || { echo "${err}: битое URL-кодирование в параметре ${key}" >&2; return 1; }
    case "$key" in
      security) security=$val ;;
      type) type=$val ;;
      pbk) pbk=$val; have_pbk=1 ;;
      sni) sni=$val; have_sni=1 ;;
      sid) sid=$val; have_sid=1 ;;
      fp) fp=$val ;;
      flow) flow=$val ;;
      encryption) encryption=$val ;;
      headerType) header_type=$val ;;
      *) [[ "$key" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] && ignored+=("$key") ;;
    esac
  done

  case "${encryption:-none}" in
    none) ;;
    *) echo "${err}: encryption=${encryption:0:20} не поддерживается (нужно none)" >&2; return 1 ;;
  esac
  case "$security" in
    reality) ;;
    tls) echo "${err}: security=tls — шаблон поддерживает только Reality (security=reality)" >&2; return 1 ;;
    "") echo "${err}: нет security=reality — шаблон поддерживает только Reality" >&2; return 1 ;;
    *) echo "${err}: security=${security:0:20} не поддерживается (нужно reality)" >&2; return 1 ;;
  esac
  case "${type:-tcp}" in
    tcp|raw) ;;
    grpc|ws|xhttp|splithttp|httpupgrade|http|h2|kcp|quic)
      echo "${err}: транспорт type=${type} пока не поддерживается шаблоном (только tcp) — в 3x-ui выбери Transmission: TCP (RAW)" >&2; return 1 ;;
    *) echo "${err}: неизвестный транспорт type=${type:0:20} (поддерживается только tcp)" >&2; return 1 ;;
  esac
  case "${header_type:-none}" in
    none) ;;
    *) echo "${err}: headerType=${header_type:0:20} не поддерживается (нужно none)" >&2; return 1 ;;
  esac
  if [[ "$have_pbk" -ne 1 || -z "$pbk" ]]; then echo "${err}: нет pbk (Reality public key)" >&2; return 1; fi
  if ! [[ "$pbk" =~ ^[A-Za-z0-9_-]{42,44}=?$ ]]; then echo "${err}: pbk не похож на Reality public key (base64url, 43 символа)" >&2; return 1; fi
  if [[ "$have_sni" -ne 1 || -z "$sni" ]]; then echo "${err}: нет sni (Reality server_name)" >&2; return 1; fi
  if ! [[ "$sni" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then echo "${err}: некорректный sni" >&2; return 1; fi
  if [[ "$have_sid" -ne 1 || -z "$sid" ]]; then echo "${err}: нет sid (Reality short_id)" >&2; return 1; fi
  if ! [[ "$sid" =~ ^[0-9A-Fa-f]{1,16}$ ]] || (( ${#sid} % 2 != 0 )); then
    echo "${err}: sid должен быть hex чётной длины до 16 символов" >&2; return 1
  fi
  case "$flow" in
    ""|xtls-rprx-vision) ;;
    *) echo "${err}: flow=${flow:0:30} не поддерживается sing-box (нужно xtls-rprx-vision или пусто)" >&2; return 1 ;;
  esac
  local fp_note=""
  if [[ -z "$fp" ]]; then
    fp=chrome
  elif [[ " $VLESS_FINGERPRINTS " != *" $fp "* ]]; then
    fp_note="fp=${fp:0:20}"
    fp=chrome
  fi
  [[ -n "$fp_note" ]] && ignored+=("$fp_note → chrome")

  local remark=""
  if [[ -n "$fragment" ]]; then
    remark=$(vless_urldecode "$fragment") || remark=""
  fi
  local name
  name=$(vless_name_from_remark "$remark")

  local ign_json='[]'
  if [[ ${#ignored[@]} -gt 0 ]]; then
    ign_json=$(printf '%s\n' "${ignored[@]}" | jq -R . | jq -s 'unique')
  fi
  jq -n --arg server "$host" --argjson port "$port" --arg uuid "$uuid" \
    --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" --arg flow "$flow" --arg fp "$fp" \
    --arg remark "$remark" --arg name "$name" --argjson ignored "$ign_json" '{
      server: $server, server_port: $port, uuid: $uuid,
      server_name: $sni, public_key: $pbk, short_id: $sid,
      flow: $flow, fingerprint: $fp,
      remark: $remark, name: $name, ignored: $ignored
    }'
}

# Маска секрета для вывода: первые N и последние 4 символа.
vless_mask() {
  local s="$1" head="${2:-4}"
  if (( ${#s} <= head + 4 )); then
    printf '%s' "${s:0:2}…"
  else
    printf '%s…%s' "${s:0:head}" "${s: -4}"
  fi
}

# Сводка узла (JSON из parse_vless_link) без полного UUID/ключа.
vless_node_summary() {
  local json="$1" server port uuid sni pbk sid flow fp remark ign
  server=$(jq -r '.server' <<<"$json")
  port=$(jq -r '.server_port' <<<"$json")
  uuid=$(jq -r '.uuid' <<<"$json")
  sni=$(jq -r '.server_name' <<<"$json")
  pbk=$(jq -r '.public_key' <<<"$json")
  sid=$(jq -r '.short_id' <<<"$json")
  flow=$(jq -r '.flow' <<<"$json")
  fp=$(jq -r '.fingerprint' <<<"$json")
  remark=$(jq -r '.remark' <<<"$json")
  ign=$(jq -r '.ignored | join(", ")' <<<"$json")
  [[ "$server" == *:* ]] && server="[${server}]"
  echo "  remark:      ${remark:-—}"
  echo "  сервер:      ${server}:${port}"
  echo "  UUID:        $(vless_mask "$uuid" 8)"
  echo "  Reality:     sni=${sni}  pbk=$(vless_mask "$pbk" 6)  sid=${sid:0:2}…(${#sid})"
  echo "  flow / fp:   ${flow:-—} / ${fp}"
  [[ -z "$ign" ]] || echo "  не используется sing-box: ${ign}"
}

# Список ссылок для мастера без вопросов: NANOPI_VLESS_LINKS (по одной на строку)
# и/или файл NANOPI_VLESS_LINKS_FILE. Строка: «vless://…» или «имя vless://…»;
# пустые и начинающиеся с # — пропуск. Вывод — нормализованные строки.
vless_links_input() {
  local line
  {
    [[ -z "${NANOPI_VLESS_LINKS:-}" ]] || printf '%s\n' "$NANOPI_VLESS_LINKS"
    if [[ -n "${NANOPI_VLESS_LINKS_FILE:-}" ]]; then
      [[ -r "$NANOPI_VLESS_LINKS_FILE" ]] || die "NANOPI_VLESS_LINKS_FILE не читается: ${NANOPI_VLESS_LINKS_FILE}"
      cat "$NANOPI_VLESS_LINKS_FILE"
      echo
    fi
  } | while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line//$'\r'/}
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" && "$line" != \#* ]] || continue
    printf '%s\n' "$line"
  done
}

# Добавить узел в nodes.json: <nodes_file> <tag> <json-узла>
vless_nodes_add() {
  local file="$1" tag="$2" json="$3"
  jq --arg tag "$tag" --argjson n "$json" '. + [{
      tag: $tag, server: $n.server, server_port: $n.server_port, uuid: $n.uuid,
      server_name: $n.server_name, public_key: $n.public_key, short_id: $n.short_id,
      flow: $n.flow, fingerprint: $n.fingerprint
    }]' "$file" >"${file}.new" && mv "${file}.new" "$file"
}

vless_tag_used() {
  jq -e --arg t "$2" 'map(select(.tag == $t)) | length > 0' "$1" >/dev/null
}

# Узлы из NANOPI_VLESS_LINKS / NANOPI_VLESS_LINKS_FILE → nodes.json (без вопросов).
# Имя: явное «имя vless://…», иначе из #remark, иначе nodeN; дубли → -2, -3…
vless_nodes_from_links() {
  local file="$1" line name link json tag base i n=0
  while IFS= read -r line; do
    n=$((n + 1))
    name=""
    link=$line
    if [[ "$line" =~ ^([A-Za-z0-9_-]+)[[:space:]]+(.+)$ ]]; then
      name=${BASH_REMATCH[1]}
      link=${BASH_REMATCH[2]}
    fi
    json=$(parse_vless_link "$link") || die "узел #${n} из NANOPI_VLESS_LINKS: ссылка не принята (см. выше)"
    [[ -n "$name" ]] || name=$(jq -r '.name' <<<"$json")
    [[ -n "$name" ]] || name="node${n}"
    base=$(normalize_vless_tag "$name")
    tag=$base
    i=1
    while vless_tag_used "$file" "$tag"; do
      i=$((i + 1))
      tag="${base}-${i}"
    done
    vless_nodes_add "$file" "$tag" "$json"
    echo "  узел #${n}: ${tag}"
    vless_node_summary "$json"
  done < <(vless_links_input)
}

# Ручной ввод узла по полям (запасной вариант к ссылке) → JSON как у parse_vless_link.
vless_prompt_manual() {
  local server port uuid sni pubkey shortid
  server=$(ask "server (IP или hostname)")
  [[ -n "$server" ]] || die "server пуст"
  port=$(ask "port" "443")
  [[ "$port" =~ ^[0-9]+$ ]] || die "port должен быть числом"
  uuid=$(ask "UUID")
  [[ -n "$uuid" ]] || die "UUID пуст"
  sni=$(ask "Reality server_name (SNI)")
  [[ -n "$sni" ]] || die "server_name пуст"
  pubkey=$(ask "Reality public_key")
  [[ -n "$pubkey" ]] || die "public_key пуст"
  shortid=$(ask "Reality short_id")
  [[ -n "$shortid" ]] || die "short_id пуст"
  jq -n --arg server "$server" --argjson port "$port" --arg uuid "$uuid" \
    --arg sni "$sni" --arg pub "$pubkey" --arg sid "$shortid" '{
      server: $server, server_port: $port, uuid: $uuid,
      server_name: $sni, public_key: $pub, short_id: $sid,
      flow: "xtls-rprx-vision", fingerprint: "chrome",
      remark: "", name: "", ignored: []
    }'
}

# Один узел интерактивно: ссылка vless:// (Enter — по полям) → JSON в stdout.
# Вопросы и сводка — в stderr (stdout занят JSON).
vless_prompt_node() {
  local link json
  while true; do
    link=$(ask "ссылка vless:// из 3x-ui (Enter — ввести поля вручную)")
    if [[ -z "${link//[[:space:]]/}" ]]; then
      vless_prompt_manual
      return
    fi
    if ! json=$(parse_vless_link "$link"); then
      echo "  ссылка не принята — вставь другую или Enter для ручного ввода" >&2
      continue
    fi
    {
      echo "  Разобрано:"
      vless_node_summary "$json"
    } >&2
    if yesno "  Всё верно?" y; then
      printf '%s\n' "$json"
      return
    fi
  done
}

run_wizard_and_build() {
  local secret="$1"
  local nodes_tmp
  nodes_tmp=$(mktemp)
  echo '[]' > "$nodes_tmp"

  local n=0 tag_in tag json def_name default_tag=""
  if [[ -n "${NANOPI_VLESS_LINKS:-}${NANOPI_VLESS_LINKS_FILE:-}" ]]; then
    explain \
      "Узлы VLESS+Reality из NANOPI_VLESS_LINKS / NANOPI_VLESS_LINKS_FILE (ссылки vless:// из 3x-ui).
Имя узла — из «имя vless://…», иначе из #remark; префикс vless- добавится сам." \
      "Единый config.json с outbound’ами и selector proxy."
    vless_nodes_from_links "$nodes_tmp"
    [[ "$(jq 'length' "$nodes_tmp")" -ge 1 ]] || die "NANOPI_VLESS_LINKS: нет ни одной ссылки"
    default_tag=$(jq -r '.[0].tag' "$nodes_tmp")
    if [[ -n "${NANOPI_VLESS_DEFAULT:-}" ]]; then
      default_tag=$NANOPI_VLESS_DEFAULT
    fi
    if [[ "${NANOPI_YES:-}" != "1" ]]; then
      yesno "Собрать config.json из этих узлов?" y || die "отменено"
    fi
  else
    [[ "${NANOPI_YES:-}" != "1" ]] \
      || die "NANOPI_YES=1 без узлов: задай NANOPI_VLESS_LINKS или NANOPI_VLESS_LINKS_FILE (ссылки vless://)"
    explain \
      "Мастер VLESS+Reality: узлы по одному. Для каждого вставь ссылку vless:// из 3x-ui
(Inbounds → клиент → «Копировать ссылку»): адрес, порт, UUID, pbk, sni, sid, fp, flow
разберутся сами, покажу сводку (UUID и ключ — замаскированы) и спрошу подтверждение.
Enter вместо ссылки — ввод по полям, как раньше.
Когда хватит — откажись от «ещё один». Затем default для selector «proxy».

Важно: к имени автоматически добавится префикс vless-
  germany  →  vless-germany
  finland  →  vless-finland
Если введёшь уже vless-germany — префикс повторно не добавится." \
      "Единый config.json с outbound’ами и selector proxy."

    while true; do
      n=$((n + 1))
      echo
      echo "─── Узел #$n ───"
      json=$(vless_prompt_node)
      def_name=$(jq -r '.name // empty' <<<"$json")
      [[ -n "$def_name" ]] || def_name="node${n}"
      echo "  (к имени добавится префикс vless-, если его ещё нет)"
      while true; do
        tag_in=$(ask "короткое имя (латиница/цифры/дефис)" "$def_name")
        if ! [[ "$tag_in" =~ ^[A-Za-z0-9_-]+$ ]]; then
          echo "  некорректное имя — только латиница, цифры, _ и -" >&2
          continue
        fi
        tag=$(normalize_vless_tag "$tag_in")
        if vless_tag_used "$nodes_tmp" "$tag"; then
          echo "  tag уже использован: $tag — введи другое имя" >&2
          continue
        fi
        break
      done
      echo "  → tag в конфиге: $tag"
      vless_nodes_add "$nodes_tmp" "$tag" "$json"
      echo "  добавлен: $tag → $(jq -r '.server' <<<"$json"):$(jq -r '.server_port' <<<"$json")"
      [[ -n "$default_tag" ]] || default_tag=$tag

      if ! yesno "Добавить ещё один узел?" y; then
        break
      fi
    done
  fi

  local count
  count=$(jq 'length' "$nodes_tmp")
  [[ "$count" -ge 1 ]] || die "нужен хотя бы один VLESS-узел"

  echo
  echo "Добавленные теги:"
  jq -r '.[].tag' "$nodes_tmp" | sed 's/^/  - /'
  default_tag=$(ask "default для selector «proxy»" "$default_tag")
  # если ввели короткое имя — нормализуем
  default_tag=$(normalize_vless_tag "$default_tag")
  jq -e --arg t "$default_tag" 'map(select(.tag == $t)) | length == 1' "$nodes_tmp" >/dev/null \
    || die "default tag не из списка: $default_tag"

  build_singbox_config "$nodes_tmp" "$secret" "$default_tag"
  rm -f "$nodes_tmp" "${nodes_tmp}.new"
}

# Upgrade: по умолчанию оставить боевой config.json.
maybe_rebuild_config() {
  local secret="$1"
  if [[ "$INSTALL_MODE" != "upgrade" ]]; then
    run_wizard_and_build "$secret"
    return 0
  fi
  explain \
    "Боевой ${SB_CFG} уже есть. По умолчанию НЕ пересобираю (домены/узлы сохранятся).
Пересборка — только если явно согласишься (сделаю .bak)." \
    "config.json без изменений, либо новый из мастера VLESS"

  if yesno "Пересобрать config.json мастером VLESS? (сотрёт текущий после бэкапа)" n; then
    run_wizard_and_build "$secret"
  else
    info "Оставляю существующий ${SB_CFG}"
    CONFIG_REBUILT=0
    if [[ ! -f "$SB_CFG" ]]; then
      die "нет ${SB_CFG} — нужна полная установка или согласие на мастер"
    fi
    "$SINGBOX_BIN" check -c "$SB_CFG" || die "существующий config.json не проходит check"
  fi
}

start_singbox() {
  if [[ "$INSTALL_MODE" == "upgrade" && "$CONFIG_REBUILT" -eq 0 ]]; then
    explain \
      "Перезапущу sing-box (бинарь/unit могли обновиться; config без изменений)." \
      "sing-box active; есть sb-tun"
  else
    explain \
      "Запущу sing-box. Первый старт может занять до ~2 мин (remote rule-set)." \
      "sing-box active; есть sb-tun"
  fi

  mkdir -p /var/lib/sing-box
  systemctl restart sing-box
  local i
  for i in $(seq 1 60); do
    if systemctl is-active --quiet sing-box; then
      break
    fi
    sleep 2
  done
  systemctl is-active --quiet sing-box || {
    journalctl -u sing-box -n 40 --no-pager >&2 || true
    die "sing-box не active — смотри journalctl -u sing-box"
  }
  wait_singbox_ready || true
}

# Секрет clash_api из .env (без вывода).
clash_secret_from_env() {
  sed -n 's/^[[:space:]]*CLASH_SECRET=//p' "$OPT_ENV" 2>/dev/null | tail -1 | tr -d "\"'[:space:]"
}

clash_api_from_env() {
  local v
  v=$(sed -n 's/^[[:space:]]*CLASH_API=//p' "$OPT_ENV" 2>/dev/null | tail -1 | tr -d "\"'[:space:]")
  echo "${v:-http://127.0.0.1:9090}"
}

# Дождаться готовности: sb-tun, clash_api /version и первый запрос через proxy
# (на первом старте sing-box качает remote rule-set'ы — это десятки секунд).
# NANOPI_READY_TIMEOUT — потолок в секундах (по умолчанию 90). 0 — готов, 1 — таймаут
# (тесты ниже покажут, что именно не так).
wait_singbox_ready() {
  local timeout="${NANOPI_READY_TIMEOUT:-90}" t=0 tun api net secret api_url
  secret=$(clash_secret_from_env)
  api_url=$(clash_api_from_env)
  info "Жду готовности sing-box (до ${timeout} с): sb-tun, clash_api, выход через proxy…"
  while :; do
    tun=нет; api=нет; net=нет
    ip link show sb-tun >/dev/null 2>&1 && tun=да
    curl -fsS -o /dev/null --connect-timeout 2 --max-time 3 \
      -H "Authorization: Bearer ${secret}" "${api_url}/version" 2>/dev/null && api=да
    if [[ "$tun" == да && "$api" == да ]]; then
      curl -4 -fsS -o /dev/null --connect-timeout 5 --max-time 8 https://api.ipify.org 2>/dev/null && net=да
    fi
    if [[ "$tun" == да && "$api" == да && "$net" == да ]]; then
      ok "sing-box готов за ~${t} с (sb-tun, clash_api, proxy)"
      return 0
    fi
    if (( t >= timeout )); then
      break
    fi
    if (( t > 0 && t % 10 == 0 )); then
      info "… ${t}/${timeout} с: sb-tun=${tun} clash_api=${api} proxy=${net} (первый старт качает rule-set'ы)"
    fi
    sleep 2
    t=$((t + 2))
  done
  fail "sing-box не готов за ${timeout} с: sb-tun=${tun} clash_api=${api} proxy=${net}"
  echo "--- диагностика ---" >&2
  systemctl --no-pager --lines=0 status sing-box >&2 2>/dev/null || true
  journalctl -u sing-box -n 40 --no-pager >&2 2>/dev/null || true
  ip -br link show sb-tun >&2 2>/dev/null || echo "sb-tun: нет" >&2
  ss -Htlnp 2>/dev/null | grep -E ':9090\b' >&2 || echo "никто не слушает :9090" >&2
  echo "--- конец диагностики (тесты ниже покажут подробности) ---" >&2
  return 1
}

# --- проверка пути через proxy ---

# Текущий узел selector proxy: clash_api /proxies/proxy .now, иначе default из config.
selected_proxy_node() {
  local now
  now=$(curl -fsS --connect-timeout 3 --max-time 5 -H "Authorization: Bearer ${CLASH_SECRET}" \
    "${CLASH_API}/proxies/proxy" 2>/dev/null | jq -r '.now // empty' 2>/dev/null || true)
  if [[ -z "$now" ]]; then
    now=$(jq -r '[.outbounds[]? | select(.tag=="proxy")][0].default // empty' "$SB_CFG" 2>/dev/null || true)
  fi
  echo "$now"
}

# IPv4 адреса server узла (IP как есть, имя — getent ahostsv4), по одному в строке.
node_server_ipv4() {
  local tag="$1" server
  server=$(jq -r --arg t "$tag" '[.outbounds[]? | select(.tag==$t)][0].server // empty' "$SB_CFG" 2>/dev/null || true)
  [[ -n "$server" ]] || return 0
  if [[ "$server" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$server"
  else
    getent ahostsv4 "$server" 2>/dev/null | awk '{print $1}' | sort -u
  fi
}

# Открыть TLS к host:443 (держим ~6 с) и найти соединение в clash_api /connections.
# Печатает chains через запятую (напр. «finland,proxy» или «direct»); пусто — не видно.
proxy_chain_probe() {
  local host="${1:-api.ipify.org}" i chains=""
  ( sleep 6 | timeout 10 openssl s_client -connect "${host}:443" -servername "$host" -quiet \
      >/dev/null 2>&1 ) &
  for i in $(seq 1 12); do
    sleep 0.5
    chains=$(curl -fsS --connect-timeout 2 --max-time 3 -H "Authorization: Bearer ${CLASH_SECRET}" \
      "${CLASH_API}/connections" 2>/dev/null \
      | jq -r --arg h "$host" \
        '[.connections[]? | select(.metadata.host == $h) | (.chains // []) | join(",")] | map(select(. != "")) | .[0] // empty' \
        2>/dev/null || true)
    [[ -n "$chains" ]] && break
  done
  echo "$chains"
}

# Трафик к api.ipify.org (правило → proxy) должен идти через sing-box и узел selector.
# Одного «IP ≠ WAN» мало: в lab за другим роутером с VPN внешний IP тоже «чужой».
# Доказательство — цепочка соединения в clash_api; IP узла — дополнительная сверка.
test_proxy_path() {
  local node chains proxy_ip node_ips
  node=$(selected_proxy_node)
  proxy_ip=$(curl -4 -sS --connect-timeout 15 --max-time 25 https://api.ipify.org 2>/dev/null || true)
  chains=$(proxy_chain_probe api.ipify.org)
  node_ips=$(node_server_ipv4 "$node" | tr '\n' ' ' | sed 's/ $//')

  if [[ -z "$chains" ]]; then
    fail "соединение к api.ipify.org не видно в clash_api — трафик идёт мимо sing-box (TUN/auto_redirect не перехватывает)"
    [[ -n "$proxy_ip" ]] && info "внешний IP сейчас ${proxy_ip} — он может быть чужим (VPN вышестоящего роутера), это не доказательство"
    return 1
  fi
  if [[ ",${chains}," != *",proxy,"* ]] || [[ "${chains%%,*}" == direct ]]; then
    fail "api.ipify.org ушёл не через proxy: цепочка ${chains}"
    return 1
  fi
  if [[ -n "$node" && ",${chains}," != *",${node},"* ]]; then
    fail "api.ipify.org через proxy, но узел ${chains%%,*} ≠ выбранному ${node}"
    return 1
  fi
  ok "api.ipify.org идёт через sing-box: ${chains//,/ ← }"

  if [[ ! "$proxy_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "api.ipify.org не вернул IP (узел ${node:-?} не отвечает?)"
    return 1
  fi
  if [[ -n "$node_ips" && " ${node_ips} " == *" ${proxy_ip} "* ]]; then
    ok "внешний IP ${proxy_ip} = адрес узла ${node}"
  else
    ok "внешний IP ${proxy_ip} (адрес узла ${node}: ${node_ips:-?} — у VPS выход может быть с другого IP)"
  fi
  return 0
}

# auto_redirect: sing-box слушает redirect-порт на 0.0.0.0 (случайный, напр. 39439).
# sing-tun сам добавляет в table inet sing-box / chain input:
#   tcp dport <port> ct status ! dnat reject with tcp reset — снаружи (WAN/LAN) порт закрыт.
# Проверяем, что каждый не-loopback TCP listener sing-box (кроме мобильного VLESS)
# закрыт таким правилом.
test_redirect_port_closed() {
  command -v nft >/dev/null 2>&1 || { info "nft нет — пропускаю проверку redirect-порта"; return 0; }
  local ports p rules mv_port="" bad=0
  if [[ -f "$MOBILE_VLESS_STATE" ]] && jq -e '.enabled == true' "$MOBILE_VLESS_STATE" >/dev/null 2>&1; then
    mv_port=$(jq -r '.port // 8443' "$MOBILE_VLESS_STATE")
  fi
  ports=$(ss -Htlnp 2>/dev/null | awk '/"sing-box"/ {print $4}' \
    | grep -vE '^(127\.|\[::1\]|\[::ffff:127\.)' | sed 's/.*://' | sort -un)
  if [[ -z "$ports" ]]; then
    ok "sing-box не слушает TCP вне loopback"
    return 0
  fi
  rules=$(nft list chain inet sing-box input 2>/dev/null || true)
  for p in $ports; do
    [[ -n "$mv_port" && "$p" == "$mv_port" ]] && continue
    if grep -qE "tcp dport ${p}( .*)? reject" <<<"$rules"; then
      ok "redirect-порт sing-box :${p} закрыт снаружи (inet sing-box input reject)"
    else
      fail "sing-box слушает :${p} на всех адресах, а правила reject в inet sing-box input нет"
      bad=1
    fi
  done
  return "$bad"
}

# --- тесты ---

run_tests() {
  load_env
  step "T" "Приёмочные тесты (lab, до врезки)"
  explain \
    "Проверю: ip_forward, unit, TUN, ya.ru (direct), clash_api,
api.ipify.org через proxy (цепочка в clash_api + IP узла), redirect-порт закрыт снаружи,
${SCRIPTS_DIR}/proxy-select get." \
    "Все PASS. router-on не нужен."

  local failed=0 http_code

  if [[ $(sysctl -n net.ipv4.ip_forward) == 1 ]]; then
    ok "ip_forward=1"
  else
    fail "ip_forward != 1"; failed=1
  fi

  if systemctl is-active --quiet sing-box; then
    ok "sing-box active"
  else
    fail "sing-box not active"; failed=1
  fi

  if "$SINGBOX_BIN" check -c "$SB_CFG" >/dev/null; then
    ok "sing-box check"
  else
    fail "sing-box check"; failed=1
  fi

  if ip link show sb-tun >/dev/null 2>&1; then
    ok "интерфейс sb-tun"
  else
    fail "нет sb-tun"; failed=1
  fi

  http_code=$(curl -4 -sS --connect-timeout 10 --max-time 20 -o /dev/null -w '%{http_code}' https://ya.ru/ || echo "000")
  if [[ "$http_code" =~ ^[23] ]]; then
    ok "ya.ru HTTP $http_code (direct/.ru)"
  else
    fail "ya.ru HTTP $http_code"; failed=1
  fi

  # shellcheck disable=SC1090
  source "$OPT_ENV"
  if curl -fsS -o /dev/null --connect-timeout 3 \
      -H "Authorization: Bearer ${CLASH_SECRET}" \
      "${CLASH_API}/version"; then
    ok "clash_api ${CLASH_API}/version"
  else
    fail "clash_api недоступен"; failed=1
  fi

  test_proxy_path || failed=1

  test_redirect_port_closed || failed=1

  if [[ -x "$SCRIPTS_DIR/proxy-select" ]] && "$SCRIPTS_DIR/proxy-select" get >/dev/null; then
    ok "proxy-select get"
  else
    fail "proxy-select get"; failed=1
  fi

  # Мобильный VLESS: только если состояние включено — inbound и listener
  if [[ -f "$MOBILE_VLESS_STATE" ]] && jq -e '.enabled == true' "$MOBILE_VLESS_STATE" >/dev/null 2>&1; then
    local mv_port
    mv_port=$(jq -r '.port // 8443' "$MOBILE_VLESS_STATE")
    if jq -e '.inbounds[]? | select(.tag=="vless-mobile")' "$SB_CFG" >/dev/null 2>&1; then
      ok "config содержит inbound vless-mobile"
    else
      fail "enabled мобильный VLESS, но нет inbound vless-mobile в config"; failed=1
    fi
    if ss -ltn 2>/dev/null | grep -qE ":${mv_port}\\b"; then
      ok "слушает TCP :${mv_port}"
    else
      fail "не слушает TCP :${mv_port}"; failed=1
    fi
    # NPM DNAT 80/443 не должен пропасть из‑за мобильного VLESS
    if [[ -f /etc/nftables.d/nanopi-port-forwards.nft ]]; then
      if grep -qE 'dport (80|443)' /etc/nftables.d/nanopi-port-forwards.nft 2>/dev/null; then
        ok "port-forwards 80/443 на месте (NPM)"
      else
        info "port-forwards без 80/443 — ок, если NPM не настроен"
      fi
    fi
  else
    ok "мобильный VLESS не включён — пропускаю проверку :8443"
  fi

  echo
  if [[ "$failed" -eq 0 ]]; then
    echo "═══ ВСЕ ТЕСТЫ ПРОЙДЕНЫ ═══"
    return 0
  fi
  echo "═══ ЕСТЬ ОШИБКИ (см. FAIL выше) ═══"
  return 1
}

print_cutover() {
  cat <<EOF

════════════════════════════════════════════════════════════
 Инструкция по врезке (фаза D) — вручную, в окно простоя
════════════════════════════════════════════════════════════

Схема после врезки:
  ISP → WAN NanoPi (${WAN_IF}) → sing-box + NAT
      → LAN NanoPi (${LAN_IF}=10.10.10.1) dual-serve (DHCP + PPPoE-server)
      → WAN домашнего роутера (DHCP или PPPoE без правок)
      → LAN роутера → клиенты

0) Запасной путь
   • Запомни текущий SSH (lab).
   • После врезки SSH / панель: root@10.10.10.1 · http://10.10.10.1/
   • Откат: ISP → WAN роутера; NanoPi WAN (${WAN_IF}) → LAN роутера; затем:
       ${SCRIPTS_DIR}/lab-on

1) Клиенты роутера — убрать «старый» gateway/DNS
   • Gateway = сам роутер (обычно 192.168.1.1), НЕ старый прокси/VM.
   • DNS клиентов = 10.10.10.1 (NanoPi): dnsmasq → 94.140.14.14/15.15:53, sing-box перехватывает
     (hijack-dns) и резолвит через AdGuard DoH по proxy (фолбэк — напрямую; .ru/.su/.рф — напрямую).
     HAIRPIN_DNS_TARGET — подмена A белого WAN → NPM в LAN.

2) Роутерный профиль на NanoPi (lab-кабель ещё можно не трогать)
   ${SCRIPTS_DIR}/router-on
   Ожидание: ${LAN_IF}=10.10.10.1/24; nftables+dnsmasq+nanopi-pppoe-server;
   WAN_MODE=dhcp. SSH может моргнуть — подожди ~30 с.

3) Кабели (питание NanoPi не выключать)
   1. Вынь lab из WAN NanoPi (${WAN_IF}) ← LAN роутера.
   2. ISP → WAN NanoPi (${WAN_IF}).
   3. LAN NanoPi (${LAN_IF}) → WAN-порт роутера.
   4. Подожди 30–60 с.

4) WAN роутера
   • DHCP → 10.10.10.100–200, шлюз/DNS 10.10.10.1; или
   • PPPoE (любые креды) → session к NanoPi, peer 10.10.10.2.
   • Клиенты: LAN роутера, gateway = роутер.

5) Если ISP на NanoPi — PPPoE (не DHCP)
   В панели http://10.10.10.1/ или:
     ${SCRIPTS_DIR}/wan-pppoe <user> <pass> [vlan]
   Откат на DHCP: ${SCRIPTS_DIR}/wan-dhcp
   Статус: ${SCRIPTS_DIR}/wan-status | jq .

6) Проверки
   С ПК: ping роутера; ping 10.10.10.1; браузер → панель.
   С NanoPi (ssh root@10.10.10.1):
     ip -br addr
     systemctl is-active sing-box nftables dnsmasq nanopi-pppoe-server
     curl -4 -sS https://ya.ru/ -o /dev/null -w '%{http_code}\n'
     curl -4 -sS https://api.ipify.org; echo
     ${SCRIPTS_DIR}/proxy-select get

После успешной установки и тестов этот install-singbox.sh можно удалить.
Остаётся:
  ${OPT_ENV}
  ${SB_CFG}
  ${SCRIPTS_DIR}/

WebUI: отдельно — install-webui.sh (скачивает release с GitHub).
Lab PPPoE без ISP: см. lab/CHECKLIST.md в репозитории.

EOF
}

usage() {
  cat <<EOF
Usage: $0 [install|status|test]

  (без аргументов / install)  установка или обновление (авто)
  status                      диагностика
  test                        приёмочные тесты

Повторный install безопасен для router-режима:
  не mask dnsmasq / не stop nftables; config.json по умолчанию не трогает.
  NANOPI_YES=1 — без вопросов (для WebUI; config не пересобирает).

Постоянные команды:
  ${SCRIPTS_DIR}/router-on
  ${SCRIPTS_DIR}/lab-on
  ${SCRIPTS_DIR}/wan-dhcp
  ${SCRIPTS_DIR}/wan-pppoe [user] [pass] [vlan]
  ${SCRIPTS_DIR}/wan-status
  ${SCRIPTS_DIR}/proxy-select list|get|set <tag>
EOF
  exit 1
}

# Подтянуть шаблон nft (include port-forwards) без смены dual-serve.
refresh_nft_if_router() {
  detect_router_live
  [[ "$ROUTER_LIVE" -eq 1 ]] || return 0
  # shellcheck disable=SC1091
  source "$SCRIPTS_DIR/common.sh"
  nanopi_load_env
  info "Router live: обновляю nftables.conf + restart nftables (port-forwards.nft сохраняется)"
  nanopi_write_nft "$WAN_IF"
  nanopi_restart_nftables
}

# Сохранить копию установщика и опционально EDGE_VERSION (из релиза / WebUI).
install_self_copy() {
  local src="${BASH_SOURCE[0]:-$0}"
  mkdir -p "$OPT_ROOT"
  if [[ -f "$src" && "$(readlink -f "$src" 2>/dev/null || echo "$src")" != "$(readlink -f "$SELF_INSTALL" 2>/dev/null || echo "$SELF_INSTALL")" ]]; then
    install -m 755 "$src" "$SELF_INSTALL"
    info "Установщик → ${SELF_INSTALL}"
  elif [[ -f "$src" && ! -f "$SELF_INSTALL" ]]; then
    install -m 755 "$src" "$SELF_INSTALL"
    info "Установщик → ${SELF_INSTALL}"
  fi
  if [[ -n "${EDGE_VERSION:-}" ]]; then
    touch "$OPT_ENV"
    chmod 600 "$OPT_ENV"
    env_set_kv EDGE_VERSION "$EDGE_VERSION"
    info "EDGE_VERSION=${EDGE_VERSION}"
  fi
}

cmd_install() {
  need_root
  load_env
  detect_install_mode
  detect_router_live

  if [[ "$INSTALL_MODE" == "upgrade" ]]; then
    cat <<EOF
╔══════════════════════════════════════════════════════════╗
║  NanoPi edge · UPDATE                                    ║
║  scripts / пакеты / sing-box · config по умолчанию as-is ║
╚══════════════════════════════════════════════════════════╝

Режим: upgrade (автодетект повторного запуска)
Router live: ${ROUTER_LIVE} (1 = dnsmasq/nft не гасим)
Сохраняю: ${SB_CFG}, CLASH_SECRET, WAN_MODE/PPPoE, port-forwards, hairpin (+ исключения)
Обновляю: ${SCRIPTS_DIR}/, пакеты, бинарь sing-box, unit, ключи .env

EOF
  else
    cat <<EOF
╔══════════════════════════════════════════════════════════╗
║  NanoPi edge install (схема B)                           ║
║  Первая установка · без WebUI                            ║
╚══════════════════════════════════════════════════════════╝

Предпосылки:
  • Свежая Armbian (aarch64) или Debian 12/13 (x86_64), root, интернет
  • WAN NanoPi в LAN домашнего роутера (lab)
  • VLESS+Reality под рукой
  • Врезку сейчас НЕ делаем

После успеха останутся
  ${OPT_ROOT}/.env, scripts/, /etc/sing-box/config.json
Повторный запуск этого скрипта = безопасный upgrade.

EOF
  fi

  yesno "Продолжить?" y || exit 0

  step 1 "Инвентарь"
  explain \
    "Сниму инвентарь ОС/сети." \
    "Адреса и default route."
  show_inventory
  if [[ "$INSTALL_MODE" == "fresh" ]]; then
    yesno "Похоже на lab. Продолжаем?" y || exit 0
  fi

  check_singbox_pkg
  if [[ "$INSTALL_MODE" == "fresh" ]]; then
    check_net_stack
  fi

  step 2 "Интерфейсы WAN/LAN"
  prompt_interfaces

  step 3 "Каталог ${OPT_ROOT} + scripts"
  explain \
    "Запишу/обновлю постоянные scripts/ (router-on, wan-*, lab-on, proxy-select)." \
    "${SCRIPTS_DIR}/router-on и остальные на месте"
  mkdir -p "$OPT_ROOT"
  install_scripts_bundle
  install_self_copy

  step 4 "Пакеты"
  install_packages

  step 5 "Бинарник sing-box + unit"
  install_singbox_binary
  install_service_units

  step 6 ".env (${OPT_ENV})"
  gen_clash_secrets
  # EDGE_VERSION мог прийти из WebUI — дописать после merge/fresh
  if [[ -n "${EDGE_VERSION:-}" ]]; then
    env_set_kv EDGE_VERSION "$EDGE_VERSION"
  fi

  step 6b "Hairpin DNS (опционально)"
  prompt_hairpin_dns

  step 7 "config.json"
  maybe_rebuild_config "$CLASH_SECRET_VALUE"

  if [[ "$INSTALL_MODE" == "upgrade" ]]; then
    step 8 "nftables (если router)"
    refresh_nft_if_router
  fi

  step 9 "Запуск sing-box"
  start_singbox

  if [[ "$INSTALL_MODE" == "upgrade" ]]; then
    if yesno "Прогнать приёмочные тесты?" n; then
      if ! run_tests; then
        echo
        echo "Тесты с ошибками. journalctl -u sing-box -n 80 --no-pager"
        exit 1
      fi
    else
      info "Тесты пропущены"
    fi
    echo
    info "Upgrade готов. Router/WAN не переключал — система должна остаться как была."
    info "WebUI отдельно: install-webui.sh (если нужна панель / порты)."
    return 0
  fi

  if ! run_tests; then
    echo
    echo "Установка с ошибками тестов. journalctl -u sing-box -n 80 --no-pager"
    print_cutover
    exit 1
  fi

  print_cutover
  info "Готово. Повторный запуск этого скрипта безопасен (upgrade)."
}

main() {
  local cmd="${1:-install}"
  case "$cmd" in
    install|"")
      cmd_install
      ;;
    status)
      need_root
      cmd_status
      ;;
    test)
      need_root
      run_tests
      ;;
    -h|--help|help)
      usage
      ;;
    router-on|lab-on|proxy|upgrade)
      die "неизвестная команда «${cmd}». Используй: install | status | test (upgrade — авто при повторном install)"
      ;;
    *)
      usage
      ;;
  esac
}

# NANOPI_INSTALL_LIB_ONLY=1 — только подключить функции (тесты), без main.
[[ -n "${NANOPI_INSTALL_LIB_ONLY:-}" ]] || main "$@"
