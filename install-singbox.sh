#!/bin/bash
# install.sh — одноразовая установка NanoPi R3S LTS как edge (схема B).
#
# Копируешь ТОЛЬКО этот файл на свежую Armbian (root):
#   bash install.sh           # установка + тесты
#   bash install.sh status    # диагностика (до удаления)
#   bash install.sh test      # приёмочные тесты (до удаления)
#
# После успешной установки install.sh можно удалить.
# Повседневное управление — скрипты в /opt/nanopi-edge/scripts/:
#   router-on | lab-on | proxy-select
#
# .env и будущий webui живут в /opt/nanopi-edge/.
# Боевой конфиг sing-box: /etc/sing-box/config.json (единый файл).
#
set -euo pipefail

SINGBOX_VERSION="${SINGBOX_VERSION:-1.13.14}"
SINGBOX_BIN=/usr/local/bin/sing-box
OPT_ROOT=/opt/nanopi-edge
SCRIPTS_DIR="$OPT_ROOT/scripts"
OPT_ENV="$OPT_ROOT/.env"
SB_DIR=/etc/sing-box
SB_CFG="$SB_DIR/config.json"
UNIT_DST=/etc/systemd/system/sing-box.service
NETPLAN_DIR=/etc/netplan

WAN_IF=end0
LAN_IF=enp1s0
CLASH_SECRET_VALUE=""

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
  if [[ "$default" =~ ^[Yy]$ ]]; then hint="Y/n"; else hint="y/N"; fi
  read -r -p "$prompt [$hint]: " reply || true
  reply=${reply:-$default}
  [[ "$reply" =~ ^[Yy]$ ]]
}

need_root() { [[ $(id -u) -eq 0 ]] || die "нужен root (sudo -i / sudo bash install.sh)"; }

load_env() {
  [[ -f "$OPT_ENV" ]] || return 0
  # shellcheck disable=SC1090
  source "$OPT_ENV"
  WAN_IF=${WAN_IF:-end0}
  LAN_IF=${LAN_IF:-enp1s0}
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
  systemctl is-active sing-box nftables dnsmasq 2>/dev/null || true
  systemctl is-enabled sing-box nftables dnsmasq 2>/dev/null || true
  echo "=== scripts ==="
  ls -la "$SCRIPTS_DIR" 2>/dev/null || true
}

# --- постоянные скрипты в /opt/nanopi-edge/scripts ---

write_ops_scripts() {
  explain \
    "Запишу постоянные утилиты в ${SCRIPTS_DIR}/ (router-on, lab-on, proxy-select).
Они читают ${OPT_ENV} и не зависят от install.sh — его потом можно удалить." \
    "Три executable-скрипта на месте"

  mkdir -p "$SCRIPTS_DIR"

  cat > "$SCRIPTS_DIR/lab-on" <<'EOF'
#!/bin/bash
# Откат в lab: WAN = DHCP в LAN домашнего роутера; dnsmasq/nft off.
set -euo pipefail
ENV_FILE=/opt/nanopi-edge/.env
NETPLAN_DIR=/etc/netplan
[[ -f "$ENV_FILE" ]] || { echo "ERROR: нет $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
WAN_IF=${WAN_IF:-end0}
LAN_IF=${LAN_IF:-enp1s0}

echo "==> lab-on: ${WAN_IF} DHCP (домашняя LAN). SSH может моргнуть."
rm -f "$NETPLAN_DIR"/40-router-wan-dhcp.yaml "$NETPLAN_DIR"/50-router-lan.yaml
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

systemctl disable --now nftables 2>/dev/null || true
systemctl mask dnsmasq 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
rm -f /etc/dnsmasq.d/lan.conf

netplan apply
echo "[ok] lab-on. Проверь: ip -br addr"
EOF

  cat > "$SCRIPTS_DIR/router-on" <<'EOF'
#!/bin/bash
# Врезка: WAN DHCP (ISP) + LAN 10.10.10.1 + nft MASQUERADE + dnsmasq.
set -euo pipefail
ENV_FILE=/opt/nanopi-edge/.env
NETPLAN_DIR=/etc/netplan
[[ -f "$ENV_FILE" ]] || { echo "ERROR: нет $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
WAN_IF=${WAN_IF:-end0}
LAN_IF=${LAN_IF:-enp1s0}

echo "==> router-on"
echo "    Кабели: ISP→WAN(${WAN_IF}), LAN(${LAN_IF})→WAN роутера."
echo "    SSH может моргнуть на netplan apply."
read -r -p "Продолжить? [y/N]: " reply || true
[[ "${reply:-}" =~ ^[Yy]$ ]] || exit 0

rm -f "$NETPLAN_DIR/30-ethernets-dhcp.yaml"

cat > "$NETPLAN_DIR/40-router-wan-dhcp.yaml" <<YAML
# NanoPi router: WAN (${WAN_IF}) = DHCP от ISP
network:
  version: 2
  renderer: networkd
  ethernets:
    ${WAN_IF}:
      dhcp4: true
      dhcp6: false
      dhcp4-overrides:
        route-metric: 100
YAML
chmod 600 "$NETPLAN_DIR/40-router-wan-dhcp.yaml"

cat > "$NETPLAN_DIR/50-router-lan.yaml" <<YAML
# NanoPi router: LAN (${LAN_IF}) = 10.10.10.1/24
network:
  version: 2
  renderer: networkd
  ethernets:
    ${LAN_IF}:
      dhcp4: false
      dhcp6: false
      optional: true
      ignore-carrier: true
      addresses:
        - 10.10.10.1/24
YAML
chmod 600 "$NETPLAN_DIR/50-router-lan.yaml"

cat > /etc/nftables.conf <<NFT
#!/usr/sbin/nft -f
# Минимальный NAT на краю (схема B)
flush ruleset

table inet nat {
	chain postrouting {
		type nat hook postrouting priority srcnat; policy accept;
		oifname "${WAN_IF}" masquerade
		oifname "ppp0" masquerade
	}
}

table inet filter {
	chain forward {
		type filter hook forward priority filter; policy accept;
	}
}
NFT

mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/lan.conf <<DNS
# DHCP только на LAN NanoPi → WAN домашнего роутера
interface=${LAN_IF}
bind-dynamic
except-interface=lo
except-interface=${WAN_IF}
except-interface=sb-tun

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

systemctl unmask dnsmasq
systemctl enable nftables dnsmasq
netplan apply
ip link set "$LAN_IF" up || true
for i in 1 2 3 4 5 6 7 8 9 10; do
  ip -4 -br addr show "$LAN_IF" | grep -q '10\.10\.10\.1' && break
  sleep 0.5
done
systemctl restart nftables
systemctl restart dnsmasq
systemctl is-active dnsmasq nftables
echo "[ok] router-on. Проверь: ip -br addr; ${LAN_IF} должен быть 10.10.10.1"
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

  chmod 755 "$SCRIPTS_DIR/lab-on" "$SCRIPTS_DIR/router-on" "$SCRIPTS_DIR/proxy-select"
}

# --- пакеты / sysctl / sing-box ---

install_packages() {
  explain \
    "apt update и минимум пакетов: curl, jq, ca-certificates, nftables, dnsmasq, ppp, openssl.
nftables/dnsmasq сразу выключу — в lab не должны слушать LAN роутера." \
    "Пакеты на месте; dnsmasq masked; nftables не active до router-on."

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    curl jq ca-certificates nftables dnsmasq ppp openssl
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

write_dotenv() {
  local secret="$1"
  mkdir -p "$OPT_ROOT" "$SB_DIR"
  umask 077
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
EOF
  chmod 600 "$OPT_ENV"
  # убрать старые расположения секрета
  rm -f "$SB_DIR/clash-api.secret" "$SB_DIR/ui.env" "$SB_DIR/.env"
}

gen_clash_secrets() {
  explain \
    "Сгенерирую ${OPT_ENV} (0600): CLASH_API/SECRET, пути, WAN_IF/LAN_IF.
Тот же CLASH_SECRET подставлю в config.json (sing-box читает только JSON)." \
    "Файл ${OPT_ENV}; clash_api на 127.0.0.1:9090"

  local secret=""
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
  if [[ -z "${secret:-}" ]]; then
    secret=$(openssl rand -hex 16)
  fi
  write_dotenv "$secret"
  CLASH_SECRET_VALUE=$secret
}

prompt_interfaces() {
  explain \
    "Уточню имена Ethernet. На R3S LTS обычно: WAN-разъём = end0, LAN = enp1s0.
Lab-кабель сейчас в WAN-разъёме." \
    "WAN_IF / LAN_IF сохранятся в ${OPT_ENV}"

  echo "Сейчас:"
  ip -br link
  echo
  WAN_IF=$(ask "WAN interface (разъём WAN на корпусе)" "end0")
  LAN_IF=$(ask "LAN interface (разъём LAN на корпусе)" "enp1s0")
  [[ -n "$WAN_IF" && -n "$LAN_IF" ]] || die "пустые имена интерфейсов"
  [[ "$WAN_IF" != "$LAN_IF" ]] || die "WAN и LAN не должны совпадать"
}

build_singbox_config() {
  local nodes_file="$1" secret="$2" default_tag="$3"

  explain \
    "Соберу единый ${SB_CFG}: TUN, AdGuard DoH, remote ruleset’ы, VLESS,
selector proxy, clash_api. IP узлов (IPv4) и AdGuard — direct (антипетля)." \
    "sing-box check успешен; mode 0600"

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

  "$SINGBOX_BIN" check -c "$SB_CFG"
  ok "config check passed"
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

start_singbox() {
  explain \
    "Запущу sing-box. Первый старт может занять до ~2 мин (remote rule-set)." \
    "sing-box active; есть sb-tun"

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
      → LAN NanoPi (${LAN_IF}=10.10.10.1) → WAN домашнего роутера
      → LAN роутера 192.168.1.0/24 → клиенты

0) Запасной путь
   • Запомни текущий SSH (lab).
   • После врезки SSH: root@10.10.10.1
   • Откат: ISP → WAN роутера; NanoPi WAN (${WAN_IF}) → LAN роутера; затем:
       ${SCRIPTS_DIR}/lab-on

1) Клиенты роутера — убрать «старый» gateway/DNS
   • Gateway = сам роутер (обычно 192.168.1.1), НЕ старый прокси/VM.
   • DNS = роутер (позже можно 10.10.10.1).
   • Обнови DHCP на ПК, проверь интернет без старого прокси.

2) Роутерный профиль на NanoPi (lab-кабель ещё можно не трогать)
   ${SCRIPTS_DIR}/router-on
   Ожидание: ${LAN_IF}=10.10.10.1/24; nftables+dnsmasq active; sing-box active.
   SSH может моргнуть — подожди ~30 с.

3) Кабели (питание NanoPi не выключать)
   1. Вынь lab из WAN NanoPi (${WAN_IF}) ← LAN роутера.
   2. ISP → WAN NanoPi (${WAN_IF}).
   3. LAN NanoPi (${LAN_IF}) → WAN-порт роутера.
   4. Подожди 30–60 с.

4) WAN роутера
   • DHCP-клиент → 10.10.10.100–200, шлюз/DNS 10.10.10.1.
   • Клиенты: 192.168.1.0/24, gateway = роутер.

5) Проверки
   С ПК: ping 192.168.1.1; ping 10.10.10.1; браузер.
   С NanoPi (ssh root@10.10.10.1):
     ip -br addr
     systemctl is-active sing-box nftables dnsmasq
     curl -4 -sS https://ya.ru/ -o /dev/null -w '%{http_code}\n'
     curl -4 -sS https://api.ipify.org; echo
     ${SCRIPTS_DIR}/proxy-select get
     ${SCRIPTS_DIR}/proxy-select set <tag>

После успешной установки и тестов этот install-singbox.sh можно удалить.
Остаётся:
  ${OPT_ENV}
  ${SB_CFG}
  ${SCRIPTS_DIR}/{router-on,lab-on,proxy-select}

WebUI: отдельно — install-webui.sh (скачивает release с GitHub).

EOF
}

usage() {
  cat <<EOF
Usage: $0 [install|status|test]

  (без аргументов / install)  интерактивная установка в lab + тесты
  status                      диагностика
  test                        приёмочные тесты sing-box

После установки install.sh можно удалить.
Постоянные команды:
  ${SCRIPTS_DIR}/router-on
  ${SCRIPTS_DIR}/lab-on
  ${SCRIPTS_DIR}/proxy-select list|get|set <tag>
EOF
  exit 1
}

cmd_install() {
  need_root

  cat <<EOF
╔══════════════════════════════════════════════════════════╗
║  NanoPi edge install (схема B)                           ║
║  Одноразовый установщик · без WebUI                      ║
╚══════════════════════════════════════════════════════════╝

Предпосылки:
  • Свежая Armbian, root, интернет
  • WAN NanoPi в LAN домашнего роутера (lab)
  • VLESS+Reality под рукой
  • Врезку сейчас НЕ делаем

После успеха: install.sh можно удалить; останутся
  ${OPT_ROOT}/.env, scripts/, /etc/sing-box/config.json

EOF

  yesno "Продолжить?" y || exit 0

  step 1 "Инвентарь"
  explain \
    "Сниму инвентарь ОС/сети — проверка lab и uplink." \
    "Адрес на WAN в домашней LAN и default route."
  show_inventory
  yesno "Похоже на lab. Продолжаем?" y || exit 0

  step 2 "Интерфейсы WAN/LAN"
  prompt_interfaces

  step 3 "Каталог ${OPT_ROOT}"
  explain \
    "Создам ${OPT_ROOT} и постоянные scripts/ (router-on, lab-on, proxy-select)." \
    "${SCRIPTS_DIR}/router-on, lab-on, proxy-select существуют"
  mkdir -p "$OPT_ROOT"
  write_ops_scripts

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

  step 9 "Мастер VLESS + единый config.json"
  run_wizard_and_build "$CLASH_SECRET_VALUE"

  step 10 "Запуск sing-box"
  start_singbox

  if ! run_tests; then
    echo
    echo "Установка с ошибками тестов. journalctl -u sing-box -n 80 --no-pager"
    print_cutover
    exit 1
  fi

  print_cutover
  info "Готово. При желании: rm -- \$0  (или удали скопированный install.sh)"
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
    router-on|lab-on|proxy)
      die "эта команда перенесена в ${SCRIPTS_DIR}/ (install.sh — только install|status|test)"
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
