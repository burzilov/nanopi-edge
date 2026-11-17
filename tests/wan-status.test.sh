#!/bin/bash
# Изолированная проверка диагностики wan-status без systemd и сетевых изменений.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/bash
exit 0
EOF
cat >"$tmp/bin/systemctl" <<'EOF'
#!/bin/bash
echo active
EOF
cat >"$tmp/bin/journalctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >"$JOURNAL_ARGS"
[[ "${JOURNAL_FAIL:-0}" != 1 ]] || exit 1
cat "$JOURNAL_DATA"
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" ENV_FILE="$tmp/env" PPP_SECRET_FILE="$tmp/secret"
export JOURNAL_DATA="$tmp/journal" JOURNAL_ARGS="$tmp/journal-args"
printf 'WAN_IF=eth0\nLAN_IF=eth1\nWAN_MODE=pppoe\n' >"$ENV_FILE"
printf 'secret-password' >"$PPP_SECRET_FILE"

status() { bash "$root/scripts/wan-status" | jq -r .last_error; }
assert_eq() {
  if [[ "$1" != "$2" ]]; then
    printf 'Expected: %s\nActual:   %s\n' "$2" "$1" >&2
    exit 1
  fi
}

cat >"$JOURNAL_DATA" <<'EOF'
CHAP authentication succeeded
PAP authentication succeeded
CHAP authentication success
EOF
assert_eq "$(status)" ''
assert_eq "$(cat "$JOURNAL_ARGS")" '-u nanopi-wan-pppoe.service -n 30 --no-pager -o cat'

cat >"$JOURNAL_DATA" <<'EOF'
CHAP authentication failed: secret-password
Timeout waiting for PADO packets: secret-password
Connection terminated: secret-password
PAP authentication succeeded
EOF
assert_eq "$(status)" 'Прошлые события журнала PPPoE: ошибка аутентификации; время ожидания истекло; соединение разорвано'

cat >"$JOURNAL_DATA" <<'EOF'
PAP authentication failed: secret-password
Peer refused to authenticate
Modem hangup
LCP: timeout sending Config-Requests
EOF
assert_eq "$(status)" 'Прошлые события журнала PPPoE: ошибка аутентификации; соединение разорвано; время ожидания истекло'

printf 'Failed to start service: secret-password\n' >"$JOURNAL_DATA"
assert_eq "$(status)" 'Прошлые события журнала PPPoE: ошибка подключения'
export JOURNAL_FAIL=1
assert_eq "$(status)" ''
unset JOURNAL_FAIL
printf 'WAN_IF=eth0\nLAN_IF=eth1\nWAN_MODE=dhcp\n' >"$ENV_FILE"
rm "$JOURNAL_ARGS"
assert_eq "$(status)" ''
[[ ! -e "$JOURNAL_ARGS" ]]
echo 'wan-status tests passed'
