#!/bin/bash
# Тест: панель до router-on (v0.1.16).
#  • unit: без бесконечной петли перезапусков (RestartSec/StartLimit*);
#  • install-webui.sh: адреса 10.10.10.1 ещё нет → понятное сообщение, smoke пропущен;
#  • router-on запускает панель, если она установлена и не active (активную не трогает).
# Запуск: bash tests/webui-panel.test.sh  (root и плата не нужны: ip/systemctl — фейки)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
check() { local n="$1"; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }

LOG="$WORK/calls.log"; export LOG
B="$WORK/bin"; mkdir -p "$B"
cat >"$B/ip" <<'S'
#!/bin/bash
# ip -o addr show: lab — только 192.168.1.148; router — ещё 10.10.10.1
echo "2: enp1s0    inet 192.168.1.148/24 brd 192.168.1.255 scope global enp1s0"
[[ -n "${ROUTER:-}" ]] && echo "3: enp2s0    inet 10.10.10.1/24 brd 10.10.10.255 scope global enp2s0"
exit 0
S
cat >"$B/systemctl" <<'S'
#!/bin/bash
echo "systemctl $*" >>"$LOG"
case "$1" in
  cat) [[ -n "${UNIT_INSTALLED:-}" ]] ;;
  is-enabled) [[ -n "${UNIT_ENABLED:-}" ]] ;;
  is-active) [[ -n "${UNIT_ACTIVE:-}" ]] ;;
  *) exit 0 ;;
esac
S
chmod +x "$B"/*
export PATH="$B:$PATH"

# ─── unit-файлы ─────────────────────────────────────────────────────
for u in "$ROOT/webui/nanopi-webui.service"; do
  check "unit: RestartSec=5s" grep -qx 'RestartSec=5s' "$u"
  check "unit: StartLimitIntervalSec в [Unit]" bash -c 'sed -n "/^\[Unit\]/,/^\[/p" "$1" | grep -qx "StartLimitIntervalSec=300"' _ "$u"
  check "unit: StartLimitBurst=10" grep -qx 'StartLimitBurst=10' "$u"
done
check "запасной unit в install-webui.sh: те же лимиты" \
  bash -c 'grep -qx "RestartSec=5s" "$1" && grep -qx "StartLimitBurst=10" "$1" && ! grep -q "RestartSec=2s" "$1"' _ "$ROOT/install-webui.sh"

# ─── install-webui.sh: сообщение до router-on ──────────────────────
INSTALL_WEBUI_LIB_ONLY=1
# shellcheck disable=SC1091
source "$ROOT/install-webui.sh"
set +e
OPT_ENV="$WORK/.env"; printf 'WEBUI_LISTEN=10.10.10.1:80\n' >"$OPT_ENV"

webui_listen_present 10.10.10.1:80; check "lab: 10.10.10.1 нет" test $? -ne 0
(ROUTER=1 webui_listen_present 10.10.10.1:80); check "router: 10.10.10.1 есть" test $? -eq 0
check "wildcard 0.0.0.0:80 — всегда есть" webui_listen_present 0.0.0.0:80
check "[::]:80 — всегда есть" webui_listen_present '[::]:80'
check "host из 10.10.10.1:80" test "$(webui_listen_host 10.10.10.1:80)" == 10.10.10.1
out=$(webui_report_listen 2>&1)
check "lab: «после router-on» в сообщении" grep -q 'после router-on' <<<"$out"
out=$(ROUTER=1 webui_report_listen 2>&1)
check "router: адрес панели" grep -q 'http://10.10.10.1:80/' <<<"$out"
out=$(smoke_test 2>&1); rc=$?
check "lab: smoke-тест пропущен, rc=0" bash -c 'test "$1" -eq 0 && grep -q "smoke-тест пропущен" <<<"$2"' _ $rc "$out"
check "после restart проверка автоперезапусков (NRestarts)" \
  bash -c 'grep -q webui_nrestarts <<<"$1" && grep -q "r1 > r0" <<<"$1"' _ "$(declare -f install_from_archive)"

# ─── router-on → nanopi_ensure_webui ───────────────────────────────
# shellcheck disable=SC1091
source "$ROOT/scripts/common.sh"
check "router-on вызывает nanopi_ensure_webui после wan-dhcp" bash -c '
  w=$(grep -n "\"\$SCRIPT_DIR/wan-dhcp\"" "$1" | tail -1 | cut -d: -f1)
  e=$(grep -n "^nanopi_ensure_webui" "$1" | tail -1 | cut -d: -f1)
  [[ -n "$w" && -n "$e" && "$e" -gt "$w" ]]' _ "$ROOT/scripts/router-on"

: >"$LOG"; nanopi_ensure_webui >/dev/null 2>&1
check "панель не установлена → ничего не делаем" bash -c '! grep -q start "$LOG"'
: >"$LOG"; UNIT_INSTALLED=1 UNIT_ENABLED=1 UNIT_ACTIVE=1 nanopi_ensure_webui >/dev/null 2>&1
check "панель active → не перезапускаем" bash -c '! grep -qE "start|restart" "$LOG"'
: >"$LOG"; UNIT_INSTALLED=1 UNIT_ENABLED=1 nanopi_ensure_webui >/dev/null 2>&1
check "панель упала → reset-failed + start" bash -c 'grep -qx "systemctl reset-failed nanopi-webui" "$LOG" && grep -qx "systemctl start nanopi-webui" "$LOG"'
: >"$LOG"; UNIT_INSTALLED=1 nanopi_ensure_webui >/dev/null 2>&1
check "панель выключена (disabled) → не запускаем" bash -c '! grep -q "start nanopi-webui" "$LOG"'

echo
if [[ $fails -eq 0 ]]; then echo "ВСЕ ТЕСТЫ ПРОЙДЕНЫ"; exit 0; fi
echo "ОШИБОК: $fails"; exit 1
