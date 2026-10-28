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
NANOPI_TEMPLATE_DIR="${NANOPI_TEMPLATE_DIR:-/opt/nanopi-edge/templates}"
# ifupdown (Debian): основной файл и каталог фрагментов (source …/interfaces.d/*)
NET_IFACES_MAIN="${NET_IFACES_MAIN:-/etc/network/interfaces}"
NET_IFACES_DIR="${NET_IFACES_DIR:-/etc/network/interfaces.d}"
# Снимки сетевой конфигурации перед каждым изменением (ifupdown)
NANOPI_NET_BACKUP_ROOT="${NANOPI_NET_BACKUP_ROOT:-/var/backups/nanopi-edge}"

nanopi_load_env() {
  [[ -f "$ENV_FILE" ]] || { echo "ERROR: нет $ENV_FILE" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  if [[ -z "${WAN_IF:-}" ]]; then
    WAN_IF=$(nanopi_default_route_if)
    [[ -n "$WAN_IF" ]] || { echo "ERROR: в $ENV_FILE нет WAN_IF и default route не найден" >&2; exit 1; }
  fi
  if [[ -z "${LAN_IF:-}" ]]; then
    LAN_IF=$(nanopi_guess_lan_if "$WAN_IF")
    [[ -n "$LAN_IF" ]] || { echo "ERROR: в $ENV_FILE нет LAN_IF и второй Ethernet не найден" >&2; exit 1; }
  fi
  WAN_MODE=${WAN_MODE:-dhcp}
  PPPOE_USER=${PPPOE_USER:-}
  PPPOE_VLAN=${PPPOE_VLAN:-}
  HAIRPIN_DNS_TARGET=${HAIRPIN_DNS_TARGET:-}
}

# Рендер шаблона: плейсхолдеры @KEY@, далее пары KEY=value.
nanopi_render_template() {
  local template="$1" dest="$2"
  shift 2
  local src="${NANOPI_TEMPLATE_DIR}/${template}"
  [[ -f "$src" ]] || { echo "ERROR: нет шаблона ${src}" >&2; return 1; }
  local content key val
  content=$(<"$src")
  while [[ $# -gt 0 ]]; do
    key="${1%%=*}"
    val="${1#*=}"
    content=${content//@${key}@/$val}
    shift
  done
  printf "%s\n" "$content" >"$dest"
}

nanopi_install_template() {
  local template="$1" dest="$2" mode="${3:-644}"
  local src="${NANOPI_TEMPLATE_DIR}/${template}"
  [[ -f "$src" ]] || { echo "ERROR: нет шаблона ${src}" >&2; return 1; }
  install -m "$mode" "$src" "$dest"
}

# Локальный DNS hairpin: A-записи с белым IP WAN → HAIRPIN_DNS_TARGET
# (напр. Nginx Proxy Manager в LAN роутера).
# В публичном скрипте IP нет — только опциональный ключ в /opt/nanopi-edge/.env.
# Исключения «имя → адрес» (имя и поддомены ведут не на общий адрес, а на свой,
# например DSM на NAS) — в HAIRPIN_OVERRIDES_FILE (JSON, правит webui):
#   {"overrides":[{"name":"nas.example.org","ip":"192.168.1.90"}]}
# Для них пишется address=/имя/ip: dnsmasq отвечает сам, до форварда, и alias=
# (переписывает только ответы upstream) их не трогает.
# Клиентам дома: DHCP DNS = 10.10.10.1 (NanoPi).
HAIRPIN_DNS_CONF="${HAIRPIN_DNS_CONF:-/etc/dnsmasq.d/hairpin-alias.conf}"
HAIRPIN_OVERRIDES_FILE="${HAIRPIN_OVERRIDES_FILE:-/opt/nanopi-edge/hairpin-overrides.json}"

# Валидные исключения строками «имя ip» (битые пропускаются с WARN).
nanopi_hairpin_overrides() {
  local f="$HAIRPIN_OVERRIDES_FILE" name ip
  [[ -s "$f" ]] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "WARN: нет jq — исключения hairpin из $f не применены" >&2
    return 0
  fi
  local lines
  if ! lines=$(jq -r '.overrides[]? | "\(.name // "")\t\(.ip // "")"' "$f" 2>/dev/null); then
    echo "WARN: $f не читается как JSON — исключения hairpin пропущены" >&2
    return 0
  fi
  local label='[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
  while IFS=$'\t' read -r name ip; do
    [[ -n "$name" ]] || continue
    if ! [[ "$name" =~ ^(${label}\.)+${label}$ && ${#name} -le 253 ]]; then
      echo "WARN: hairpin: имя '$name' не похоже на DNS-имя — пропуск" >&2
      continue
    fi
    if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "WARN: hairpin: адрес '$ip' для $name не IPv4 — пропуск" >&2
      continue
    fi
    printf '%s %s\n' "$name" "$ip"
  done <<<"$lines"
}

nanopi_write_hairpin_dns_alias() {
  local conf="$HAIRPIN_DNS_CONF"
  local target="${HAIRPIN_DNS_TARGET:-}"
  mkdir -p "$(dirname "$conf")"
  if [[ -n "$target" ]] && ! [[ "$target" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "WARN: HAIRPIN_DNS_TARGET='$target' не IPv4 — alias не пишу" >&2
    target=""
  fi
  local overrides
  overrides=$(nanopi_hairpin_overrides)
  if [[ -z "$target" && -z "$overrides" ]]; then
    rm -f "$conf"
    return 0
  fi
  local -a wan_ips=()
  local ifc ip
  if [[ -n "$target" ]]; then
    for ifc in "${WAN_IF:-}" ppp0; do
      [[ -n "$ifc" ]] || continue
      ip link show "$ifc" &>/dev/null || continue
      while read -r ip; do
        [[ -n "$ip" && "$ip" != "$target" ]] || continue
        wan_ips+=("$ip")
      done < <(ip -4 -o addr show dev "$ifc" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
    done
  fi
  local tmp="${conf}.tmp"
  {
    echo "# Managed by nanopi-edge — hairpin DNS (do not edit)"
    [[ -z "$target" ]] || echo "# HAIRPIN_DNS_TARGET=${target}  (из ${ENV_FILE})"
    if [[ -n "$overrides" ]]; then
      echo "# Исключения (${HAIRPIN_OVERRIDES_FILE}): имя и поддомены → свой адрес, до alias"
      local name
      while read -r name ip; do
        echo "address=/${name}/${ip}"
      done <<<"$overrides"
    fi
    if [[ -n "$target" ]]; then
      if [[ ${#wan_ips[@]} -eq 0 ]]; then
        echo "# WAN IPv4 пока нет; перезапишется после wan-dhcp/wan-pppoe / hairpin-dns-refresh"
      fi
      local seen=""
      for ip in "${wan_ips[@]}"; do
        [[ " $seen " == *" $ip "* ]] && continue
        seen+=" $ip"
        echo "alias=${ip},${target}"
      done
    fi
  } >"$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$conf"
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
  val=${val//$'\n'/}
  printf '%s=%s\n' "$key" "$val" >>"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}

nanopi_write_nft() {
  local wan="$1"
  mkdir -p /etc/nftables.d
  if [[ ! -f /etc/nftables.d/nanopi-port-forwards.nft ]]; then
    nanopi_install_template nanopi-port-forwards.nft /etc/nftables.d/nanopi-port-forwards.nft 644
  fi
  nanopi_render_template nftables.conf.tpl /etc/nftables.conf WAN="$wan" \
    SSH_WAN_RULE="$(nanopi_ssh_wan_rule "$wan")"
}

# Порты sshd (sshd -T; несколько Port → несколько строк). Fallback: 22.
nanopi_ssh_ports() {
  local ports=""
  if [[ -n "${NANOPI_SSH_PORTS:-}" ]]; then
    ports=$(tr ', ' '\n\n' <<<"$NANOPI_SSH_PORTS")
  elif command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]]; then
    ports=$({ sshd -T 2>/dev/null || /usr/sbin/sshd -T 2>/dev/null; } | awk 'tolower($1)=="port"{print $2}')
  fi
  ports=$(grep -E '^[0-9]+$' <<<"$ports" | sort -un)
  [[ -n "$ports" ]] || ports=22
  printf '%s\n' "$ports"
}

# Строка nft для chain input: новые SSH-соединения с WAN/ppp0 — drop.
# SSH_ALLOW_WAN=1 в .env — не закрывать (комментарий вместо правила).
# Уже установленные сессии (ct state established) не рвутся.
nanopi_ssh_wan_rule() {
  local wan="$1" ports
  ports=$(nanopi_ssh_ports | paste -sd, - | sed 's/,/, /g')
  if [[ "${SSH_ALLOW_WAN:-0}" == "1" ]]; then
    printf '# SSH_ALLOW_WAN=1: SSH (порт %s) с WAN открыт' "$ports"
    return 0
  fi
  printf 'iifname { "%s", "ppp0" } tcp dport { %s } ct state new counter drop comment "nanopi-edge: SSH only from LAN"' "$wan" "$ports"
}

nanopi_write_dnsmasq_lan() {
  local lan="$1" wan="$2"
  mkdir -p /etc/dnsmasq.d
  nanopi_render_template dnsmasq-lan.conf.tpl /etc/dnsmasq.d/lan.conf LAN="$lan" WAN="$wan"
  rm -f /etc/dnsmasq.d/README
}

nanopi_write_lan_net() {
  nanopi_net_write lan lan LAN="$1"
}

nanopi_write_lab_net() {
  nanopi_net_write lab lab-wan WAN="$1"
}

nanopi_write_pppoe_server_opts() {
  nanopi_install_template pppoe-server-options "$PPP_SERVER_OPTS" 644
}

# Accept-any для LAN-server + опциональная строка WAN-клиента (user/pass).
nanopi_write_ppp_auth_secrets() {
  local user="${1:-}" pass="${2:-}"
  umask 077
  nanopi_install_template ppp-secrets-base /etc/ppp/pap-secrets 600
  nanopi_install_template ppp-secrets-base /etc/ppp/chap-secrets 600
  if [[ -n "$user" || -n "$pass" ]]; then
    printf '"%s"\t*\t"%s"\t*\n' "$user" "$pass" >>/etc/ppp/pap-secrets
    printf '"%s"\t*\t"%s"\t*\n' "$user" "$pass" >>/etc/ppp/chap-secrets
  fi
  chmod 600 /etc/ppp/pap-secrets /etc/ppp/chap-secrets
}

nanopi_write_pppoe_server_unit() {
  local lan="$1"
  nanopi_render_template nanopi-pppoe-server.service.tpl \
    "/etc/systemd/system/${PPPOE_SERVER_UNIT}" LAN="$lan"
}

nanopi_write_wan_pppoe_l2_net() {
  nanopi_net_write wan wan-pppoe-l2 WAN="$1"
}

nanopi_write_wan_vlan_net() {
  nanopi_net_write vlan wan-vlan WAN="$1" VLAN="$2"
}

# Плагин PPPoE для pppd: ppp ≥ 2.5 (Debian 13) — pppoe.so, старый — rp-pppoe.so.
# NANOPI_PPPD_PLUGIN_DIRS — для тестов.
nanopi_pppoe_plugin() {
  local dirs="${NANOPI_PPPD_PLUGIN_DIRS:-/usr/lib/pppd /usr/lib/*/pppd /usr/local/lib/pppd}"
  local name d f
  for name in pppoe.so rp-pppoe.so; do
    # shellcheck disable=SC2086
    for d in $dirs; do
      for f in "$d"/*/"$name"; do
        [[ -f "$f" ]] && { echo "$name"; return 0; }
      done
    done
  done
  echo "WARN: плагин pppoe.so/rp-pppoe.so для pppd не найден (пакет ppp?) — пишу rp-pppoe.so" >&2
  echo rp-pppoe.so
}

nanopi_write_wan_ppp_peer() {
  local nic="$1" user="$2"
  nanopi_render_template ppp-wan-peer.tpl "$PPP_PEER" NIC="$nic" PPPOE_USER="$user" \
    PPPOE_PLUGIN="$(nanopi_pppoe_plugin)"
  chmod 600 "$PPP_PEER"
}

nanopi_write_wan_pppoe_unit() {
  nanopi_install_template nanopi-wan-pppoe.service \
    "/etc/systemd/system/${WAN_PPPOE_UNIT}" 644
}

# flush ruleset в /etc/nftables.conf сносит auto_redirect sing-box.
# После любого restart nftables / nft -f нужно поднять sing-box снова.
nanopi_restart_nftables() {
  systemctl restart nftables
  if systemctl is-active --quiet sing-box 2>/dev/null || systemctl is-enabled --quiet sing-box 2>/dev/null; then
    systemctl try-reload-or-restart sing-box 2>/dev/null || systemctl restart sing-box 2>/dev/null || true
  fi
}

# Панель (если установлена и включена) должна работать после router-on.
# Она слушает WEBUI_LISTEN с IP_FREEBIND и обычно уже active; если она упала
# раньше (старый бинарь без freebind, лимит перезапусков) — запустить заново.
# Активную панель не перезапускаем: router-on может быть вызван из её же сессии.
nanopi_ensure_webui() {
  local unit=nanopi-webui
  systemctl cat "$unit" >/dev/null 2>&1 || return 0
  systemctl is-enabled --quiet "$unit" 2>/dev/null || return 0
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    echo "    панель ${unit}: active"
    return 0
  fi
  systemctl reset-failed "$unit" 2>/dev/null || true
  if systemctl start "$unit" 2>/dev/null; then
    echo "    панель ${unit}: запущена"
  else
    echo "    WARN: панель ${unit} не стартовала — journalctl -u ${unit} -n 40" >&2
  fi
}

nanopi_ensure_lan_dual_serve() {
  local lan wan
  lan=${LAN_IF:?LAN_IF не задан}
  wan=${WAN_IF:?WAN_IF не задан}

  nanopi_write_lan_net "$lan"
  nanopi_write_dnsmasq_lan "$lan" "$wan"
  nanopi_write_nft "$wan"
  nanopi_write_pppoe_server_opts
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
  nanopi_net_rm vlan
}

nanopi_write_wan_dhcp_net() {
  nanopi_net_rm lab vlan
  nanopi_net_write wan wan-dhcp WAN="$1"
}

nanopi_patch_singbox_exclude() {
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

# ════════════════════════════════════════════════════════════════════
# Интерфейсы: автоопределение
# ════════════════════════════════════════════════════════════════════

# Интерфейс default route (IPv4), кроме ppp*/tun*/sb-*/wg*/lo.
nanopi_default_route_if() {
  ip -4 route show default 2>/dev/null | awk '
    { for (i = 1; i < NF; i++) if ($i == "dev") { d = $(i + 1)
        if (d !~ /^(ppp|tun|tap|sb-|wg|lo)/) { print d; exit } } }'
}

# Физические проводные Ethernet (есть device/, не Wi-Fi, ARPHRD_ETHER).
nanopi_physical_ifaces() {
  local root="${NANOPI_SYS_CLASS_NET:-/sys/class/net}" d n
  for d in "$root"/*; do
    n=${d##*/}
    [[ -e "$d/device" ]] || continue
    [[ -e "$d/wireless" || -e "$d/phy80211" ]] && continue
    [[ "$(cat "$d/type" 2>/dev/null)" == "1" ]] || continue
    echo "$n"
  done
}

# LAN по умолчанию = первый физический Ethernet, отличный от WAN.
nanopi_guess_lan_if() {
  local wan="$1" n
  while read -r n; do
    [[ -n "$n" && "$n" != "$wan" ]] && { echo "$n"; return 0; }
  done < <(nanopi_physical_ifaces)
  return 0
}

# ════════════════════════════════════════════════════════════════════
# Сетевой стек: netplan (networkd) | ifupdown (Debian) | NetworkManager (нет)
# ════════════════════════════════════════════════════════════════════
#
# Роли файлов (одинаковы для обоих стеков):
#   lab  — WAN DHCP в домашней LAN     netplan 30-ethernets-dhcp.yaml
#   wan  — WAN DHCP / L2 под PPPoE     netplan 40-router-wan-dhcp.yaml
#   vlan — WAN + VLAN под PPPoE        netplan 45-router-wan-vlan.yaml
#   lan  — LAN 10.10.10.1/24           netplan 50-router-lan.yaml
# ifupdown: те же имена в ${NET_IFACES_DIR}/nanopi-<имя> (без .yaml).
#
# NET_STACK=netplan|ifupdown в .env/окружении — принудительно.

nanopi_net_stack() {
  if [[ -n "${NANOPI_NET_STACK_CACHED:-}" ]]; then
    echo "$NANOPI_NET_STACK_CACHED"; return 0
  fi
  local st=""
  case "${NET_STACK:-}" in
    netplan|ifupdown) st="$NET_STACK" ;;
    "") ;;
    *) echo "ERROR: NET_STACK='${NET_STACK}' — допустимо netplan|ifupdown" >&2; echo unknown; return 0 ;;
  esac
  if [[ -z "$st" ]]; then
    if command -v netplan >/dev/null 2>&1 && compgen -G "${NETPLAN_DIR}/*.yaml" >/dev/null; then
      st=netplan
    elif systemctl is-active --quiet NetworkManager 2>/dev/null; then
      st=networkmanager
    elif [[ -f "$NET_IFACES_MAIN" ]] && command -v ifup >/dev/null 2>&1; then
      st=ifupdown
    elif command -v netplan >/dev/null 2>&1; then
      st=netplan
    else
      st=unknown
    fi
  fi
  NANOPI_NET_STACK_CACHED="$st"
  echo "$st"
}

nanopi_net_require_stack() {
  local st
  st=$(nanopi_net_stack)
  case "$st" in
    netplan|ifupdown) return 0 ;;
    networkmanager)
      echo "ERROR: сетью управляет NetworkManager — не поддерживается." >&2
      echo "       Нужен netplan (renderer networkd) или Debian ifupdown (/etc/network/interfaces)." >&2
      echo "       Либо задай NET_STACK=netplan|ifupdown в ${ENV_FILE}, если уверен." >&2
      exit 1 ;;
    *)
      echo "ERROR: не найден поддерживаемый сетевой стек (netplan или ifupdown)." >&2
      exit 1 ;;
  esac
}

nanopi_net_role_name() {
  case "$1" in
    lab) echo 30-ethernets-dhcp ;;
    wan) echo 40-router-wan-dhcp ;;
    vlan) echo 45-router-wan-vlan ;;
    lan) echo 50-router-lan ;;
    *) echo "ERROR: неизвестная роль сетевого файла: $1" >&2; return 1 ;;
  esac
}

nanopi_net_path() {
  local name
  name=$(nanopi_net_role_name "$1") || return 1
  case "$(nanopi_net_stack)" in
    ifupdown) echo "${NET_IFACES_DIR}/nanopi-${name}" ;;
    *) echo "${NETPLAN_DIR}/${name}.yaml" ;;
  esac
}

# nanopi_net_write <роль> <база шаблона> KEY=VAL…
#   netplan:  templates/netplan-<база>.yaml.tpl
#   ifupdown: templates/ifupdown-<база>.tpl
nanopi_net_write() {
  local role="$1" base="$2" dest tpl
  shift 2
  dest=$(nanopi_net_path "$role") || return 1
  if [[ "$(nanopi_net_stack)" == ifupdown ]]; then
    tpl="ifupdown-${base}.tpl"
    mkdir -p "$NET_IFACES_DIR"
    nanopi_ifupdown_prepare_main
  else
    tpl="netplan-${base}.yaml.tpl"
  fi
  nanopi_render_template "$tpl" "$dest" "$@"
  chmod 600 "$dest"
}

nanopi_net_rm() {
  local role p
  for role in "$@"; do
    p=$(nanopi_net_path "$role") || return 1
    rm -f "$p"
  done
}

# Снимок до изменений (ifupdown). Вызывать в начале скрипта, до записи файлов.
nanopi_net_begin() {
  nanopi_net_require_stack
  [[ "$(nanopi_net_stack)" == ifupdown ]] || return 0
  [[ -n "${NANOPI_NET_SNAP:-}" && -d "${NANOPI_NET_SNAP}" ]] && return 0
  local snap
  mkdir -p "$NANOPI_NET_BACKUP_ROOT"
  chmod 700 "$NANOPI_NET_BACKUP_ROOT" 2>/dev/null || true
  snap=$(mktemp -d "${NANOPI_NET_BACKUP_ROOT}/net-$(date +%Y%m%d-%H%M%S)-XXXXXX") \
    || { echo "ERROR: не создать снимок в ${NANOPI_NET_BACKUP_ROOT}" >&2; exit 1; }
  mkdir -p "$snap/interfaces.d"
  [[ -f "$NET_IFACES_MAIN" ]] && cp -p "$NET_IFACES_MAIN" "$snap/interfaces"
  if [[ -d "$NET_IFACES_DIR" ]]; then
    cp -pr "$NET_IFACES_DIR"/. "$snap/interfaces.d/" 2>/dev/null || true
  fi
  NANOPI_NET_SNAP="$snap"
  export NANOPI_NET_SNAP
  # хранить 10 последних снимков
  ls -1dt "${NANOPI_NET_BACKUP_ROOT}"/net-* 2>/dev/null | tail -n +11 | xargs -r rm -rf
  echo "    сеть: снимок ifupdown → ${snap}"
}

# Убрать из основного /etc/network/interfaces стензы WAN/LAN (+ WAN.*),
# кроме «iface WAN inet6 …» (IPv6 на WAN не трогаем):
# их теперь задают фрагменты nanopi-*. Строки комментируются (#nanopi-edge#),
# оригинал один раз сохраняется в ${NET_IFACES_MAIN}.nanopi-orig.
# Гарантирует строку «source ${NET_IFACES_DIR}/*».
nanopi_ifupdown_prepare_main() {
  local main="$NET_IFACES_MAIN" tmp
  [[ -f "$main" ]] || printf 'auto lo\niface lo inet loopback\n' >"$main"
  tmp=$(mktemp)
  awk -v wan="${WAN_IF:-}" -v lan="${LAN_IF:-}" '
    function ours(n) { return n != "" && (n == wan || n == lan || (wan != "" && (index(n, wan ".") == 1 || index(n, wan ":") == 1))) }
    {
      s = $0; sub(/^[ \t]+/, "", s)
      if (s == "" || s ~ /^#/) { print; next }
      n = split(s, w, /[ \t]+/)
      if (w[1] ~ /^(iface|auto|allow-[a-z]+|mapping|source|source-directory|rename|no-auto-down|no-scripts)$/) {
        inside = 0
        # IPv6 WAN (iface WAN inet6 …) оставляем: nanopi-edge задаёт только IPv4
        if (w[1] == "iface" && ours(w[2]) && !(w[2] == wan && w[3] == "inet6")) { inside = 1; print "#nanopi-edge# " $0; next }
        if (w[1] == "auto" || w[1] ~ /^allow-/) {
          out = w[1]; kept = 0
          for (i = 2; i <= n; i++) if (!ours(w[i])) { out = out " " w[i]; kept++ }
          if (kept == n - 1) print
          else { print "#nanopi-edge# " $0; if (kept > 0) print out }
          next
        }
        print; next
      }
      if (inside) { print "#nanopi-edge# " $0; next }
      print
    }' "$main" >"$tmp"
  local dir_re
  dir_re=$(printf '%s' "$NET_IFACES_DIR" | sed 's/[.[\*^$/]/\\&/g')
  if ! grep -Eq "^[[:space:]]*source(-directory)?[[:space:]]+${dir_re}" "$tmp"; then
    printf '\n# nanopi-edge: фрагменты WAN/LAN\nsource %s/*\n' "$NET_IFACES_DIR" >>"$tmp"
  fi
  if cmp -s "$tmp" "$main"; then
    rm -f "$tmp"; return 0
  fi
  [[ -f "${main}.nanopi-orig" ]] || cp -p "$main" "${main}.nanopi-orig"
  cat "$tmp" >"$main"
  rm -f "$tmp"
}

# Стензы iface <имя> (нормализованные, без комментариев) из набора файлов.
# Порядок не важен: блоки сортируются по семейству (inet/inet6/…),
# внутри блока порядок строк сохраняется.
nanopi_ifupdown_stanza() {
  local ifc="$1"; shift
  awk -v ifc="$ifc" '
    {
      s = $0; sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
      if (s == "" || s ~ /^#/) next
      gsub(/[ \t]+/, " ", s); split(s, w, " ")
      if (w[1] ~ /^(iface|auto|allow-[a-z]+|mapping|source|source-directory|rename|no-auto-down|no-scripts)$/) {
        inside = (w[1] == "iface" && w[2] == ifc)
        if (inside) { fam = w[3]; print fam "\t" s }
        next
      }
      if (inside) print fam "\t" s
    }' "$@" 2>/dev/null | sort -s -t$'\t' -k1,1 | cut -f2-
}

# Имена iface (WAN, LAN, WAN.*) в наборе файлов.
nanopi_ifupdown_names() {
  awk -v wan="${WAN_IF:-}" -v lan="${LAN_IF:-}" '
    { s = $0; sub(/^[ \t]+/, "", s); split(s, w, /[ \t]+/)
      if (w[1] == "iface" && (w[2] == wan || w[2] == lan || index(w[2], wan ".") == 1)) print w[2] }' "$@" 2>/dev/null
}

# Файлы конфигурации ifupdown в каталоге-корне (main + фрагменты).
nanopi_ifupdown_files() {
  local main="$1" dir="$2" f
  [[ -f "$main" ]] && echo "$main"
  for f in "$dir"/*; do
    [[ -f "$f" ]] && echo "$f"
  done
}

# Применить: переподнять только интерфейсы, чья стенза изменилась
# (WAN с SSH в lab-режиме не моргает, если его конфиг тот же).
# Ошибка ifup → откат файлов из снимка и попытка поднять старое.
nanopi_ifupdown_apply() {
  local snap="${NANOPI_NET_SNAP:-}"
  [[ -n "$snap" && -d "$snap" ]] || { echo "ERROR: нет снимка сети (nanopi_net_begin не вызван)" >&2; return 1; }
  local -a old_files=() new_files=() changed=() failed=()
  mapfile -t old_files < <(nanopi_ifupdown_files "$snap/interfaces" "$snap/interfaces.d")
  mapfile -t new_files < <(nanopi_ifupdown_files "$NET_IFACES_MAIN" "$NET_IFACES_DIR")
  local names ifc old new tmp
  names=$( { [[ ${#old_files[@]} -gt 0 ]] && nanopi_ifupdown_names "${old_files[@]}"
             [[ ${#new_files[@]} -gt 0 ]] && nanopi_ifupdown_names "${new_files[@]}"; } | sort -u)
  tmp=$(mktemp)
  # down: сначала VLAN (длинные имена), потом базовые — по старому конфигу
  for ifc in $(sort -r <<<"$names"); do
    old=""; new=""
    [[ ${#old_files[@]} -gt 0 ]] && old=$(nanopi_ifupdown_stanza "$ifc" "${old_files[@]}")
    [[ ${#new_files[@]} -gt 0 ]] && new=$(nanopi_ifupdown_stanza "$ifc" "${new_files[@]}")
    [[ "$old" == "$new" ]] && continue
    changed+=("$ifc")
    if [[ -n "$old" ]]; then
      printf '%s\n' "$old" >"$tmp"
      ${NANOPI_IFDOWN:-ifdown} --force -i "$tmp" "$ifc" >/dev/null 2>&1 || true
    fi
    ${NANOPI_IP:-ip} addr flush dev "$ifc" 2>/dev/null || true
    if [[ -z "$new" && "$ifc" == *.* ]]; then
      ${NANOPI_IP:-ip} link delete "$ifc" 2>/dev/null || true
    fi
  done
  rm -f "$tmp"
  # up: базовые, потом VLAN — по новому конфигу
  for ifc in $(sort <<<"$names"); do
    [[ " ${changed[*]:-} " == *" $ifc "* ]] || continue
    [[ ${#new_files[@]} -gt 0 && -n "$(nanopi_ifupdown_stanza "$ifc" "${new_files[@]}")" ]] || continue
    echo "    ifup ${ifc}"
    ${NANOPI_IFUP:-ifup} "$ifc" || failed+=("$ifc")
  done
  if [[ ${#changed[@]} -eq 0 ]]; then
    echo "    ifupdown: стензы WAN/LAN не изменились — интерфейсы не трогаю"
  fi
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "ERROR: ifup не поднял: ${failed[*]} — откатываю файлы из ${snap}" >&2
    nanopi_ifupdown_restore "$snap"
    for ifc in "${changed[@]}"; do
      ${NANOPI_IFDOWN:-ifdown} --force "$ifc" >/dev/null 2>&1 || true
      ${NANOPI_IFUP:-ifup} "$ifc" >/dev/null 2>&1 || true
    done
    return 1
  fi
}

# Вернуть /etc/network/interfaces и nanopi-* фрагменты из снимка.
nanopi_ifupdown_restore() {
  local snap="$1" f
  [[ -f "$snap/interfaces" ]] && cat "$snap/interfaces" >"$NET_IFACES_MAIN"
  rm -f "$NET_IFACES_DIR"/nanopi-*
  for f in "$snap/interfaces.d"/nanopi-*; do
    [[ -f "$f" ]] && cp -p "$f" "$NET_IFACES_DIR/"
  done
  return 0
}

nanopi_net_apply() {
  case "$(nanopi_net_stack)" in
    netplan) ${NANOPI_NETPLAN:-netplan} apply ;;
    ifupdown) nanopi_ifupdown_apply ;;
    *) nanopi_net_require_stack ;;
  esac
}
