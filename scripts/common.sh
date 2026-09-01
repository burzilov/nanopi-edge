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
  printf '%s' "$content" >"$dest"
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
  nanopi_render_template nftables.conf.tpl /etc/nftables.conf WAN="$wan"
}

nanopi_write_dnsmasq_lan() {
  local lan="$1" wan="$2"
  mkdir -p /etc/dnsmasq.d
  nanopi_render_template dnsmasq-lan.conf.tpl /etc/dnsmasq.d/lan.conf LAN="$lan" WAN="$wan"
  rm -f /etc/dnsmasq.d/README
}

nanopi_write_lan_netplan() {
  local lan="$1"
  nanopi_render_template netplan-lan.yaml.tpl "$NETPLAN_DIR/50-router-lan.yaml" LAN="$lan"
  chmod 600 "$NETPLAN_DIR/50-router-lan.yaml"
}

nanopi_write_lab_netplan() {
  local wan="$1"
  nanopi_render_template netplan-lab-wan.yaml.tpl "$NETPLAN_DIR/30-ethernets-dhcp.yaml" WAN="$wan"
  chmod 600 "$NETPLAN_DIR/30-ethernets-dhcp.yaml"
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

nanopi_write_wan_pppoe_l2_netplan() {
  local wan="$1"
  nanopi_render_template netplan-wan-pppoe-l2.yaml.tpl \
    "$NETPLAN_DIR/40-router-wan-dhcp.yaml" WAN="$wan"
  chmod 600 "$NETPLAN_DIR/40-router-wan-dhcp.yaml"
}

nanopi_write_wan_vlan_netplan() {
  local wan="$1" vlan="$2"
  nanopi_render_template netplan-wan-vlan.yaml.tpl \
    "$NETPLAN_DIR/45-router-wan-vlan.yaml" WAN="$wan" VLAN="$vlan"
  chmod 600 "$NETPLAN_DIR/45-router-wan-vlan.yaml"
}

nanopi_write_wan_ppp_peer() {
  local nic="$1" user="$2"
  nanopi_render_template ppp-wan-peer.tpl "$PPP_PEER" NIC="$nic" PPPOE_USER="$user"
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

nanopi_ensure_lan_dual_serve() {
  local lan wan
  lan=${LAN_IF:-enp1s0}
  wan=${WAN_IF:-end0}

  nanopi_write_lan_netplan "$lan"
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
  rm -f "$NETPLAN_DIR"/45-router-wan-vlan.yaml
}

nanopi_write_wan_dhcp_netplan() {
  local wan="$1"
  rm -f "$NETPLAN_DIR/30-ethernets-dhcp.yaml"
  rm -f "$NETPLAN_DIR/45-router-wan-vlan.yaml"
  nanopi_render_template netplan-wan-dhcp.yaml.tpl \
    "$NETPLAN_DIR/40-router-wan-dhcp.yaml" WAN="$wan"
  chmod 600 "$NETPLAN_DIR/40-router-wan-dhcp.yaml"
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
