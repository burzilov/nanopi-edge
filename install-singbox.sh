#!/bin/bash
# install-singbox.sh — установка и безопасное обновление NanoPi R3S LTS (edge).
#
#   bash install-singbox.sh           # fresh или upgrade (авто)
#   bash install-singbox.sh status
#   bash install-singbox.sh test
#   NANOPI_YES=1 bash install-singbox.sh   # без вопросов (для WebUI / cron)
#
# Повторный запуск не гасит router-режим (dnsmasq/nftables) и по умолчанию
# не пересобирает /etc/sing-box/config.json.
#
# Повседневное управление — /opt/nanopi-edge/scripts/ (из release bundle):
#   router-on | lab-on | wan-dhcp | wan-pppoe | wan-status | proxy-select | hairpin-dns-refresh
#   inbound-status   # метаданные мобильного VLESS (без секретов)
#
set -euo pipefail

SINGBOX_VERSION="${SINGBOX_VERSION:-1.14.0}"
SINGBOX_BIN=/usr/local/bin/sing-box
OPT_ROOT=/opt/nanopi-edge
SCRIPTS_DIR="$OPT_ROOT/scripts"
OPT_ENV="$OPT_ROOT/.env"
SB_DIR=/etc/sing-box
SB_CFG="$SB_DIR/config.json"
MOBILE_VLESS_STATE="$SB_DIR/inbound-vless-reality.json"
UNIT_DST=/etc/systemd/system/sing-box.service
NETPLAN_DIR=/etc/netplan
SELF_INSTALL="$OPT_ROOT/install-singbox.sh"

EDGE_GITHUB_REPO="${WEBUI_GITHUB_REPO:-${EDGE_GITHUB_REPO:-burzilov/nanopi-edge}}"
SCRIPTS_ASSET=nanopi-edge-scripts.tar.gz
_SCRIPTS_INSTALL_TMP=

WAN_IF=end0
LAN_IF=enp1s0
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
  WAN_IF=${WAN_IF:-end0}
  LAN_IF=${LAN_IF:-enp1s0}
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
}

cmd_status() {
  load_env
  echo "WAN_IF=$WAN_IF  LAN_IF=$LAN_IF"
  echo "OPT_ENV=$OPT_ENV"
  echo "=== netplan ==="
  ls -la "$NETPLAN_DIR"/*.yaml 2>/dev/null || true
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
  apt-get install -y --no-install-recommends curl jq ca-certificates
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
  curl -fsSL -o "$tmp/$SCRIPTS_ASSET" "$download_url"
  printf '%s\n' "$tag" >"$tmp/BUNDLE_TAG"
}

install_scripts_bundle() {
  explain \
    "Скачаю ${SCRIPTS_ASSET} из GitHub Release → ${SCRIPTS_DIR}/
(router-on, lab-on, wan-dhcp, wan-pppoe, wan-status, proxy-select, hairpin-dns-refresh,
inbound-status, common.sh) + templates (sing-box.service, sysctl)." \
    "Скрипты executable на месте; sing-box unit enabled"

  ensure_download_deps
  mkdir -p "$SCRIPTS_DIR" "$OPT_ROOT"
  _SCRIPTS_INSTALL_TMP=$(mktemp -d)
  download_scripts_bundle "$_SCRIPTS_INSTALL_TMP"

  local stage bundle_root scripts_src templates_src archive
  archive="$_SCRIPTS_INSTALL_TMP/$SCRIPTS_ASSET"
  stage=$(mktemp -d)
  tar -xzf "$archive" -C "$stage"

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
  cp -a "$templates_src/." "$templates_dst/"
  chmod -R a+rX "$templates_dst"

  [[ -f "$templates_dst/sing-box.service" ]] || die "в bundle нет templates/sing-box.service"
  install -m 644 "$templates_dst/sing-box.service" "$UNIT_DST"
  [[ -f "$templates_dst/dnsmasq-sing-box.conf" ]] || die "в bundle нет templates/dnsmasq-sing-box.conf"
  mkdir -p /etc/systemd/system/dnsmasq.service.d
  install -m 644 "$templates_dst/dnsmasq-sing-box.conf" /etc/systemd/system/dnsmasq.service.d/sing-box.conf
  [[ -f "$templates_dst/99-nanopi-forward.conf" ]] || die "в bundle нет templates/99-nanopi-forward.conf"
  install -m 644 "$templates_dst/99-nanopi-forward.conf" /etc/sysctl.d/99-nanopi-forward.conf
  sysctl -p /etc/sysctl.d/99-nanopi-forward.conf

  systemctl daemon-reload
  systemctl enable sing-box

  rm -rf "$stage" "$_SCRIPTS_INSTALL_TMP"
  _SCRIPTS_INSTALL_TMP=
  ok "scripts bundle установлен"
}


# --- пакеты / sysctl / sing-box ---

install_packages() {
  detect_router_live
  if [[ "$ROUTER_LIVE" -eq 1 ]]; then
    explain \
      "apt update и пакеты: curl, jq, ca-certificates, nftables, dnsmasq, ppp, pppoe, openssl.
Router-режим уже активен — dnsmasq/nftables НЕ останавливаю и не mask." \
      "Пакеты на месте; LAN dual-serve без простоя"
  else
    explain \
      "apt update и минимум пакетов: curl, jq, ca-certificates, nftables, dnsmasq, ppp, pppoe, openssl.
nftables/dnsmasq сразу выключу — в lab не должны слушать LAN роутера." \
      "Пакеты на месте; dnsmasq masked; nftables не active до router-on."
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    curl jq ca-certificates nftables dnsmasq ppp pppoe openssl

  if [[ "$ROUTER_LIVE" -eq 1 ]]; then
    info "router live — пропускаю disable nftables / mask dnsmasq"
    return 0
  fi
  systemctl disable --now nftables 2>/dev/null || true
  systemctl mask dnsmasq 2>/dev/null || true
  systemctl stop dnsmasq 2>/dev/null || true
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
  curl -fsSL -o "$tmp/sb.tgz" "$url"
  tar -xzf "$tmp/sb.tgz" -C "$tmp"
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
  local def_wan="${WAN_IF:-end0}"
  local def_lan="${LAN_IF:-enp1s0}"
  if [[ "$INSTALL_MODE" == "upgrade" ]]; then
    explain \
      "Интерфейсы из ${OPT_ENV} (можно поправить). На R3S LTS обычно: WAN=end0, LAN=enp1s0." \
      "WAN_IF / LAN_IF сохранятся в ${OPT_ENV}"
  else
    explain \
      "Уточню имена Ethernet. На R3S LTS обычно: WAN-разъём = end0, LAN = enp1s0.
Lab-кабель сейчас в WAN-разъёме." \
      "WAN_IF / LAN_IF сохранятся в ${OPT_ENV}"
  fi

  echo "Сейчас:"
  ip -br link
  echo
  WAN_IF=$(ask "WAN interface (разъём WAN на корпусе)" "$def_wan")
  LAN_IF=$(ask "LAN interface (разъём LAN на корпусе)" "$def_lan")
  [[ -n "$WAN_IF" && -n "$LAN_IF" ]] || die "пустые имена интерфейсов"
  [[ "$WAN_IF" != "$LAN_IF" ]] || die "WAN и LAN не должны совпадать"
}


prompt_hairpin_dns() {
  # Фоновый апдейт из WebUI: не спрашиваем, только освежаем alias если ключ уже есть.
  if [[ "${NANOPI_YES:-}" == "1" ]]; then
    local existing=""
    if [[ -f "$OPT_ENV" ]] && grep -q '^HAIRPIN_DNS_TARGET=' "$OPT_ENV" 2>/dev/null; then
      existing=$(grep -E '^HAIRPIN_DNS_TARGET=' "$OPT_ENV" | tail -1 | cut -d= -f2- | tr -d '\r')
    fi
    HAIRPIN_DNS_TARGET=$existing
    if [[ -n "$existing" && -x "$SCRIPTS_DIR/hairpin-dns-refresh" ]]; then
      # shellcheck disable=SC1091
      source "$SCRIPTS_DIR/common.sh"
      nanopi_load_env 2>/dev/null || true
      HAIRPIN_DNS_TARGET=$existing
      nanopi_write_hairpin_dns_alias
      if systemctl is-active --quiet dnsmasq 2>/dev/null; then
        systemctl restart dnsmasq || true
      fi
      info "Hairpin DNS (NANOPI_YES): ${existing}"
    else
      info "Hairpin DNS (NANOPI_YES): пропуск"
    fi
    return 0
  fi

  explain \
    "Опционально: hairpin DNS для доменов Nginx Proxy Manager из домашней LAN.
Укажи LAN IP Nginx Proxy Manager (или хоста за роутером). dnsmasq подменит A-записи
с белым IP WAN на этот адрес. Пусто / Enter без значения = не использовать.
Потом на роутере: DNS клиентов = 10.10.10.1. Значение только в ${OPT_ENV}, не в git.
При upgrade: Enter = оставить текущее; «-» = выключить." \
    "HAIRPIN_DNS_TARGET в ${OPT_ENV} или отсутствует"

  local def=""
  if [[ -f "$OPT_ENV" ]] && grep -q '^HAIRPIN_DNS_TARGET=' "$OPT_ENV" 2>/dev/null; then
    def=$(grep -E '^HAIRPIN_DNS_TARGET=' "$OPT_ENV" | tail -1 | cut -d= -f2- | tr -d '\r')
  fi

  local val
  val=$(ask "LAN IP для hairpin DNS (Nginx Proxy Manager)" "$def")
  val=${val//[[:space:]]/}
  if [[ "$val" == "-" || "$val" == "none" || "$val" == "off" ]]; then
    val=""
  fi
  if [[ -z "$val" ]]; then
    if [[ -f "$OPT_ENV" ]]; then
      # убрать ключ, чтобы не остался пустой/старый
      local tmp
      tmp=$(mktemp)
      grep -v '^HAIRPIN_DNS_TARGET=' "$OPT_ENV" >"$tmp" || true
      mv "$tmp" "$OPT_ENV"
      chmod 600 "$OPT_ENV"
    fi
    HAIRPIN_DNS_TARGET=""
    info "Hairpin DNS выключен / пропущен"
    return 0
  fi
  if ! [[ "$val" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    die "HAIRPIN_DNS_TARGET: нужен IPv4, «-» или пусто"
  fi
  env_set_kv HAIRPIN_DNS_TARGET "$val"
  HAIRPIN_DNS_TARGET=$val
  info "HAIRPIN_DNS_TARGET=${val}"

  # если router уже жив — сразу применить alias
  if [[ -x "$SCRIPTS_DIR/hairpin-dns-refresh" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPTS_DIR/common.sh"
    nanopi_load_env 2>/dev/null || true
    HAIRPIN_DNS_TARGET=$val
    nanopi_write_hairpin_dns_alias
    if systemctl is-active --quiet dnsmasq 2>/dev/null; then
      systemctl restart dnsmasq
      info "dnsmasq alias обновлён"
    fi
  fi
}

build_singbox_config() {
  local nodes_file="$1" secret="$2" default_tag="$3"
  local tpl="$OPT_ROOT/templates/sing-box.config.json.tpl"
  local tmp rendered

  explain \
    "Соберу единый ${SB_CFG} из шаблона + узлы VLESS (мастер).
TUN, AdGuard DoH, remote ruleset’ы, selector proxy, clash_api.
IP узлов (IPv4) и AdGuard — direct (антипетля).
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
  rendered=$(mktemp)
  # Плейсхолдеры @WAN_IF@ / @CLASH_SECRET@ — остальное (outbounds, VPS /32) через jq.
  sed -e "s/@WAN_IF@/${WAN_IF}/g" \
      -e "s/@CLASH_SECRET@/${secret}/g" \
      "$tpl" >"$rendered"

  jq -n \
    --slurpfile nodes "$nodes_file" \
    --arg default "$default_tag" \
    --slurpfile base "$rendered" '
    ($nodes[0]) as $n |
    ($n | map(select(.server | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")) | .server + "/32")) as $vps_cidrs |
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
              flow: "xtls-rprx-vision",
              tls: {
                enabled: true,
                server_name: .server_name,
                utls: { enabled: true, fingerprint: "chrome" },
                reality: {
                  enabled: true,
                  public_key: .public_key,
                  short_id: .short_id
                }
              }
            }))
          + [{
              type: "selector",
              tag: "proxy",
              outbounds: ($n | map(.tag)),
              default: $default
            }]
        )
      | .route.rules = (
          .route.rules
          | map(
              if .ip_cidr then .ip_cidr += $vps_cidrs else . end
            )
        )
    )
  ' >"$tmp"
  mv "$tmp" "$SB_CFG"
  rm -f "$rendered"
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

run_wizard_and_build() {
  local secret="$1"
  local nodes_tmp
  nodes_tmp=$(mktemp)
  echo '[]' > "$nodes_tmp"

  explain \
    "Мастер VLESS+Reality: узлы по одному (короткое имя, server, port, UUID, Reality).
Когда хватит — откажись от «ещё один». Затем default для selector «proxy».

Важно: к имени автоматически добавится префикс vless-
  germany  →  vless-germany
  finland  →  vless-finland
Если введёшь уже vless-germany — префикс повторно не добавится." \
    "Единый config.json с outbound’ами и selector proxy."

  local n=0 tag_in tag server port uuid sni pubkey shortid default_tag=""
  while true; do
    n=$((n + 1))
    echo
    echo "─── Узел #$n ───"
    echo "  (к имени добавится префикс vless-, если его ещё нет)"
    tag_in=$(ask "короткое имя (латиница/цифры/дефис)" "node${n}")
    [[ "$tag_in" =~ ^[A-Za-z0-9_-]+$ ]] || die "некорректное имя: $tag_in"
    tag=$(normalize_vless_tag "$tag_in")
    [[ "$tag" =~ ^[A-Za-z0-9_-]+$ ]] || die "некорректный tag: $tag"
    echo "  → tag в конфиге: $tag"
    if jq -e --arg t "$tag" 'map(select(.tag == $t)) | length > 0' "$nodes_tmp" >/dev/null; then
      die "tag уже использован: $tag"
    fi
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

    jq --arg tag "$tag" --arg server "$server" --argjson port "$port" \
      --arg uuid "$uuid" --arg sni "$sni" --arg pub "$pubkey" --arg sid "$shortid" \
      '. + [{
        tag:$tag, server:$server, server_port:$port, uuid:$uuid,
        server_name:$sni, public_key:$pub, short_id:$sid
      }]' "$nodes_tmp" > "${nodes_tmp}.new"
    mv "${nodes_tmp}.new" "$nodes_tmp"
    echo "  добавлен: $tag → $server:$port"
    [[ -n "$default_tag" ]] || default_tag=$tag

    if ! yesno "Добавить ещё один узел?" y; then
      break
    fi
  done

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
  sleep 3
}

# --- тесты ---

run_tests() {
  load_env
  step "T" "Приёмочные тесты (lab, до врезки)"
  explain \
    "Проверю: ip_forward, unit, TUN, ya.ru (direct), api.ipify.org ≠ ${WAN_IF},
clash_api, ${SCRIPTS_DIR}/proxy-select get." \
    "Все PASS. router-on не нужен."

  local failed=0 wan_ip proxy_ip http_code

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

  wan_ip=$(ip -4 -o addr show dev "$WAN_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)
  proxy_ip=$(curl -4 -sS --connect-timeout 15 --max-time 25 https://api.ipify.org || true)
  if [[ -n "$proxy_ip" && "$proxy_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    if [[ -n "$wan_ip" && "$proxy_ip" == "$wan_ip" ]]; then
      fail "api.ipify.org = $proxy_ip совпадает с ${WAN_IF} — proxy не сработал"
      failed=1
    else
      ok "api.ipify.org = $proxy_ip (не ${WAN_IF}=${wan_ip:-?}) — proxy ок"
    fi
  else
    fail "api.ipify.org не вернул IP"; failed=1
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
   • DNS клиентов = 10.10.10.1 (NanoPi): dnsmasq → sing-box :5353 (DoH, race).
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
  nanopi_write_nft "${WAN_IF:-end0}"
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
Сохраняю: ${SB_CFG}, CLASH_SECRET, WAN_MODE/PPPoE, port-forwards
Обновляю: ${SCRIPTS_DIR}/, пакеты, бинарь sing-box, unit, ключи .env

EOF
  else
    cat <<EOF
╔══════════════════════════════════════════════════════════╗
║  NanoPi edge install (схема B)                           ║
║  Первая установка · без WebUI                            ║
╚══════════════════════════════════════════════════════════╝

Предпосылки:
  • Свежая Armbian, root, интернет
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

  step 5 "Бинарник sing-box"
  install_singbox_binary

  step 6 ".env (${OPT_ENV})"
  gen_clash_secrets
  # EDGE_VERSION мог прийти из WebUI — дописать после merge/fresh
  if [[ -n "${EDGE_VERSION:-}" ]]; then
    env_set_kv EDGE_VERSION "$EDGE_VERSION"
  fi


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

main "$@"
