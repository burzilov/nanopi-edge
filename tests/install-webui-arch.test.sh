#!/bin/bash
# Тест: install-webui.sh выбирает ассет панели по архитектуре (uname -m).
# Запуск: bash tests/install-webui-arch.test.sh  (root и плата не нужны)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALL_WEBUI_LIB_ONLY=1
# shellcheck disable=SC1091
source "$ROOT/install-webui.sh"
set +e

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

for pair in x86_64:amd64 amd64:amd64 aarch64:arm64 arm64:arm64; do
  m=${pair%%:*} want=${pair#*:}
  got=$(NANOPI_UNAME_M=$m; need_arch; echo "$ASSET_NAME")
  if [[ "$got" == "nanopi-webui-linux-${want}.tar.gz" ]]; then pass "$m → $got"; else fail "$m → $got"; fi
done

for m in armv7l i686 riscv64; do
  out=$( (NANOPI_UNAME_M=$m; need_arch) 2>&1 ); rc=$?
  if [[ $rc -ne 0 && "$out" == *"не поддерживается"* && "$out" == *"$m"* ]]; then
    pass "$m → понятная ошибка"
  else
    fail "$m: rc=$rc out=$out"
  fi
done

# без переопределения — по реальному uname -m этой машины
case "$(uname -m)" in
  x86_64) host=amd64 ;; aarch64) host=arm64 ;; *) host="" ;;
esac
if [[ -n "$host" ]]; then
  got=$(unset NANOPI_UNAME_M; need_arch; echo "$ASSET_NAME")
  [[ "$got" == "nanopi-webui-linux-${host}.tar.gz" ]] && pass "uname -m хоста → $got" || fail "uname -m хоста → $got"
fi

echo
if [[ $fails -gt 0 ]]; then echo "FAILED: $fails"; exit 1; fi
echo "все тесты install-webui-arch пройдены"
