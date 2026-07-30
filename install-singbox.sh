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
# Повседневное управление — /opt/nanopi-edge/scripts/:
#   router-on | lab-on | wan-dhcp | wan-pppoe | wan-status | proxy-select | hairpin-dns-refresh
#   inbound-status   # метаданные мобильного VLESS (без секретов)
#
set -euo pipefail

SINGBOX_VERSION="${SINGBOX_VERSION:-1.13.14}"
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

# --- постоянные скрипты в /opt/nanopi-edge/scripts ---

write_ops_scripts() {
  explain \
    "Запишу постоянные утилиты в ${SCRIPTS_DIR}/
(router-on, lab-on, wan-dhcp, wan-pppoe, wan-status, proxy-select, hairpin-dns-refresh,
inbound-status, common.sh).
Они читают ${OPT_ENV} и не зависят от install.sh — его потом можно удалить." \
    "Скрипты executable на месте"

  mkdir -p "$SCRIPTS_DIR"

  cat > "$SCRIPTS_DIR/common.sh" <<'EOF'
#!/bin/bash
# Общие хелперы для /opt/nanopi-edge/scripts/* (source, не запускать).
# shellcheck shell=bash

ENV_FILE="${ENV_FILE:-/opt/nanopi-edge/.env}"
NETPLAN_DIR="${NETPLAN_DIR:-/etc/netplan}"
PPP_PEER="${PPP_PEER:-/etc/ppp/peers/nanopi-wan}"
PPP_SECRET_FILE="${PPP_SECRET_FILE:-/etc/ppp/nanopi-wan.secret}"
PPP_SERVER_OPTS="${PPP_SERVER_OPTS:-/etc/ppp/pppoe-server-options}"
PPPOE_SERVER_UNIT="${PPPOE_SERVER_UNIT:-nanopi-pppoe-server.service}"
WAN_PPPOE_UNIT="${WAN_PPPOE_UNIT:-nanopi-wan-pppoe.service}"

nanopi_load_env() {
  [[ -f "$ENV_FILE" ]] || { echo "ERROR: нет $ENV_FILE" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  WAN_IF=${WAN_IF:-end0}
  LAN_IF=${LAN_IF:-enp1s0}
  WAN_MODE=${WAN_MODE:-dhcp}
  PPPOE_USER=${PPPOE_USER:-}
  PPPOE_VLAN=${PPPOE_VLAN:-}
  HAIRPIN_DNS_TARGET=${HAIRPIN_DNS_TARGET:-}
}



# Локальный DNS hairpin: A-записи с белым IP WAN → HAIRPIN_DNS_TARGET
# (напр. Nginx Proxy Manager в LAN роутера).
# В публичном скрипте IP нет — только опциональный ключ в /opt/nanopi-edge/.env.
# Клиентам дома: DHCP DNS = 10.10.10.1 (NanoPi).
nanopi_write_hairpin_dns_alias() {
  local conf=/etc/dnsmasq.d/hairpin-alias.conf
  local target="${HAIRPIN_DNS_TARGET:-}"
  mkdir -p /etc/dnsmasq.d
  if [[ -z "$target" ]]; then
    rm -f "$conf"
    return 0
  fi
  if ! [[ "$target" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "WARN: HAIRPIN_DNS_TARGET='$target' не IPv4 — alias не пишу" >&2
    return 0
  fi
  local -a wan_ips=()
  local ifc ip
  for ifc in "${WAN_IF:-end0}" ppp0; do
    ip link show "$ifc" &>/dev/null || continue
    while read -r ip; do
      [[ -n "$ip" && "$ip" != "$target" ]] || continue
      wan_ips+=("$ip")
    done < <(ip -4 -o addr show dev "$ifc" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
  done
  if [[ ${#wan_ips[@]} -eq 0 ]]; then
    printf '%s\n' \
      "# Managed by nanopi-edge — HAIRPIN_DNS_TARGET=${target}" \
      "# WAN IPv4 пока нет; перезапишется после wan-dhcp/wan-pppoe / hairpin-dns-refresh" \
      >"$conf"
    return 0
  fi
  {
    echo "# Managed by nanopi-edge — hairpin DNS (do not edit)"
    echo "# HAIRPIN_DNS_TARGET=${target}  (из ${ENV_FILE})"
    local seen=""
    for ip in "${wan_ips[@]}"; do
      [[ " $seen " == *" $ip "* ]] && continue
      seen+=" $ip"
      echo "alias=${ip},${target}"
    done
  } >"$conf"
}


nanopi_set_env_kv() {
  local key="$1" val="$2"
  local tmp
  tmp=$(mktemp)
  if [[ -f "$ENV_FILE" ]]; then
    grep -v "^${key}=" "$ENV_FILE" >"$tmp" || true
  else
    : >"$tmp"
  fi
  # экранируем только перевод строки
  val=${val//$'\n'/}
  printf '%s=%s\n' "$key" "$val" >>"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}

nanopi_write_nft() {
  local wan="$1"
  mkdir -p /etc/nftables.d
  if [[ ! -f /etc/nftables.d/nanopi-port-forwards.nft ]]; then
    cat > /etc/nftables.d/nanopi-port-forwards.nft <<'FWD'
# Managed by nanopi-webui — port forwards (do not edit)
table inet nanopi_portforward {
	chain prerouting {
		type nat hook prerouting priority dstnat; policy accept;
	}
}
FWD
  fi
  cat > /etc/nftables.conf <<NFT
#!/usr/sbin/nft -f
# Минимальный NAT на краю + MSS clamp для PPPoE
flush ruleset

table inet nat {
	chain postrouting {
		type nat hook postrouting priority srcnat; policy accept;
		oifname "${wan}" masquerade
		oifname "ppp0" masquerade
	}
}

table inet filter {
	chain forward {
		type filter hook forward priority filter; policy accept;
		tcp flags syn tcp option maxseg size set 1452
	}
}

include "/etc/nftables.d/nanopi-port-forwards.nft"
NFT
}

nanopi_write_dnsmasq_lan() {
  local lan="$1" wan="$2"
  mkdir -p /etc/dnsmasq.d
  cat > /etc/dnsmasq.d/lan.conf <<DNS
# DHCP только на LAN NanoPi → WAN домашнего роутера
interface=${lan}
bind-dynamic
except-interface=lo
except-interface=${wan}
except-interface=sb-tun
except-interface=ppp0
except-interface=ppp1

domain-needed
bogus-priv
dhcp-authoritative

dhcp-range=10.10.10.100,10.10.10.200,12h
dhcp-option=option:router,10.10.10.1
dhcp-option=option:dns-server,10.10.10.1

no-resolv
server=94.140.14.14
server=94.140.15.15
DNS
  rm -f /etc/dnsmasq.d/README
}

nanopi_write_lan_netplan() {
  local lan="$1"
  cat > "$NETPLAN_DIR/50-router-lan.yaml" <<YAML
# NanoPi router: LAN (${lan}) = 10.10.10.1/24
network:
  version: 2
  renderer: networkd
  ethernets:
    ${lan}:
      dhcp4: false
      dhcp6: false
      optional: true
      ignore-carrier: true
      addresses:
        - 10.10.10.1/24
YAML
  chmod 600 "$NETPLAN_DIR/50-router-lan.yaml"
}

nanopi_write_pppoe_server_opts() {
  cat > "$PPP_SERVER_OPTS" <<'OPTS'
# NanoPi LAN PPPoE server — accept-any (в т.ч. пустые креды)
noauth
nologin
ms-dns 10.10.10.1
netmask 255.255.255.0
default-asyncmap
mtu 1492
mru 1492
lcp-echo-interval 30
lcp-echo-failure 4
noipdefault
nodefaultroute
noproxyarp
OPTS
  chmod 644 "$PPP_SERVER_OPTS"
}

# Accept-any для LAN-server + опциональная строка WAN-клиента (user/pass).
nanopi_write_ppp_auth_secrets() {
  local user="${1:-}" pass="${2:-}"
  umask 077
  cat > /etc/ppp/pap-secrets <<PAP
# NanoPi: LAN PPPoE-server accept-any + optional WAN client
*               *       ""                      *
*               *       *                       *
PAP
  cat > /etc/ppp/chap-secrets <<CHAP
# NanoPi: LAN PPPoE-server accept-any + optional WAN client
*               *       ""                      *
*               *       *                       *
CHAP
  if [[ -n "$user" || -n "$pass" ]]; then
    printf '"%s"\t*\t"%s"\t*\n' "$user" "$pass" >>/etc/ppp/pap-secrets
    printf '"%s"\t*\t"%s"\t*\n' "$user" "$pass" >>/etc/ppp/chap-secrets
  fi
  chmod 600 /etc/ppp/pap-secrets /etc/ppp/chap-secrets
}

nanopi_write_pppoe_server_unit() {
  local lan="$1"
  cat > "/etc/systemd/system/${PPPOE_SERVER_UNIT}" <<UNIT
[Unit]
Description=NanoPi LAN PPPoE server (accept-any)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/pppoe-server -F -I ${lan} -L 10.10.10.1 -R 10.10.10.2 -N 1 -C nanopi
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
}

# flush ruleset в /etc/nftables.conf сносит auto_redirect sing-box.
# После любого restart nftables / nft -f нужно поднять sing-box снова.
nanopi_restart_nftables() {
  systemctl restart nftables
  if systemctl is-active --quiet sing-box 2>/dev/null || systemctl is-enabled --quiet sing-box 2>/dev/null; then
    systemctl try-reload-or-restart sing-box 2>/dev/null || systemctl restart sing-box 2>/dev/null || true
  fi
}

nanopi_ensure_lan_dual_serve() {
  local lan wan
  lan=${LAN_IF:-enp1s0}
  wan=${WAN_IF:-end0}

  nanopi_write_lan_netplan "$lan"
  nanopi_write_dnsmasq_lan "$lan" "$wan"
  nanopi_write_nft "$wan"
  nanopi_write_pppoe_server_opts
  # не затираем WAN-клиентские строки — вызывающий пишет secrets сам
  if [[ ! -f /etc/ppp/pap-secrets ]]; then
    nanopi_write_ppp_auth_secrets "" ""
  fi
  nanopi_write_pppoe_server_unit "$lan"

  systemctl unmask dnsmasq 2>/dev/null || true
  systemctl enable nftables dnsmasq "$PPPOE_SERVER_UNIT"
  systemctl daemon-reload

  ip link set "$lan" up || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ip -4 -br addr show "$lan" 2>/dev/null | grep -q '10\.10\.10\.1' && break
    sleep 0.5
  done

  nanopi_restart_nftables
  nanopi_write_hairpin_dns_alias
systemctl restart dnsmasq
  systemctl restart "$PPPOE_SERVER_UNIT"
}

nanopi_stop_wan_pppoe() {
  systemctl disable --now "$WAN_PPPOE_UNIT" 2>/dev/null || true
  pkill -f 'pppd call nanopi-wan' 2>/dev/null || true
  rm -f "$PPP_PEER"
  if [[ -n "${PPPOE_VLAN:-}" ]]; then
    ip link delete "${WAN_IF}.${PPPOE_VLAN}" 2>/dev/null || true
  fi
  rm -f "$NETPLAN_DIR"/45-router-wan-vlan.yaml
}

nanopi_write_wan_dhcp_netplan() {
  local wan="$1"
  rm -f "$NETPLAN_DIR/30-ethernets-dhcp.yaml"
  rm -f "$NETPLAN_DIR/45-router-wan-vlan.yaml"
  cat > "$NETPLAN_DIR/40-router-wan-dhcp.yaml" <<YAML
# NanoPi router: WAN (${wan}) = DHCP от ISP
network:
  version: 2
  renderer: networkd
  ethernets:
    ${wan}:
      dhcp4: true
      dhcp6: false
      dhcp4-overrides:
        route-metric: 100
YAML
  chmod 600 "$NETPLAN_DIR/40-router-wan-dhcp.yaml"
}

nanopi_patch_singbox_exclude() {
  # exclude_interface:
  # - DHCP WAN: [WAN_IF]
  # - PPPoE WAN: [WAN_IF, ppp0, optional WAN_IF.VLAN]
  local cfg="${SINGBOX_CONFIG:-/etc/sing-box/config.json}"
  local wan="$WAN_IF"
  local vlan="${PPPOE_VLAN:-}"
  local mode="${WAN_MODE:-dhcp}"
  [[ -f "$cfg" ]] || return 0
  local tmp
  tmp=$(mktemp)
  if [[ "$mode" == "pppoe" ]]; then
    if [[ -n "$vlan" ]]; then
      jq --arg wan "$wan" --arg vif "${wan}.${vlan}" '
        (.inbounds[] | select(.type=="tun") | .exclude_interface) = [$wan, "ppp0", $vif]
      ' "$cfg" >"$tmp" && mv "$tmp" "$cfg"
    else
      jq --arg wan "$wan" '
        (.inbounds[] | select(.type=="tun") | .exclude_interface) = [$wan, "ppp0"]
      ' "$cfg" >"$tmp" && mv "$tmp" "$cfg"
    fi
  else
    jq --arg wan "$wan" '
      (.inbounds[] | select(.type=="tun") | .exclude_interface) = [$wan]
    ' "$cfg" >"$tmp" && mv "$tmp" "$cfg"
  fi
  chmod 600 "$cfg"
  if command -v sing-box >/dev/null 2>&1; then
    sing-box check -c "$cfg" >/dev/null 2>&1 || true
  fi
  systemctl try-reload-or-restart sing-box 2>/dev/null || systemctl restart sing-box 2>/dev/null || true
}

nanopi_read_ppp_password() {
  if [[ -f "$PPP_SECRET_FILE" ]]; then
    tr -d '\r\n' <"$PPP_SECRET_FILE"
  else
    echo -n ""
  fi
}

nanopi_write_ppp_password() {
  local pass="$1"
  umask 077
  printf '%s\n' "$pass" >"$PPP_SECRET_FILE"
  chmod 600 "$PPP_SECRET_FILE"
}
EOF

  cat > "$SCRIPTS_DIR/wan-dhcp" <<'EOF'
#!/bin/bash
# WAN = DHCP от ISP; LAN dual-serve не трогаем (кроме ensure).
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
nanopi_load_env

echo "==> wan-dhcp: ${WAN_IF} DHCP"

nanopi_stop_wan_pppoe
nanopi_write_wan_dhcp_netplan "$WAN_IF"
nanopi_set_env_kv WAN_MODE dhcp
# VLAN сбрасываем при откате на DHCP
nanopi_set_env_kv PPPOE_VLAN ""
PPPOE_VLAN=""

nanopi_write_ppp_auth_secrets "" ""
nanopi_ensure_lan_dual_serve

netplan apply
ip link set "$WAN_IF" up || true
# nftables снова (после netplan); exclude + restart sing-box — последним
nanopi_restart_nftables
nanopi_patch_singbox_exclude
nanopi_write_hairpin_dns_alias
systemctl restart dnsmasq

echo "[ok] wan-dhcp. WAN_MODE=dhcp"
EOF

  cat > "$SCRIPTS_DIR/wan-pppoe" <<'EOF'
#!/bin/bash
# WAN = PPPoE-клиент к ISP (+ опциональный VLAN). LAN dual-serve без изменений.
# Env: PPPOE_USER, PPPOE_VLAN (из .env). Пароль: /etc/ppp/nanopi-wan.secret
# CLI: wan-pppoe [user] [password] [vlan]
#      или PPPOE_USER=… PPPOE_PASS=… PPPOE_VLAN=… wan-pppoe
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
nanopi_load_env

USER_IN="${1:-${PPPOE_USER:-}}"
PASS_IN="${2:-${PPPOE_PASS:-}}"
VLAN_IN="${3:-${PPPOE_VLAN:-}}"

if [[ -z "$PASS_IN" && -f "$PPP_SECRET_FILE" && $# -lt 2 ]]; then
  PASS_IN=$(nanopi_read_ppp_password)
fi

if [[ -z "$USER_IN" && -z "$PASS_IN" ]]; then
  # пустые креды допустимы (редкий ISP); всё равно поднимаем peer
  :
fi

if [[ -n "$VLAN_IN" ]]; then
  if ! [[ "$VLAN_IN" =~ ^[0-9]+$ ]] || (( VLAN_IN < 1 || VLAN_IN > 4094 )); then
    echo "ERROR: PPPOE_VLAN должен быть 1–4094 или пусто" >&2
    exit 1
  fi
fi

echo "==> wan-pppoe: user=${USER_IN:-(empty)} vlan=${VLAN_IN:-(none)}"

nanopi_stop_wan_pppoe

# WAN ethernet: без DHCP, только L2 (+ VLAN)
rm -f "$NETPLAN_DIR/30-ethernets-dhcp.yaml" "$NETPLAN_DIR/40-router-wan-dhcp.yaml"

if [[ -n "$VLAN_IN" ]]; then
  cat > "$NETPLAN_DIR/45-router-wan-vlan.yaml" <<YAML
# NanoPi WAN PPPoE поверх VLAN ${VLAN_IN}
network:
  version: 2
  renderer: networkd
  ethernets:
    ${WAN_IF}:
      dhcp4: false
      dhcp6: false
      optional: true
  vlans:
    ${WAN_IF}.${VLAN_IN}:
      id: ${VLAN_IN}
      link: ${WAN_IF}
      dhcp4: false
      dhcp6: false
YAML
  chmod 600 "$NETPLAN_DIR/45-router-wan-vlan.yaml"
  NIC="nic-${WAN_IF}.${VLAN_IN}"
else
  rm -f "$NETPLAN_DIR/45-router-wan-vlan.yaml"
  cat > "$NETPLAN_DIR/40-router-wan-dhcp.yaml" <<YAML
# NanoPi WAN: L2 для PPPoE (без DHCP)
network:
  version: 2
  renderer: networkd
  ethernets:
    ${WAN_IF}:
      dhcp4: false
      dhcp6: false
      optional: true
YAML
  chmod 600 "$NETPLAN_DIR/40-router-wan-dhcp.yaml"
  NIC="nic-${WAN_IF}"
fi

nanopi_write_ppp_password "$PASS_IN"
nanopi_set_env_kv WAN_MODE pppoe
nanopi_set_env_kv PPPOE_USER "$USER_IN"
nanopi_set_env_kv PPPOE_VLAN "$VLAN_IN"
PPPOE_USER="$USER_IN"
PPPOE_VLAN="$VLAN_IN"

cat > "$PPP_PEER" <<PEER
# NanoPi WAN PPPoE client → ISP
plugin rp-pppoe.so
${NIC}
user "${USER_IN}"
noipdefault
defaultroute
replacedefaultroute
persist
maxfail 0
holdoff 5
mtu 1492
mru 1492
usepeerdns
lcp-echo-interval 30
lcp-echo-failure 4
nodetach
PEER
chmod 600 "$PPP_PEER"

cat > "/etc/systemd/system/${WAN_PPPOE_UNIT}" <<UNIT
[Unit]
Description=NanoPi WAN PPPoE client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/pppd call nanopi-wan
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

nanopi_ensure_lan_dual_serve
nanopi_write_ppp_auth_secrets "$USER_IN" "$PASS_IN"

netplan apply
ip link set "$WAN_IF" up || true
if [[ -n "$VLAN_IN" ]]; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ip link show "${WAN_IF}.${VLAN_IN}" &>/dev/null && break
    sleep 0.3
  done
fi

systemctl daemon-reload
systemctl enable "$WAN_PPPOE_UNIT"
systemctl restart "$WAN_PPPOE_UNIT"
# nftables снова; exclude + restart sing-box — последним (после flush)
nanopi_restart_nftables
nanopi_patch_singbox_exclude
nanopi_write_hairpin_dns_alias
systemctl restart dnsmasq

echo "[ok] wan-pppoe. Жди UP ppp0: journalctl -u ${WAN_PPPOE_UNIT} -f"
echo "    После UP ppp0: ${SCRIPT_DIR}/hairpin-dns-refresh"
EOF

  cat > "$SCRIPTS_DIR/wan-status" <<'EOF'
#!/bin/bash
# Статус WAN/LAN в JSON (для WebUI и CLI).
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
nanopi_load_env

mode=${WAN_MODE:-dhcp}
user=${PPPOE_USER:-}
vlan=${PPPOE_VLAN:-}
pass=$(nanopi_read_ppp_password)

ppp0_up=false
ppp0_ip=""
if ip link show ppp0 &>/dev/null; then
  ppp0_up=true
  ppp0_ip=$(ip -4 -o addr show ppp0 2>/dev/null | awk '{print $4}' | head -1 | cut -d/ -f1 || true)
fi

wan_ip=$(ip -4 -o addr show "$WAN_IF" 2>/dev/null | awk '{print $4}' | head -1 | cut -d/ -f1 || true)
lan_ip=$(ip -4 -o addr show "$LAN_IF" 2>/dev/null | awk '{print $4}' | head -1 | cut -d/ -f1 || true)

# LAN DHCP leases (активные)
dhcp_leases=0
lease_file=""
for f in /var/lib/misc/dnsmasq.leases /var/lib/dnsmasq/dnsmasq.leases; do
  if [[ -f "$f" ]]; then lease_file=$f; break; fi
done
if [[ -n "$lease_file" ]]; then
  dhcp_leases=$(awk 'NF>=4 {c++} END{print c+0}' "$lease_file")
fi

# LAN PPPoE session (обычно ppp1)
lan_pppoe_up=false
lan_pppoe_if=""
while read -r ifname; do
  [[ "$ifname" == ppp0 ]] && continue
  [[ "$ifname" =~ ^ppp[0-9]+$ ]] || continue
  lan_pppoe_up=true
  lan_pppoe_if=$ifname
  break
done < <(ip -br link 2>/dev/null | awk '{print $1}' | tr -d '@:*' || true)

dnsmasq_active=$(systemctl is-active dnsmasq 2>/dev/null || echo inactive)
pppoe_srv_active=$(systemctl is-active nanopi-pppoe-server.service 2>/dev/null || echo inactive)
wan_pppoe_active=$(systemctl is-active nanopi-wan-pppoe.service 2>/dev/null || echo inactive)

last_err=""
if [[ "$mode" == pppoe ]]; then
  last_err=$(journalctl -u nanopi-wan-pppoe.service -n 30 --no-pager -o cat 2>/dev/null \
    | grep -iE 'failed|error|timeout|CHAP|PAP|Connection terminated|Modem hangup' \
    | tail -3 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' || true)
fi

if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg mode "$mode" \
    --arg user "$user" \
    --arg password "$pass" \
    --arg vlan "$vlan" \
    --arg wan_if "$WAN_IF" \
    --arg lan_if "$LAN_IF" \
    --arg wan_ip "$wan_ip" \
    --arg lan_ip "$lan_ip" \
    --arg ppp0_ip "$ppp0_ip" \
    --argjson ppp0_up "$ppp0_up" \
    --argjson lan_pppoe_up "$lan_pppoe_up" \
    --arg lan_pppoe_if "$lan_pppoe_if" \
    --argjson dhcp_leases "$dhcp_leases" \
    --arg dnsmasq "$dnsmasq_active" \
    --arg pppoe_server "$pppoe_srv_active" \
    --arg wan_pppoe "$wan_pppoe_active" \
    --arg last_error "$last_err" \
    '{
      mode: $mode,
      user: $user,
      password: $password,
      vlan: $vlan,
      wan_if: $wan_if,
      lan_if: $lan_if,
      wan_ip: $wan_ip,
      lan_ip: $lan_ip,
      ppp0_up: $ppp0_up,
      ppp0_ip: $ppp0_ip,
      lan_dhcp_leases: $dhcp_leases,
      lan_pppoe_up: $lan_pppoe_up,
      lan_pppoe_if: $lan_pppoe_if,
      dnsmasq: $dnsmasq,
      pppoe_server: $pppoe_server,
      wan_pppoe_unit: $wan_pppoe,
      last_error: $last_error
    }'
else
  echo "{\"mode\":\"$mode\",\"error\":\"jq required\"}"
  exit 1
fi
EOF

  cat > "$SCRIPTS_DIR/router-on" <<'EOF'
#!/bin/bash
# Врезка: LAN dual-serve (DHCP + PPPoE-server) + WAN DHCP.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
nanopi_load_env

echo "==> router-on"
echo "    Кабели: ISP→WAN(${WAN_IF}), LAN(${LAN_IF})→WAN роутера."
echo "    LAN: DHCP + PPPoE-server (accept-any). WAN по умолчанию DHCP."
echo "    SSH может моргнуть на netplan apply."

if [[ "${NANOPI_YES:-}" != "1" ]]; then
  read -r -p "Продолжить? [y/N]: " reply || true
  [[ "${reply:-}" =~ ^[Yy]$ ]] || exit 0
fi

rm -f "$NETPLAN_DIR/30-ethernets-dhcp.yaml"
"$SCRIPT_DIR/wan-dhcp"

echo "[ok] router-on. Проверь: ip -br addr; ${LAN_IF}=10.10.10.1; wan-status"
EOF

  cat > "$SCRIPTS_DIR/lab-on" <<'EOF'
#!/bin/bash
# Откат в lab: WAN = DHCP в LAN домашнего роутера; dnsmasq/nft/pppoe off.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
nanopi_load_env

echo "==> lab-on: ${WAN_IF} DHCP (домашняя LAN). SSH может моргнуть."

nanopi_stop_wan_pppoe
systemctl disable --now "$PPPOE_SERVER_UNIT" 2>/dev/null || true
systemctl disable --now nftables 2>/dev/null || true
systemctl mask dnsmasq 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
rm -f /etc/dnsmasq.d/lan.conf
rm -f "$NETPLAN_DIR"/40-router-wan-dhcp.yaml \
      "$NETPLAN_DIR"/45-router-wan-vlan.yaml \
      "$NETPLAN_DIR"/50-router-lan.yaml

cat > "$NETPLAN_DIR/30-ethernets-dhcp.yaml" <<YAML
# NanoPi lab: WAN (${WAN_IF}) в LAN домашнего роутера
network:
  version: 2
  renderer: networkd
  ethernets:
    ${WAN_IF}:
      dhcp4: true
      dhcp6: false
YAML
chmod 600 "$NETPLAN_DIR/30-ethernets-dhcp.yaml"

nanopi_set_env_kv WAN_MODE dhcp
nanopi_set_env_kv PPPOE_VLAN ""

netplan apply
echo "[ok] lab-on. Проверь: ip -br addr"
EOF

  cat > "$SCRIPTS_DIR/proxy-select" <<'EOF'
#!/bin/bash
# CLI к clash_api: list | get | set <outbound-tag>
set -euo pipefail
ENV_FILE=/opt/nanopi-edge/.env
[[ -f "$ENV_FILE" ]] || { echo "ERROR: нет $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
[[ -n "${CLASH_API:-}" && -n "${CLASH_SECRET:-}" ]] || {
  echo "ERROR: в .env нет CLASH_API/CLASH_SECRET" >&2
  exit 1
}

usage() {
  echo "Usage: $0 list | get | set <outbound-tag>"
  exit 1
}

auth_hdr=( -H "Authorization: Bearer ${CLASH_SECRET}" )

wait_api() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS -o /dev/null --connect-timeout 1 "${auth_hdr[@]}" "${CLASH_API}/version" 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  echo "clash_api недоступен на ${CLASH_API}" >&2
  return 1
}

cmd="${1:-}"
case "$cmd" in
  list)
    wait_api
    curl -fsS "${auth_hdr[@]}" "${CLASH_API}/proxies" | jq '.proxies.proxy'
    ;;
  get)
    wait_api
    curl -fsS "${auth_hdr[@]}" "${CLASH_API}/proxies/proxy" | jq '{now, all, type}'
    ;;
  set)
    name="${2:-}"
    [[ -n "$name" ]] || usage
    wait_api
    curl -fsS -X PUT "${auth_hdr[@]}" \
      -H 'Content-Type: application/json' \
      -d "{\"name\":\"${name}\"}" \
      "${CLASH_API}/proxies/proxy"
    echo
    curl -fsS "${auth_hdr[@]}" "${CLASH_API}/proxies/proxy" | jq '{now, all}'
    ;;
  *)
    usage
    ;;
esac
EOF


  cat > "$SCRIPTS_DIR/hairpin-dns-refresh" <<'EOF'
#!/bin/bash
# Переписать /etc/dnsmasq.d/hairpin-alias.conf по HAIRPIN_DNS_TARGET + текущим WAN IP.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
nanopi_load_env
nanopi_write_hairpin_dns_alias
if [[ -n "${HAIRPIN_DNS_TARGET:-}" ]]; then
  systemctl restart dnsmasq
  echo "[ok] hairpin alias → ${HAIRPIN_DNS_TARGET}; dig @10.10.10.1 <домен>"
else
  systemctl restart dnsmasq 2>/dev/null || true
  echo "[ok] HAIRPIN_DNS_TARGET пуст — alias удалён"
fi
EOF

  cat > "$SCRIPTS_DIR/inbound-status" <<'EOF'
#!/bin/bash
# Метаданные мобильного VLESS inbound (без UUID/ключей/URI).
set -euo pipefail
# shellcheck disable=SC1091
source /opt/nanopi-edge/scripts/common.sh
nanopi_load_env

STATE="${MOBILE_VLESS_STATE:-/etc/sing-box/inbound-vless-reality.json}"
CFG="${SINGBOX_CONFIG:-/etc/sing-box/config.json}"

enabled=false
port=0
configured=false
inbound_present=false
listen_ok=false

if [[ -f "$STATE" ]]; then
  enabled=$(jq -r '.enabled // false' "$STATE" 2>/dev/null || echo false)
  port=$(jq -r '.port // 8443' "$STATE" 2>/dev/null || echo 0)
  if jq -e '(.uuid // "") != "" and (.private_key // "") != ""' "$STATE" >/dev/null 2>&1; then
    configured=true
  fi
fi

if [[ -f "$CFG" ]] && jq -e '.inbounds[]? | select(.tag=="vless-mobile")' "$CFG" >/dev/null 2>&1; then
  inbound_present=true
fi

if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -gt 0 ]]; then
  if ss -ltn 2>/dev/null | grep -qE ":${port}\\b"; then
    listen_ok=true
  fi
fi

jq -n \
  --argjson enabled "$enabled" \
  --argjson port "${port:-0}" \
  --argjson configured "$configured" \
  --argjson inbound_present "$inbound_present" \
  --argjson listen_ok "$listen_ok" \
  --arg singbox "$(systemctl is-active sing-box 2>/dev/null || echo unknown)" \
  '{
    enabled: $enabled,
    port: $port,
    configured: $configured,
    inbound_present: $inbound_present,
    listen_ok: $listen_ok,
    singbox: $singbox
  }'
EOF

  chmod 755 "$SCRIPTS_DIR"/router-on "$SCRIPTS_DIR"/lab-on \
    "$SCRIPTS_DIR"/wan-dhcp "$SCRIPTS_DIR"/wan-pppoe \
    "$SCRIPTS_DIR"/wan-status "$SCRIPTS_DIR"/proxy-select \
    "$SCRIPTS_DIR"/hairpin-dns-refresh "$SCRIPTS_DIR"/inbound-status
  chmod 644 "$SCRIPTS_DIR/common.sh"
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

install_sysctl() {
  explain \
    "Включу net.ipv4.ip_forward=1 persistently (/etc/sysctl.d/99-nanopi-forward.conf)." \
    "sysctl net.ipv4.ip_forward = 1"

  cat > /etc/sysctl.d/99-nanopi-forward.conf <<'EOF'
# NanoPi edge router (схема B)
net.ipv4.ip_forward = 1
EOF
  sysctl -p /etc/sysctl.d/99-nanopi-forward.conf
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

install_unit() {
  explain \
    "Поставлю systemd unit sing-box (enabled; старт после config.json)." \
    "systemctl is-enabled sing-box = enabled"

  cat > "$UNIT_DST" <<'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sing-box
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

  explain \
    "Соберу единый ${SB_CFG}: TUN, AdGuard DoH, remote ruleset’ы, VLESS,
selector proxy, clash_api. IP узлов (IPv4) и AdGuard — direct (антипетля).
Если есть ${MOBILE_VLESS_STATE} (мобильный VLESS) — восстановлю inbound." \
    "sing-box check успешен; mode 0600"

  if [[ -f "$SB_CFG" ]]; then
    local bak="${SB_CFG}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$SB_CFG" "$bak"
    info "Бэкап конфига: $bak"
  fi

  mkdir -p "$SB_DIR"
  jq -n \
    --slurpfile nodes "$nodes_file" \
    --arg secret "$secret" \
    --arg default "$default_tag" \
    --arg wan "$WAN_IF" '
    ($nodes[0]) as $n |
    ($n | map(select(.server | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")) | .server + "/32")) as $vps_cidrs |
    {
      log: { level: "warn", timestamp: true },
      dns: {
        servers: [
          { type: "local", tag: "dns-local" },
          {
            type: "https", tag: "dns-direct",
            server: "94.140.14.14", server_port: 443, path: "/dns-query",
            tls: { enabled: true, server_name: "dns.adguard-dns.com" }
          },
          {
            type: "https", tag: "dns-quad9",
            server: "9.9.9.9", server_port: 443, path: "/dns-query",
            tls: { enabled: true, server_name: "dns.quad9.net" }
          }
        ],
        final: "dns-direct",
        strategy: "ipv4_only"
      },
      inbounds: [
        {
          type: "tun", tag: "tun-in",
          interface_name: "sb-tun",
          address: ["172.19.0.1/30"],
          mtu: 1500,
          auto_route: true,
          strict_route: false,
          stack: "mixed",
          route_exclude_address: ["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16"],
          auto_redirect: true,
          # ppp0 добавляется только при WAN_MODE=pppoe (nanopi_patch_singbox_exclude)
          exclude_interface: [$wan]
        }
      ],
      outbounds: (
        [ { type: "direct", tag: "direct" } ]
        + ($n | map({
            type: "vless",
            tag: .tag,
            server: .server,
            server_port: .server_port,
            uuid: .uuid,
            network: ["tcp","udp"],
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
      ),
      route: {
        rules: [
          { action: "reject", ip_cidr: ["169.254.0.0/16"] },
          { port: 53, action: "hijack-dns" },
          { action: "route", outbound: "direct", ip_is_private: true },
          { action: "sniff", timeout: "300ms" },
          { port: 853, action: "reject" },
          {
            action: "route", outbound: "direct",
            ip_cidr: (
              ["94.140.14.14/32","94.140.15.15/32","9.9.9.9/32"] + $vps_cidrs
            )
          },
          { action: "route", outbound: "direct", protocol: "bittorrent" },
          {
            action: "route", outbound: "proxy",
            domain_suffix: ["2ip.io","ipify.org"]
          },
          {
            action: "route", outbound: "proxy",
            rule_set: [
              "geosite-category-ai-!cn",
              "geosite-ru-blocked",
              "geoip-ru-blocked",
              "geosite-telegram",
              "geoip-telegram"
            ]
          },
          {
            action: "route", outbound: "direct",
            domain_suffix: [".ru",".su",".рф"]
          }
        ],
        rule_set: [
          {
            type: "remote", tag: "geosite-ru-blocked", format: "binary",
            url: "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-ru-blocked.srs",
            download_detour: "direct", update_interval: "6h"
          },
          {
            type: "remote", tag: "geoip-ru-blocked", format: "binary",
            url: "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geoip/geoip-ru-blocked.srs",
            download_detour: "direct", update_interval: "6h"
          },
          {
            type: "remote", tag: "geosite-category-ai-!cn", format: "binary",
            url: "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-category-ai-!cn.srs",
            download_detour: "direct", update_interval: "6h"
          },
          {
            type: "remote", tag: "geosite-telegram", format: "binary",
            url: "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-telegram.srs",
            download_detour: "direct", update_interval: "6h"
          },
          {
            type: "remote", tag: "geoip-telegram", format: "binary",
            url: "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geoip/geoip-telegram.srs",
            download_detour: "direct", update_interval: "6h"
          }
        ],
        final: "direct",
        auto_detect_interface: true,
        default_domain_resolver: "dns-direct"
      },
      experimental: {
        cache_file: { enabled: true, path: "/var/lib/sing-box/cache.db" },
        clash_api: {
          external_controller: "127.0.0.1:9090",
          secret: $secret
        }
      }
    }
  ' > "$SB_CFG"
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
   • DNS клиентов = 10.10.10.1 (NanoPi) для hairpin доменов Nginx Proxy Manager
     (HAIRPIN_DNS_TARGET); иначе DNS = роутер.

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
  write_ops_scripts
  install_self_copy

  step 4 "Пакеты"
  install_packages

  step 5 "ip_forward"
  install_sysctl

  step 6 "Бинарник sing-box"
  install_singbox_binary

  step 7 "systemd unit"
  install_unit

  step 8 ".env (${OPT_ENV})"
  gen_clash_secrets
  # EDGE_VERSION мог прийти из WebUI — дописать после merge/fresh
  if [[ -n "${EDGE_VERSION:-}" ]]; then
    env_set_kv EDGE_VERSION "$EDGE_VERSION"
  fi


  step 9 "config.json"
  maybe_rebuild_config "$CLASH_SECRET_VALUE"

  if [[ "$INSTALL_MODE" == "upgrade" ]]; then
    step 10 "nftables (если router)"
    refresh_nft_if_router
  fi

  step 11 "Запуск sing-box"
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
