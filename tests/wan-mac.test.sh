#!/bin/bash
# Изолированный тест scripts/wan-mac (без живой сети).
# Запуск: bash tests/wan-mac.test.sh
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
check() { local n="$1"; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }

B="$WORK/bin"; mkdir -p "$B" "$WORK/sys/eth0" "$WORK/netplan" "$WORK/if-pre-up.d"
LOG="$WORK/cmd.log"; : >"$LOG"; export LOG

cat >"$B/ip" <<'EOF'
#!/bin/bash
echo "ip $*" >>"$LOG"
# ip link set dev IFACE address MAC
if [[ "$1 $2 $3" == "link set dev" && "$5" == "address" ]]; then
  printf '%s\n' "$6" >"$WAN_MAC_SYSFS/$4/address"
fi
exit 0
EOF
cat >"$B/ethtool" <<'EOF'
#!/bin/bash
iface=${!#}
echo "Permanent address: $(tr -d '[:space:]' <"$WAN_MAC_SYSFS/$iface/perm_address")"
EOF
cat >"$B/netplan" <<'EOF'
#!/bin/bash
echo "netplan $*" >>"$LOG"
exit 0
EOF
cat >"$B/ifup" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$B"/*

printf '00:11:22:33:44:55\n' >"$WORK/sys/eth0/address"
printf '00:11:22:33:44:55\n' >"$WORK/sys/eth0/perm_address"
printf '0x1003\n' >"$WORK/sys/eth0/flags"
printf '0\n' >"$WORK/sys/eth0/addr_assign_type"
mkdir -p "$WORK/etc/network"
printf 'auto lo\n' >"$WORK/etc/network/interfaces"

ENV_FILE="$WORK/env"
cat >"$ENV_FILE" <<'EOF'
WAN_IF=eth0
LAN_IF=eth1
NET_STACK=ifupdown
EOF

export PATH="$B:$PATH"
export ENV_FILE
export WAN_MAC_SYSFS="$WORK/sys"
export NETPLAN_DIR="$WORK/netplan"
export WAN_MAC_IFUP_HOOK="$WORK/if-pre-up.d/nanopi-wan-mac"
export WAN_MAC_NETPLAN="$WORK/netplan/99-nanopi-wan-mac.yaml"
export WAN_MAC_LOCK="$WORK/lock"
export NET_IFACES_MAIN="$WORK/etc/network/interfaces"
export NANOPI_NETPLAN=netplan

SCRIPT="$ROOT/scripts/wan-mac"
chmod +x "$SCRIPT"

# set ifupdown
if "$SCRIPT" "02:aa:bb:cc:dd:ee" >"$WORK/out1" 2>"$WORK/err1"; then
  pass "set MAC ifupdown rc=0"
else
  fail "set MAC ifupdown rc=0 ($(cat "$WORK/err1"))"
fi
check "hook создан" test -f "$WAN_MAC_IFUP_HOOK"
check "hook: shebang первый" bash -c 'head -1 "$1" | grep -qx "#!/bin/sh"' _ "$WAN_MAC_IFUP_HOOK"
check "hook: маркер" grep -Fq '# Managed by nanopi-edge wan-mac' "$WAN_MAC_IFUP_HOOK"
check "hook исполняемый" test -x "$WAN_MAC_IFUP_HOOK"
check ".env WAN_MAC" grep -qx 'WAN_MAC=02:aa:bb:cc:dd:ee' "$ENV_FILE"
check "live address" bash -c 'test "$(tr -d "[:space:]" <"$1")" = "02:aa:bb:cc:dd:ee"' _ "$WORK/sys/eth0/address"
check "permanent сохранён" grep -qx 'WAN_PERMANENT_MAC=00:11:22:33:44:55' "$ENV_FILE"
check "hook: POSIX quoting" grep -Fq "!= 'eth0'" "$WAN_MAC_IFUP_HOOK"

# повтор с тем же MAC — без down/up (путь reapply после wan-dhcp)
: >"$LOG"
if "$SCRIPT" "02:aa:bb:cc:dd:ee" >"$WORK/out1b" 2>"$WORK/err1b"; then
  pass "reapply same MAC rc=0"
else
  fail "reapply same MAC rc=0 ($(cat "$WORK/err1b"))"
fi
check "reapply: unchanged" grep -Fq '(unchanged)' "$WORK/out1b"
check "reapply: без ip down" bash -c '! grep -q "link set dev eth0 down" "$LOG"'

# clear
if "$SCRIPT" "" >"$WORK/out2" 2>"$WORK/err2"; then
  pass "clear MAC rc=0"
else
  fail "clear MAC rc=0 ($(cat "$WORK/err2"))"
fi
check "hook удалён" test ! -e "$WAN_MAC_IFUP_HOOK"
check ".env WAN_MAC пуст" grep -qx 'WAN_MAC=' "$ENV_FILE"
check "live вернулся" bash -c 'test "$(tr -d "[:space:]" <"$1")" = "00:11:22:33:44:55"' _ "$WORK/sys/eth0/address"

# netplan
sed -i 's/^NET_STACK=.*/NET_STACK=netplan/' "$ENV_FILE"
: >"$LOG"
if "$SCRIPT" "02:11:22:33:44:55" >"$WORK/out3" 2>"$WORK/err3"; then
  pass "set MAC netplan rc=0"
else
  fail "set MAC netplan rc=0 ($(cat "$WORK/err3"))"
fi
check "netplan yaml" test -f "$WAN_MAC_NETPLAN"
check "yaml macaddress" grep -Fq 'macaddress: "02:11:22:33:44:55"' "$WAN_MAC_NETPLAN"
check "netplan generate" grep -qx 'netplan generate' "$LOG"
check "netplan apply" grep -qx 'netplan apply' "$LOG"

# multicast rejected
if "$SCRIPT" "01:00:5e:00:00:01" >"$WORK/out4" 2>"$WORK/err4"; then
  fail "multicast отклонён"
else
  pass "multicast отклонён"
fi

# unmanaged hook refused
sed -i 's/^NET_STACK=.*/NET_STACK=ifupdown/' "$ENV_FILE"
printf '#!/bin/sh\necho foreign\n' >"$WAN_MAC_IFUP_HOOK"
chmod 755 "$WAN_MAC_IFUP_HOOK"
if "$SCRIPT" "02:aa:bb:cc:dd:ee" >"$WORK/out5" 2>"$WORK/err5"; then
  fail "unmanaged hook отказ"
else
  pass "unmanaged hook отказ"
fi
check "stderr про unmanaged" grep -qi 'маркера\|управляется\|отказ' "$WORK/err5"

if [[ "$fails" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
fi
echo "FAILED: $fails"
exit 1
