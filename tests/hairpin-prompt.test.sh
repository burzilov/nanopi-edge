#!/bin/bash
# Тест: шаг мастера «Hairpin DNS» (prompt_hairpin_dns) — интерактив и NANOPI_YES.
# Запуск: bash tests/hairpin-prompt.test.sh  (root и плата не нужны)
# common.sh / hairpin-dns-refresh / systemctl — заглушки во временном каталоге.
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

# заглушки
SCRIPTS_DIR="$WORK/scripts"
OPT_ENV="$WORK/.env"
mkdir -p "$SCRIPTS_DIR" "$WORK/bin"
cat >"$SCRIPTS_DIR/common.sh" <<STUB
nanopi_load_env() { :; }
nanopi_write_hairpin_dns_alias() { echo "alias:\${HAIRPIN_DNS_TARGET}" >>"$WORK/calls"; }
STUB
printf '#!/bin/sh\nexit 0\n' >"$SCRIPTS_DIR/hairpin-dns-refresh"
chmod +x "$SCRIPTS_DIR/hairpin-dns-refresh"
printf '#!/bin/sh\necho "systemctl $*" >>"%s/calls"\nexit 0\n' "$WORK" >"$WORK/bin/systemctl"
chmod +x "$WORK/bin/systemctl"
PATH="$WORK/bin:$PATH"

# case name, .env до, ввод, env-переменные → проверка .env и вызовов
run() { # env_before input [VAR=val ...]
  local before="$1" input="$2"; shift 2
  printf '%s' "$before" >"$OPT_ENV"
  : >"$WORK/calls"
  env "$@" bash -c '
    NANOPI_INSTALL_LIB_ONLY=1 source "$0"
    SCRIPTS_DIR="$1"; OPT_ENV="$2"
    prompt_hairpin_dns
  ' "$ROOT/install-singbox.sh" "$SCRIPTS_DIR" "$OPT_ENV" <<<"$input" >"$WORK/out" 2>&1
  echo $? >"$WORK/rc"
}
target() { grep -E '^HAIRPIN_DNS_TARGET=' "$OPT_ENV" | cut -d= -f2-; }
check() { # name expected_target expected_calls(regex|"none")
  local t c ok=1
  t=$(target); c=$(tr '\n' ' ' <"$WORK/calls")
  [[ "$(cat "$WORK/rc")" == 0 ]] || ok=0
  [[ "$t" == "$2" ]] || ok=0
  if [[ "$3" == none ]]; then [[ -z "$c" ]] || ok=0; else [[ "$c" =~ $3 ]] || ok=0; fi
  grep -q '^OTHER=1$' "$OPT_ENV" || ok=0
  if [[ $ok == 1 ]]; then pass "$1"; else fail "$1 (target='$t' calls='$c')"; cat "$WORK/out"; fi
}

E=$'OTHER=1\n'
EH=$'OTHER=1\nHAIRPIN_DNS_TARGET=192.168.1.10\n'

run "$E" "192.168.1.20"
check "интерактив: новое значение → .env + alias + restart dnsmasq" 192.168.1.20 '^alias:192\.168\.1\.20 systemctl is-active --quiet dnsmasq systemctl restart dnsmasq $'
run "$E" ""
check "интерактив: Enter без значения → пропуск, ничего не трогаем" "" none
run "$EH" ""
check "интерактив: Enter при заданном → оставить, dnsmasq не трогаем" 192.168.1.10 none
run "$EH" "192.168.1.10"
check "интерактив: то же значение → без перезапуска" 192.168.1.10 none
run "$EH" "10.0.0.5"
check "интерактив: смена значения" 10.0.0.5 '^alias:10\.0\.0\.5 .*restart dnsmasq'
run "$EH" "-"
check "интерактив: «-» → выключить (ключ удалён, alias пустой)" "" '^alias: .*restart dnsmasq'
run "$E" $'999.1.1.1\nabc\n192.168.1.30'
check "интерактив: неверный IP → повтор вопроса" 192.168.1.30 '^alias:192\.168\.1\.30 '
run "$EH" $'x\ny\nz'
check "интерактив: 3 неверных ответа → без изменений, установка не падает" 192.168.1.10 none

run "$EH" "" NANOPI_YES=1 NANOPI_HAIRPIN_DNS_TARGET=10.9.9.9
check "NANOPI_YES: значение из .env не перезаписывается" 192.168.1.10 none
run "$E" "" NANOPI_YES=1 NANOPI_HAIRPIN_DNS_TARGET=10.9.9.9
check "NANOPI_YES: NANOPI_HAIRPIN_DNS_TARGET, если в .env нет" 10.9.9.9 '^alias:10\.9\.9\.9 '
run "$E" "" NANOPI_YES=1 NANOPI_HAIRPIN_DNS_TARGET=bad
check "NANOPI_YES: неверный NANOPI_HAIRPIN_DNS_TARGET → пропуск" "" none
run "$E" "" NANOPI_YES=1 HAIRPIN_DNS_TARGET=10.8.8.8
check "NANOPI_YES: унаследованный HAIRPIN_DNS_TARGET (WebUI) игнорируется" "" none
run "$E" "" NANOPI_YES=1
check "NANOPI_YES: ничего не задано → пропуск" "" none

# без hairpin-dns-refresh (scripts ещё не установлены) — только .env
rm -f "$SCRIPTS_DIR/hairpin-dns-refresh"
run "$E" "192.168.1.40"
check "без scripts/hairpin-dns-refresh: только .env, alias при router-on" 192.168.1.40 none

# мастер установки действительно вызывает шаг
if awk '/^cmd_install\(\)/,/^}/' "$ROOT/install-singbox.sh" | grep -q '^[[:space:]]*prompt_hairpin_dns[[:space:]]*$'; then
  pass "cmd_install вызывает prompt_hairpin_dns"
else
  fail "cmd_install вызывает prompt_hairpin_dns"
fi

echo
if [[ $fails -eq 0 ]]; then echo "итого: все PASS"; else echo "итого: FAIL=$fails"; exit 1; fi
