#!/bin/bash
# Тест: install-singbox.sh на новом хосте — пакетный sing-box (стоп/remove/upgrade-warn),
# выбор WAN/LAN (NANOPI_* → .env → автоопределение), стек сети.
# Запуск: bash tests/install-singbox-host.test.sh  (root и плата не нужны: apt/ip/systemctl — фейки)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

NANOPI_INSTALL_LIB_ONLY=1
# shellcheck disable=SC1091
source "$ROOT/install-singbox.sh"
set +e

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
check() { local n="$1"; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }

LOG="$WORK/calls.log"; export LOG
B="$WORK/bin"; mkdir -p "$B"
# dpkg-query: «установлен» только пакет из $DPKG_INSTALLED
cat >"$B/dpkg-query" <<'S'
#!/bin/bash
pkg="${!#}"
[[ " ${DPKG_INSTALLED:-} " == *" $pkg "* ]] && { printf 'install ok installed'; exit 0; }
exit 1
S
for c in apt-get systemctl; do
  printf '#!/bin/bash\necho "%s $*" >>"$LOG"\n' "$c" >"$B/$c"
done
cat >"$B/ip" <<'S'
#!/bin/bash
case "$*" in
  "-4 route show default") echo "default via 192.168.1.1 dev enp1s0 proto dhcp metric 100" ;;
  "link show dev enp1s0"|"link show dev enp2s0"|"link show dev end0") exit 0 ;;
  link\ show\ dev\ *) exit 1 ;;
  *) exit 0 ;;
esac
S
chmod +x "$B"/*
export PATH="$B:$PATH"
SB_DIR="$WORK/etc-sing-box"; mkdir -p "$SB_DIR"; echo '{}' >"$SB_DIR/config.json"
export NANOPI_YES=1

# ─── пакетный sing-box ──────────────────────────────────────────────
: >"$LOG"
(INSTALL_MODE=fresh; DPKG_INSTALLED="" check_singbox_pkg) >/dev/null 2>&1
check "пакета нет → продолжаем" test $? -eq 0
(INSTALL_MODE=fresh; export DPKG_INSTALLED="sing-box"; check_singbox_pkg) >"$WORK/o1" 2>&1; rc=$?
check "fresh + пакет → стоп (rc≠0)" test $rc -ne 0
check "fresh + пакет → предупреждение" grep -q 'установлен пакетом' "$WORK/o1"
check "fresh + пакет → ничего не удалено" test ! -s "$LOG"
(INSTALL_MODE=upgrade; export DPKG_INSTALLED="sing-box-beta"; check_singbox_pkg) >"$WORK/o2" 2>&1; rc=$?
check "upgrade + пакет → только WARN (rc=0)" test $rc -eq 0
check "upgrade + пакет → без apt" test ! -s "$LOG"
(INSTALL_MODE=fresh; export DPKG_INSTALLED="sing-box" NANOPI_REMOVE_SINGBOX_PKG=1; check_singbox_pkg) >/dev/null 2>&1; rc=$?
check "NANOPI_REMOVE_SINGBOX_PKG=1 → rc=0" test $rc -eq 0
check "→ apt-get remove (не purge)" grep -qx 'apt-get remove -y sing-box' "$LOG"
check "→ копия /etc/sing-box" bash -c 'ls -d "$1".bak-* >/dev/null 2>&1' _ "$SB_DIR"

# ─── WAN/LAN ────────────────────────────────────────────────────────
S="$WORK/sysnet"
for n in enp1s0 enp2s0; do mkdir -p "$S/$n/device"; echo 1 >"$S/$n/type"; done
mkdir -p "$S/lo"; echo 772 >"$S/lo/type"
export NANOPI_SYS_CLASS_NET="$S"

got=$(INSTALL_MODE=fresh; WAN_IF=""; LAN_IF=""; prompt_interfaces >/dev/null 2>&1; echo "$WAN_IF $LAN_IF")
check "fresh, автоопределение: WAN=default route, LAN=другой NIC" test "$got" == "enp1s0 enp2s0"
got=$(INSTALL_MODE=fresh; WAN_IF=""; LAN_IF=""; NANOPI_WAN_IF=enp2s0 NANOPI_LAN_IF=enp1s0 prompt_interfaces >/dev/null 2>&1; echo "$WAN_IF $LAN_IF")
check "NANOPI_WAN_IF/NANOPI_LAN_IF приоритетнее" test "$got" == "enp2s0 enp1s0"
got=$(INSTALL_MODE=upgrade; WAN_IF=end0; LAN_IF=enp1s0; prompt_interfaces >/dev/null 2>&1; echo "$WAN_IF $LAN_IF")
check "upgrade: значения из .env (NanoPi end0/enp1s0) не меняются" test "$got" == "end0 enp1s0"
(INSTALL_MODE=fresh; WAN_IF=""; LAN_IF=""; NANOPI_WAN_IF=eth9 prompt_interfaces) >/dev/null 2>&1; rc=$?
check "fresh: несуществующий интерфейс → стоп" test $rc -ne 0
(INSTALL_MODE=fresh; WAN_IF=""; LAN_IF=""; NANOPI_WAN_IF=enp1s0 NANOPI_LAN_IF=enp1s0 prompt_interfaces) >/dev/null 2>&1; rc=$?
check "WAN = LAN → стоп" test $rc -ne 0
(INSTALL_MODE=upgrade; WAN_IF=eth9; LAN_IF=enp1s0; prompt_interfaces) >"$WORK/o3" 2>&1; rc=$?
check "upgrade: нет интерфейса → WARN, не стоп" test $rc -eq 0
rm -rf "$S/enp2s0"
(INSTALL_MODE=fresh; WAN_IF=""; LAN_IF=""; prompt_interfaces) >"$WORK/o4" 2>&1; rc=$?
check "один NIC → стоп с подсказкой NANOPI_LAN_IF" bash -c '[[ $1 -ne 0 ]] && grep -q NANOPI_LAN_IF "$2"' _ $rc "$WORK/o4"

# ─── стек ───────────────────────────────────────────────────────────
check "NET_STACK=ifupdown" test "$(NET_STACK=ifupdown detect_net_stack)" == ifupdown
check "NET_STACK=netplan" test "$(NET_STACK=netplan detect_net_stack)" == netplan

echo
if [[ $fails -gt 0 ]]; then echo "FAILED: $fails"; exit 1; fi
echo "все тесты install-singbox-host пройдены"
