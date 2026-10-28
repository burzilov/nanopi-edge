#!/bin/bash
# Тест: сетевой слой scripts/common.sh — стек netplan|ifupdown, правка
# /etc/network/interfaces, переподъём только изменённых стенз, откат при
# ошибке ifup, плагин PPPoE, правило SSH на WAN, автоопределение интерфейсов.
# Запуск: bash tests/net-stack.test.sh  (root и плата не нужны, всё во временном каталоге)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export NANOPI_TEMPLATE_DIR="$ROOT/templates"
# shellcheck disable=SC1091
source "$ROOT/scripts/common.sh"
set +e

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
check() { # name cond…
  local name="$1"; shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}
eq() { [[ "$1" == "$2" ]] || { printf '  ожидалось: %q\n  получено:  %q\n' "$2" "$1"; return 1; }; }

# фейковые ifup/ifdown/ip: пишут вызовы в лог; ifup падает на $FAIL_IFUP
LOG="$WORK/calls.log"
mkdir -p "$WORK/bin"
cat >"$WORK/bin/fake-ifup" <<'S'
#!/bin/bash
echo "ifup $*" >>"$LOG"
[[ -n "${FAIL_IFUP:-}" && "$*" == *"$FAIL_IFUP"* ]] && exit 1
exit 0
S
cat >"$WORK/bin/fake-ifdown" <<'S'
#!/bin/bash
echo "ifdown $*" >>"$LOG"
S
cat >"$WORK/bin/fake-ip" <<'S'
#!/bin/bash
echo "ip $*" >>"$LOG"
S
cat >"$WORK/bin/fake-netplan" <<'S'
#!/bin/bash
echo "netplan $*" >>"$LOG"
S
chmod +x "$WORK/bin"/*
export LOG
NANOPI_IFUP="$WORK/bin/fake-ifup"
NANOPI_IFDOWN="$WORK/bin/fake-ifdown"
NANOPI_IP="$WORK/bin/fake-ip"
NANOPI_NETPLAN="$WORK/bin/fake-netplan"

reset_net() { # новая «система» ifupdown в $WORK/sys
  rm -rf "$WORK/sys"; mkdir -p "$WORK/sys/interfaces.d" "$WORK/sys/backups" "$WORK/sys/netplan"
  NET_IFACES_MAIN="$WORK/sys/interfaces"
  NET_IFACES_DIR="$WORK/sys/interfaces.d"
  NANOPI_NET_BACKUP_ROOT="$WORK/sys/backups"
  NETPLAN_DIR="$WORK/sys/netplan"
  unset NANOPI_NET_SNAP NANOPI_NET_STACK_CACHED
  : >"$LOG"
}

# /etc/network/interfaces свежего Debian 13 (установщик, IPv4 DHCP + SLAAC)
debian_main() {
  cat >"$NET_IFACES_MAIN" <<'I'
# This file describes the network interfaces available on your system
source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
allow-hotplug enp1s0
iface enp1s0 inet dhcp
# This is an autoconfigured IPv6 interface
iface enp1s0 inet6 auto
I
}

WAN_IF=enp1s0
LAN_IF=enp2s0

# ─── 1. выбор стека ────────────────────────────────────────────────
reset_net
check "NET_STACK=ifupdown" eq "$(NET_STACK=ifupdown nanopi_net_stack)" ifupdown
unset NANOPI_NET_STACK_CACHED
check "NET_STACK=netplan" eq "$(NET_STACK=netplan nanopi_net_stack)" netplan
unset NANOPI_NET_STACK_CACHED
check "NET_STACK=мусор → unknown" eq "$(NET_STACK=bogus nanopi_net_stack 2>/dev/null)" unknown
out=$( (NET_STACK=bogus; unset NANOPI_NET_STACK_CACHED; nanopi_net_require_stack) 2>&1); rc=$?
check "unknown стек → exit 1" eq "$rc" 1
check "пути netplan не изменились" eq "$(NET_STACK=netplan; unset NANOPI_NET_STACK_CACHED; nanopi_net_path wan; nanopi_net_path lan; nanopi_net_path lab; nanopi_net_path vlan)" \
  "$NETPLAN_DIR/40-router-wan-dhcp.yaml"$'\n'"$NETPLAN_DIR/50-router-lan.yaml"$'\n'"$NETPLAN_DIR/30-ethernets-dhcp.yaml"$'\n'"$NETPLAN_DIR/45-router-wan-vlan.yaml"
check "пути ifupdown" eq "$(NET_STACK=ifupdown; unset NANOPI_NET_STACK_CACHED; nanopi_net_path wan; nanopi_net_path lan)" \
  "$NET_IFACES_DIR/nanopi-40-router-wan-dhcp"$'\n'"$NET_IFACES_DIR/nanopi-50-router-lan"

# ─── 2. netplan: рендер + netplan apply ────────────────────────────
reset_net
NET_STACK=netplan
nanopi_write_lan_net "$LAN_IF"
nanopi_write_wan_dhcp_net "$WAN_IF"
check "netplan: 50-router-lan.yaml с LAN" grep -q "$LAN_IF" "$NETPLAN_DIR/50-router-lan.yaml"
check "netplan: 40-router-wan-dhcp.yaml с WAN" grep -q "$WAN_IF" "$NETPLAN_DIR/40-router-wan-dhcp.yaml"
check "netplan: /etc/network не тронут" eq "$(ls "$NET_IFACES_DIR")" ""
nanopi_net_apply
check "netplan: вызван netplan apply" eq "$(cat "$LOG")" "netplan apply"
unset NET_STACK

# ─── 3. ifupdown: router-on (WAN DHCP + LAN static) ────────────────
reset_net
NET_STACK=ifupdown
debian_main
cp "$NET_IFACES_MAIN" "$WORK/orig"
nanopi_net_begin >/dev/null
check "снимок создан" test -f "$NANOPI_NET_SNAP/interfaces"
nanopi_net_rm lab vlan
nanopi_write_lan_net "$LAN_IF"
nanopi_write_wan_dhcp_net "$WAN_IF"
check "оригинал сохранён (.nanopi-orig)" cmp -s "$NET_IFACES_MAIN.nanopi-orig" "$WORK/orig"
check "WAN inet закомментирован" grep -qx '#nanopi-edge# iface enp1s0 inet dhcp' "$NET_IFACES_MAIN"
check "allow-hotplug WAN закомментирован" grep -qx '#nanopi-edge# allow-hotplug enp1s0' "$NET_IFACES_MAIN"
check "WAN inet6 оставлен" grep -qx 'iface enp1s0 inet6 auto' "$NET_IFACES_MAIN"
check "lo не тронут" grep -qx 'iface lo inet loopback' "$NET_IFACES_MAIN"
check "source на каталог фрагментов" grep -qx "source $NET_IFACES_DIR/\*" "$NET_IFACES_MAIN"
check "фрагмент LAN" grep -qx '    address 10.10.10.1/24' "$NET_IFACES_DIR/nanopi-50-router-lan"
check "права фрагмента 600" eq "$(stat -c %a "$NET_IFACES_DIR/nanopi-50-router-lan")" 600
nanopi_net_apply >/dev/null; rc=$?
check "apply ok" eq "$rc" 0
check "WAN не переподнят (стенза та же)" bash -c '! grep -q "enp1s0" "$1"' _ "$LOG"
check "LAN поднят" grep -qx "ifup $LAN_IF" "$LOG"
check "LAN без старой стензы — ifdown не нужен" bash -c '! grep -q "^ifdown" "$1"' _ "$LOG"
# повторная правка идемпотентна
cp "$NET_IFACES_MAIN" "$WORK/after1"
nanopi_ifupdown_prepare_main
check "prepare_main идемпотентен" cmp -s "$NET_IFACES_MAIN" "$WORK/after1"

# ─── 4. ifupdown: повторный router-on без изменений — ничего не трогаем
unset NANOPI_NET_SNAP; : >"$LOG"
nanopi_net_begin >/dev/null
nanopi_write_lan_net "$LAN_IF"; nanopi_write_wan_dhcp_net "$WAN_IF"
out=$(nanopi_net_apply)
check "без изменений — ни ifup, ни ifdown" eq "$(cat "$LOG")" ""
check "сообщение «не трогаю»" grep -q 'не изменились' <<<"$out"

# ─── 5. ifupdown: PPPoE+VLAN → WAN manual + WAN.VLAN, потом обратно DHCP
unset NANOPI_NET_SNAP; : >"$LOG"
nanopi_net_begin >/dev/null
nanopi_net_rm wan lab
nanopi_write_wan_vlan_net "$WAN_IF" 300
nanopi_net_apply >/dev/null
check "VLAN: ifdown WAN по старой стензе" grep -q "^ifdown --force -i .* enp1s0$" "$LOG"
check "VLAN: ifup WAN и WAN.300" eq "$(grep '^ifup' "$LOG")" $'ifup enp1s0\nifup enp1s0.300'
unset NANOPI_NET_SNAP; : >"$LOG"
nanopi_net_begin >/dev/null
nanopi_net_rm vlan lab
nanopi_write_wan_dhcp_net "$WAN_IF"
nanopi_net_apply >/dev/null
check "назад: WAN.300 удалён" grep -qx "ip link delete enp1s0.300" "$LOG"
check "назад: ifdown сначала VLAN" eq "$(grep '^ifdown' "$LOG" | awk '{print $NF}' | paste -sd' ')" "enp1s0.300 enp1s0"
check "назад: ifup только WAN" eq "$(grep '^ifup' "$LOG")" "ifup enp1s0"
check "назад: фрагмента VLAN нет" test ! -e "$NET_IFACES_DIR/nanopi-45-router-wan-vlan"

# ─── 6. ifupdown: ошибка ifup → откат файлов из снимка ─────────────
unset NANOPI_NET_SNAP; : >"$LOG"
nanopi_net_begin >/dev/null
snap_lan=$(cat "$NET_IFACES_DIR/nanopi-50-router-lan")
main_before=$(cat "$NET_IFACES_MAIN")
nanopi_net_rm wan lab
nanopi_write_wan_vlan_net "$WAN_IF" 42
FAIL_IFUP=enp1s0.42 nanopi_net_apply >/dev/null 2>&1; rc=$?
check "ifup упал → apply = 1" eq "$rc" 1
check "откат: фрагмент WAN DHCP вернулся" test -f "$NET_IFACES_DIR/nanopi-40-router-wan-dhcp"
check "откат: фрагмента VLAN нет" test ! -e "$NET_IFACES_DIR/nanopi-45-router-wan-vlan"
check "откат: LAN тот же" eq "$(cat "$NET_IFACES_DIR/nanopi-50-router-lan")" "$snap_lan"
check "откат: interfaces тот же" eq "$(cat "$NET_IFACES_MAIN")" "$main_before"
check "откат: интерфейсы переподняты" grep -q "^ifup enp1s0$" "$LOG"

# ─── 7. снимки: хранится не больше 10 ──────────────────────────────
for i in $(seq 1 12); do mkdir -p "$NANOPI_NET_BACKUP_ROOT/net-2000010$i-000000-1"; touch -d "2000-01-01 + $i min" "$NANOPI_NET_BACKUP_ROOT/net-2000010$i-000000-1"; done
unset NANOPI_NET_SNAP
nanopi_net_begin >/dev/null
check "снимков ≤ 10" eq "$(ls -1d "$NANOPI_NET_BACKUP_ROOT"/net-* | wc -l)" 10
unset NET_STACK NANOPI_NET_STACK_CACHED

# ─── 8. стенза: порядок блоков не важен ────────────────────────────
printf 'iface x inet6 auto\niface x inet dhcp\n  hostname a\n' >"$WORK/s1"
printf 'iface x inet dhcp\n    hostname   a\n\niface x inet6 auto\n' >"$WORK/s2"
check "стенза нормализуется" eq "$(nanopi_ifupdown_stanza x "$WORK/s1")" "$(nanopi_ifupdown_stanza x "$WORK/s2")"

# ─── 9. плагин PPPoE ───────────────────────────────────────────────
mkdir -p "$WORK/pppd/a/2.5.2" "$WORK/pppd/b/2.4.9"
touch "$WORK/pppd/a/2.5.2/pppoe.so" "$WORK/pppd/a/2.5.2/rp-pppoe.so" "$WORK/pppd/b/2.4.9/rp-pppoe.so"
check "ppp 2.5: pppoe.so" eq "$(NANOPI_PPPD_PLUGIN_DIRS="$WORK/pppd/a" nanopi_pppoe_plugin)" pppoe.so
check "ppp 2.4: rp-pppoe.so" eq "$(NANOPI_PPPD_PLUGIN_DIRS="$WORK/pppd/b" nanopi_pppoe_plugin)" rp-pppoe.so
check "нет плагина: rp-pppoe.so + WARN" eq "$(NANOPI_PPPD_PLUGIN_DIRS="$WORK/none" nanopi_pppoe_plugin 2>/dev/null)" rp-pppoe.so
PPP_PEER="$WORK/peer"
NANOPI_PPPD_PLUGIN_DIRS="$WORK/pppd/a" nanopi_write_wan_ppp_peer enp1s0.300 user1
check "peer: plugin pppoe.so" grep -qx 'plugin pppoe.so' "$PPP_PEER"
check "peer: без плейсхолдеров" bash -c '! grep -q @ "$1"' _ "$PPP_PEER"

# ─── 10. SSH на WAN ────────────────────────────────────────────────
check "SSH: порты из NANOPI_SSH_PORTS" eq "$(NANOPI_SSH_PORTS='2222,22 2222' nanopi_ssh_ports | paste -sd,)" "22,2222"
r=$(NANOPI_SSH_PORTS=22 nanopi_ssh_wan_rule enp1s0)
check "SSH: drop новых с WAN/ppp0" eq "$r" 'iifname { "enp1s0", "ppp0" } tcp dport { 22 } ct state new counter drop comment "nanopi-edge: SSH only from LAN"'
r=$(NANOPI_SSH_PORTS=22 SSH_ALLOW_WAN=1 nanopi_ssh_wan_rule enp1s0)
check "SSH_ALLOW_WAN=1 → комментарий" eq "${r:0:1}" "#"
nft=$(NANOPI_SSH_PORTS=2222 nanopi_render_template nftables.conf.tpl /dev/stdout WAN=enp1s0 SSH_WAN_RULE="$(NANOPI_SSH_PORTS=2222 nanopi_ssh_wan_rule enp1s0)")
check "nftables.conf: chain input с правилом" grep -q 'tcp dport { 2222 } ct state new counter drop' <<<"$nft"
check "nftables.conf: без плейсхолдеров" bash -c '! grep -q "@[A-Z_]*@" <<<"$1"' _ "$nft"
if command -v nft >/dev/null 2>&1 && [[ $EUID -eq 0 ]]; then
  printf '%s\n' "$nft" | sed '/^include/d' >"$WORK/nft.conf"
  if nft -c -f "$WORK/nft.conf" 2>"$WORK/nft.err"; then pass "nft -c: синтаксис ок"; else
    if grep -qi 'Operation not permitted\|netlink' "$WORK/nft.err"; then echo "skip - nft -c недоступен: $(head -1 "$WORK/nft.err")"; else fail "nft -c"; cat "$WORK/nft.err"; fi
  fi
else
  echo "skip - nft -c (нет nft или не root)"
fi

# ─── 11. интерфейсы: фейковый /sys/class/net ───────────────────────
S="$WORK/sysnet"
mkif() { # имя type [device] [wireless]
  mkdir -p "$S/$1"; echo "$2" >"$S/$1/type"
  [[ "${3:-}" == dev ]] && mkdir -p "$S/$1/device"
  [[ "${4:-}" == wifi ]] && mkdir -p "$S/$1/wireless"
  return 0
}
mkif lo 772; mkif enp1s0 1 dev; mkif enp2s0 1 dev; mkif wlp3s0 1 dev wifi; mkif docker0 1; mkif sb-tun 65534
check "физические: только проводные с device/" eq "$(NANOPI_SYS_CLASS_NET="$S" nanopi_physical_ifaces | paste -sd' ')" "enp1s0 enp2s0"
check "LAN = второй физический" eq "$(NANOPI_SYS_CLASS_NET="$S" nanopi_guess_lan_if enp1s0)" enp2s0
check "LAN, если WAN второй" eq "$(NANOPI_SYS_CLASS_NET="$S" nanopi_guess_lan_if enp2s0)" enp1s0
rm -rf "$S/enp2s0"
check "один NIC → LAN пусто" eq "$(NANOPI_SYS_CLASS_NET="$S" nanopi_guess_lan_if enp1s0)" ""

# nanopi_load_env: .env без WAN_IF/LAN_IF → автоопределение
mkif enp2s0 1 dev
cat >"$WORK/bin/ip" <<'S'
#!/bin/bash
[[ "$*" == "-4 route show default" ]] && { printf 'default dev ppp0 scope link\ndefault via 192.168.1.1 dev enp1s0 proto dhcp metric 100\n'; exit 0; }
exit 1
S
chmod +x "$WORK/bin/ip"
printf 'WAN_MODE=dhcp\n' >"$WORK/env1"
got=$(PATH="$WORK/bin:$PATH" NANOPI_SYS_CLASS_NET="$S" ENV_FILE="$WORK/env1" bash -c '
  source "$1"; unset WAN_IF LAN_IF; nanopi_load_env; echo "$WAN_IF $LAN_IF"' _ "$ROOT/scripts/common.sh")
check "load_env: WAN по default route (не ppp0), LAN — другой NIC" eq "$got" "enp1s0 enp2s0"
printf 'WAN_IF=end0\nLAN_IF=enp1s0\n' >"$WORK/env2"
got=$(PATH="$WORK/bin:$PATH" NANOPI_SYS_CLASS_NET="$S" ENV_FILE="$WORK/env2" bash -c '
  source "$1"; unset WAN_IF LAN_IF; nanopi_load_env; echo "$WAN_IF $LAN_IF"' _ "$ROOT/scripts/common.sh")
check "load_env: .env (NanoPi end0/enp1s0) приоритетнее" eq "$got" "end0 enp1s0"

echo
if [[ $fails -gt 0 ]]; then echo "FAILED: $fails"; exit 1; fi
echo "все тесты net-stack пройдены"
