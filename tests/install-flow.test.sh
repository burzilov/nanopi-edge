#!/bin/bash
# Тест: порядок установки и готовность (v0.1.16):
#  • unit sing-box и drop-in dnsmasq ставятся только после бинарника (нет 203/EXEC);
#  • apt не стартует службы (policy-rc.d) и убирает за собой;
#  • скачивание с повторами; ожидание готовности sing-box с диагностикой;
#  • proxy-тест по цепочке clash_api (без ложного PASS за чужим VPN);
#  • redirect-порт auto_redirect закрыт reject-правилом sing-box.
# Запуск: bash tests/install-flow.test.sh  (root и плата не нужны: curl/ss/nft/systemctl — фейки)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

NANOPI_INSTALL_LIB_ONLY=1
# shellcheck disable=SC1091
source "$ROOT/install-singbox.sh"
set +e
trap 'rm -rf "$WORK"' EXIT

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
check() { local n="$1"; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }

LOG="$WORK/calls.log"; export LOG
B="$WORK/bin"; mkdir -p "$B"
printf '#!/bin/bash\necho "systemctl $*" >>"$LOG"\n' >"$B/systemctl"
chmod +x "$B"/*
export PATH="$B:$PATH"

# ─── порядок шагов в cmd_install ────────────────────────────────────
body=$(declare -f cmd_install)
n_bin=$(grep -n 'install_singbox_binary' <<<"$body" | head -1 | cut -d: -f1)
n_units=$(grep -n 'install_service_units' <<<"$body" | head -1 | cut -d: -f1)
n_pkgs=$(grep -n 'install_packages' <<<"$body" | head -1 | cut -d: -f1)
check "cmd_install: unit после бинарника" test -n "$n_units" -a "${n_units:-0}" -gt "${n_bin:-999}"
check "cmd_install: unit после apt" test "${n_units:-0}" -gt "${n_pkgs:-999}"
bundle=$(declare -f install_scripts_bundle)
check "scripts bundle не ставит unit/drop-in и не enable" \
  bash -c '! grep -qE "UNIT_DST|DNSMASQ_DROPIN|enable sing-box|dnsmasq.service.d" <<<"$1"' _ "$bundle"
check "templates: tar --no-same-owner + chown root:root" \
  bash -c 'grep -q -- "--no-same-owner" <<<"$1" && grep -q "chown -R root:root" <<<"$1"' _ "$bundle"
check "drop-in dnsmasq: Requires=sing-box, без Wants=" \
  bash -c 'grep -qx "Requires=sing-box.service" "$1" && ! grep -q "^Wants=" "$1"' _ "$ROOT/templates/dnsmasq-sing-box.conf"

# ─── install_service_units ──────────────────────────────────────────
OPT_ROOT="$WORK/opt"; mkdir -p "$OPT_ROOT/templates"
cp "$ROOT/templates/sing-box.service" "$ROOT/templates/dnsmasq-sing-box.conf" "$OPT_ROOT/templates/"
SINGBOX_BIN="$WORK/sing-box"
UNIT_DST="$WORK/systemd/sing-box.service"; mkdir -p "$WORK/systemd"
DNSMASQ_DROPIN="$WORK/systemd/dnsmasq.service.d/sing-box.conf"
: >"$LOG"
(install_service_units) >"$WORK/u1" 2>&1; rc=$?
check "нет бинарника → стоп" test $rc -ne 0
check "нет бинарника → unit не поставлен" test ! -e "$UNIT_DST"
check "нет бинарника → drop-in не поставлен" test ! -e "$DNSMASQ_DROPIN"
check "нет бинарника → без systemctl enable" bash -c '! grep -q enable "$LOG"'
printf '#!/bin/sh\necho "sing-box version 1.14.4"\n' >"$SINGBOX_BIN"; chmod +x "$SINGBOX_BIN"
(install_service_units) >"$WORK/u2" 2>&1; rc=$?
check "бинарник есть → rc=0" test $rc -eq 0
check "→ unit на месте" cmp -s "$UNIT_DST" "$ROOT/templates/sing-box.service"
check "→ drop-in на месте" cmp -s "$DNSMASQ_DROPIN" "$ROOT/templates/dnsmasq-sing-box.conf"
check "→ daemon-reload перед enable" bash -c 'grep -n . "$LOG" | grep -q "1:systemctl daemon-reload" && grep -qx "systemctl enable sing-box" "$LOG"'

# ─── policy-rc.d на время apt ───────────────────────────────────────
POLICY_RC="$WORK/policy-rc.d"
policy_rc_block >/dev/null
check "policy-rc.d создан, exit 101" bash -c '"$1"; test $? -eq 101' _ "$POLICY_RC"
policy_rc_restore
check "policy-rc.d убран после apt" test ! -e "$POLICY_RC"
printf '#!/bin/sh\nexit 0\n' >"$POLICY_RC"
policy_rc_block >/dev/null; policy_rc_restore
check "чужой policy-rc.d не трогаем" grep -qx 'exit 0' "$POLICY_RC"
rm -f "$POLICY_RC"
(POLICY_RC="$WORK/p2"; policy_rc_block >/dev/null; exit 3) ; rc=$?
check "выход скрипта (die) → policy-rc.d убран trap'ом" test ! -e "$WORK/p2" -a $rc -eq 3

# install_packages в lab: mask dnsmasq и policy-rc.d ДО apt-get install
cat >"$B/apt-get" <<'S'
#!/bin/bash
echo "apt-get $1 policy=$([[ -e "$POLICY_RC_PATH" ]] && echo on || echo off)" >>"$LOG"
S
cat >"$B/dpkg-query" <<'S'
#!/bin/bash
exit 1
S
chmod +x "$B"/*
: >"$LOG"
(POLICY_RC="$WORK/p3"; export POLICY_RC_PATH="$POLICY_RC"
 detect_router_live() { ROUTER_LIVE=0; }; detect_net_stack() { echo netplan; }
 install_packages) >/dev/null 2>&1; rc=$?
check "install_packages (lab) → rc=0" test $rc -eq 0
check "mask dnsmasq раньше apt-get install" bash -c '
  m=$(grep -n "systemctl mask dnsmasq" "$LOG" | head -1 | cut -d: -f1)
  a=$(grep -n "apt-get install" "$LOG" | head -1 | cut -d: -f1)
  [[ -n "$m" && -n "$a" && "$m" -lt "$a" ]]'
check "apt-get install при policy-rc.d" grep -q 'apt-get install policy=on' "$LOG"
check "после apt policy-rc.d нет" test ! -e "$WORK/p3"
: >"$LOG"
(POLICY_RC="$WORK/p4"; export POLICY_RC_PATH="$POLICY_RC"
 detect_router_live() { ROUTER_LIVE=1; }; detect_net_stack() { echo netplan; }
 install_packages) >/dev/null 2>&1
check "router live: dnsmasq не mask, policy-rc.d не ставим" \
  bash -c '! grep -q "mask dnsmasq" "$LOG" && grep -q "apt-get install policy=off" "$LOG"'

# ─── download_file: повторы ─────────────────────────────────────────
cat >"$B/curl" <<'S'
#!/bin/bash
n=$(cat "$CURL_CNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$CURL_CNT"
out=""; while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && { out="$2"; shift; }; shift; done
if [[ "$n" -ge "${CURL_OK_AT:-99}" ]]; then echo data >"$out"; exit 0; fi
exit 7
S
chmod +x "$B/curl"
sleep() { :; }
export CURL_CNT="$WORK/cnt"
rm -f "$CURL_CNT"; CURL_OK_AT=3 download_file http://x "$WORK/f1" f1 >"$WORK/d1" 2>&1; rc=$?
check "download: 3-я попытка успешна → rc=0" test $rc -eq 0 -a -s "$WORK/f1"
check "download: сообщает о повторах" grep -q 'попытка 1/3' "$WORK/d1"
rm -f "$CURL_CNT"; CURL_OK_AT=99 download_file http://x "$WORK/f2" f2 >/dev/null 2>&1; rc=$?
check "download: 3 неудачи → rc≠0, файла нет" test $rc -ne 0 -a ! -e "$WORK/f2"
check "sing-box качается через download_file" bash -c 'declare -f install_singbox_binary >/dev/null; grep -q download_file <<<"$1" && grep -q "несколько минут" <<<"$1"' _ "$(declare -f install_singbox_binary)"

# ─── wait_singbox_ready ─────────────────────────────────────────────
OPT_ENV="$WORK/.env"; printf 'CLASH_API=http://127.0.0.1:9090\nCLASH_SECRET=s3cr3t\n' >"$OPT_ENV"
for c in journalctl ss; do printf '#!/bin/bash\nexit 0\n' >"$B/$c"; done
cat >"$B/ip" <<'S'
#!/bin/bash
[[ -n "${TUN_UP:-}" ]] && exit 0
exit 1
S
cat >"$B/curl" <<'S'
#!/bin/bash
echo "curl $*" >>"$LOG"
[[ -n "${NET_UP:-}" ]] && exit 0
exit 7
S
chmod +x "$B"/*
: >"$LOG"
(NANOPI_READY_TIMEOUT=6 wait_singbox_ready) >"$WORK/w1" 2>&1; rc=$?
check "ready: таймаут → rc=1" test $rc -eq 1
check "ready: таймаут → диагностика" grep -q 'диагностика' "$WORK/w1"
check "ready: печатает что не готово" grep -q 'sb-tun=нет' "$WORK/w1"
check "ready: секрет не печатается" bash -c '! grep -q s3cr3t "$1"' _ "$WORK/w1"
(TUN_UP=1 NET_UP=1 NANOPI_READY_TIMEOUT=6 wait_singbox_ready) >"$WORK/w2" 2>&1; rc=$?
check "ready: всё поднято → rc=0" test $rc -eq 0
check "start_singbox: без «sleep 3», ждёт готовность" bash -c 'grep -q wait_singbox_ready <<<"$1" && ! grep -q "sleep 3" <<<"$1"' _ "$(declare -f start_singbox)"

# ─── test_proxy_path ────────────────────────────────────────────────
SB_CFG="$WORK/config.json"
cat >"$SB_CFG" <<'J'
{"outbounds":[{"type":"direct","tag":"direct"},
 {"type":"vless","tag":"finland","server":"203.0.113.10"},
 {"type":"vless","tag":"germany","server":"203.0.113.20"},
 {"type":"selector","tag":"proxy","outbounds":["finland","germany"],"default":"finland"}]}
J
CLASH_API=http://127.0.0.1:9090; CLASH_SECRET=s3cr3t
cat >"$B/curl" <<'S'
#!/bin/bash
url="${!#}"
case "$url" in
  */proxies/proxy) echo '{"now":"finland","type":"Selector"}' ;;
  */connections)
    if [[ -n "${CHAINS:-}" ]]; then
      printf '{"connections":[{"chains":%s,"metadata":{"host":"api.ipify.org"}}]}\n' "$CHAINS"
    else echo '{"connections":[]}'; fi ;;
  https://api.ipify.org) echo "${EGRESS_IP:-203.0.113.10}" ;;
  *) exit 0 ;;
esac
S
printf '#!/bin/bash\nexit 0\n' >"$B/openssl"
chmod +x "$B"/*
(CHAINS='["finland","proxy"]' test_proxy_path) >"$WORK/p1" 2>&1; rc=$?
check "proxy: цепочка finland←proxy, IP узла → PASS" test $rc -eq 0
check "proxy: сверка IP узла" grep -q '= адрес узла finland' "$WORK/p1"
(CHAINS='["finland","proxy"]' EGRESS_IP=198.51.100.5 test_proxy_path) >"$WORK/p2" 2>&1; rc=$?
check "proxy: через proxy, но выход VPS с другого IP → PASS с пометкой" \
  bash -c 'test "$1" -eq 0 && grep -q "выход может быть" "$2"' _ $rc "$WORK/p2"
(CHAINS='["direct"]' EGRESS_IP=198.51.100.5 test_proxy_path) >"$WORK/p3" 2>&1; rc=$?
check "proxy: цепочка direct → FAIL" test $rc -ne 0
(CHAINS='' EGRESS_IP=198.51.100.5 test_proxy_path) >"$WORK/p4" 2>&1; rc=$?
check "proxy: соединения нет в clash_api (чужой VPN снаружи) → FAIL" test $rc -ne 0
check "proxy: объясняет, что внешний IP не доказательство" grep -q 'не доказательство' "$WORK/p4"
(CHAINS='["germany","proxy"]' test_proxy_path) >/dev/null 2>&1; rc=$?
check "proxy: узел ≠ выбранному → FAIL" test $rc -ne 0

# ─── redirect-порт (auto_redirect) ──────────────────────────────────
cat >"$B/ss" <<'S'
#!/bin/bash
cat <<E
LISTEN 0 4096 127.0.0.1:9090 0.0.0.0:* users:(("sing-box",pid=1,fd=9))
LISTEN 0 4096 0.0.0.0:39439 0.0.0.0:* users:(("sing-box",pid=1,fd=7))
LISTEN 0 128 0.0.0.0:2208 0.0.0.0:* users:(("sshd",pid=2,fd=3))
E
S
cat >"$B/nft" <<'S'
#!/bin/bash
if [[ -n "${NFT_REJECT:-}" ]]; then
cat <<E
table inet sing-box {
	chain input {
		type filter hook input priority filter; policy accept;
		tcp dport 39439 ct status ! dnat reject with tcp reset
	}
}
E
else
echo 'table inet sing-box { chain input { type filter hook input priority filter; policy accept; } }'
fi
S
chmod +x "$B"/*
MOBILE_VLESS_STATE="$WORK/none.json"
(NFT_REJECT=1 test_redirect_port_closed) >"$WORK/r1" 2>&1; rc=$?
check "redirect :39439 + reject sing-box → PASS" bash -c 'test "$1" -eq 0 && grep -q ":39439 закрыт" "$2"' _ $rc "$WORK/r1"
(test_redirect_port_closed) >"$WORK/r2" 2>&1; rc=$?
check "redirect :39439 без reject → FAIL" test $rc -ne 0
check "loopback :9090 и чужой sshd не проверяются" bash -c '! grep -qE ":9090|:2208" "$1"' _ "$WORK/r1"

# Настоящий nft (если есть и пускает в user netns): формат правила sing-tun.
if command -v unshare >/dev/null 2>&1 && PATH="${PATH#"$B:"}" unshare -rn nft list ruleset >/dev/null 2>&1; then
  real=$(PATH="${PATH#"$B:"}" unshare -rn sh -c 'nft -f - <<E && nft list chain inet sing-box input
table inet sing-box { chain input { type filter hook input priority filter; policy accept; tcp dport 39439 ct status != dnat reject with tcp reset; } }
E' 2>&1)
  check "nft (unshare): reject-правило sing-tun распознаётся" grep -qE "tcp dport 39439( .*)? reject" <<<"$real"
else
  echo "skip - nft в unshare недоступен"
fi

echo
if [[ $fails -eq 0 ]]; then echo "ВСЕ ТЕСТЫ ПРОЙДЕНЫ"; exit 0; fi
echo "ОШИБОК: $fails"; exit 1
