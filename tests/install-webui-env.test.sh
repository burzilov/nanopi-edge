#!/bin/bash
# Тест: install-webui.sh выставляет EDGE_VERSION в .env (env_file_set_kv / sync_edge_version).
# Запуск: bash tests/install-webui-env.test.sh  (root и плата не нужны)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

INSTALL_WEBUI_LIB_ONLY=1
# shellcheck disable=SC1091
source "$ROOT/install-webui.sh"
set +e

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
expect_file() { # name file expected-content
  local got
  got=$(cat "$2"; echo x); got=${got%x}
  if [[ "$got" == "$3" ]]; then pass "$1"; else
    fail "$1"; printf '  ожидалось:\n%s  получено:\n%s' "$3" "$got"
  fi
}

OPT_ENV="$WORK/.env"

# 1. строки нет — дописать, остальные переменные на месте
printf 'CLASH_SECRET=abc\nHAIRPIN_DNS_TARGET=192.168.1.137\n' >"$OPT_ENV"
chmod 600 "$OPT_ENV"
sync_edge_version v0.1.8 >/dev/null
expect_file "нет строки → дописана" "$OPT_ENV" $'CLASH_SECRET=abc\nHAIRPIN_DNS_TARGET=192.168.1.137\nEDGE_VERSION=v0.1.8\n'
[[ $(stat -c %a "$OPT_ENV") == 600 ]] && pass "права 600 сохранены" || fail "права изменились: $(stat -c %a "$OPT_ENV")"

# 2. старая версия — замена на месте (порядок строк сохраняется)
printf 'A=1\nEDGE_VERSION=v0.1.6\nHAIRPIN_DNS_TARGET=192.168.1.137\n' >"$OPT_ENV"
chmod 640 "$OPT_ENV"
ino=$(stat -c %i "$OPT_ENV")
sync_edge_version v0.1.8 >/dev/null
expect_file "старая версия → замена на месте" "$OPT_ENV" $'A=1\nEDGE_VERSION=v0.1.8\nHAIRPIN_DNS_TARGET=192.168.1.137\n'
[[ $(stat -c %a "$OPT_ENV") == 640 && $(stat -c %i "$OPT_ENV") == "$ino" ]] && pass "права и inode сохранены" || fail "права/inode изменились"

# 3. идемпотентность — повтор не меняет файл (и mtime)
touch -d '2020-01-01' "$OPT_ENV"; m1=$(stat -c %Y "$OPT_ENV")
sync_edge_version v0.1.8 >/dev/null
env_file_set_kv "$OPT_ENV" EDGE_VERSION v0.1.8
[[ $(stat -c %Y "$OPT_ENV") == "$m1" ]] && pass "повтор не перезаписывает файл" || fail "файл перезаписан при повторе"

# 4. пустой файл
: >"$OPT_ENV"
sync_edge_version v0.1.8 >/dev/null
expect_file "пустой файл" "$OPT_ENV" $'EDGE_VERSION=v0.1.8\n'

# 5. без перевода строки в конце (последняя строка — другая переменная)
printf 'A=1\nHAIRPIN_DNS_TARGET=192.168.1.137' >"$OPT_ENV"
sync_edge_version v0.1.8 >/dev/null
expect_file "нет \\n в конце, ключа нет" "$OPT_ENV" $'A=1\nHAIRPIN_DNS_TARGET=192.168.1.137\nEDGE_VERSION=v0.1.8\n'

# 6. без перевода строки, ключ — последняя строка
printf 'A=1\nEDGE_VERSION=v0.1.6' >"$OPT_ENV"
sync_edge_version v0.1.8 >/dev/null
expect_file "нет \\n в конце, ключ последний" "$OPT_ENV" $'A=1\nEDGE_VERSION=v0.1.8\n'

# 7. дубли и кавычки — одна строка, на месте первой
printf 'EDGE_VERSION="v0.1.5"\nB=2\nEDGE_VERSION=v0.1.6\n' >"$OPT_ENV"
sync_edge_version v0.1.8 >/dev/null
expect_file "дубли → одна строка" "$OPT_ENV" $'EDGE_VERSION=v0.1.8\nB=2\n'

# 8. не понижать
printf 'EDGE_VERSION=v0.1.9\n' >"$OPT_ENV"
sync_edge_version v0.1.8 >/dev/null
expect_file "новее в .env → не понижаем" "$OPT_ENV" $'EDGE_VERSION=v0.1.9\n'

# 9. semver, а не строковое сравнение (v0.1.10 > v0.1.9)
printf 'EDGE_VERSION=v0.1.9\n' >"$OPT_ENV"
sync_edge_version v0.1.10 >/dev/null
expect_file "v0.1.9 → v0.1.10" "$OPT_ENV" $'EDGE_VERSION=v0.1.10\n'

# 10. unknown / пусто → перезаписать
printf 'EDGE_VERSION=unknown\n' >"$OPT_ENV"
sync_edge_version v0.1.8 >/dev/null
expect_file "unknown → тег" "$OPT_ENV" $'EDGE_VERSION=v0.1.8\n'

# 11. мусорный тег / пустой тег — не трогаем
printf 'EDGE_VERSION=v0.1.6\n' >"$OPT_ENV"
sync_edge_version latest >/dev/null
sync_edge_version "" >/dev/null
expect_file "невалидный/пустой тег → без изменений" "$OPT_ENV" $'EDGE_VERSION=v0.1.6\n'

# 12. закомментированная строка и похожий ключ не трогаются
printf '# EDGE_VERSION=v0.0.1\nEDGE_VERSION_OLD=x\n' >"$OPT_ENV"
sync_edge_version v0.1.8 >/dev/null
expect_file "комментарий и EDGE_VERSION_OLD целы" "$OPT_ENV" $'# EDGE_VERSION=v0.0.1\nEDGE_VERSION_OLD=x\nEDGE_VERSION=v0.1.8\n'

# 13. .env нет — ничего не создаём
rm -f "$OPT_ENV"
sync_edge_version v0.1.8 >/dev/null
[[ ! -e "$OPT_ENV" ]] && pass "нет .env → не создаём" || fail "создан .env"

if (( fails )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
