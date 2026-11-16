#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
NANOPI_INSTALL_LIB_ONLY=1 source "$ROOT/install-singbox.sh"
export NANOPI_PROC_SYS="$WORK/proc" LOG="$WORK/log" TEST_ROOT="$WORK"
mkdir -p "$NANOPI_PROC_SYS/net/ipv4" "$NANOPI_PROC_SYS/net/netfilter" "$WORK/bin"
export PATH="$WORK/bin:$PATH"
printf '#!/bin/bash\necho "$*" >> "$LOG"\n' > "$WORK/bin/sysctl"
cat > "$WORK/bin/modprobe" <<'S'
#!/bin/bash
echo "modprobe $*" >> "$LOG"
[[ ${MODPROBE_OK:-0} == 1 ]] || exit 1
touch "$NANOPI_PROC_SYS/net/netfilter/nf_conntrack_max"
S
cat > "$WORK/bin/modinfo" <<'S'
#!/bin/bash
exit "${MODINFO_STATUS:-1}"
S
cat > "$WORK/bin/apt-cache" <<'S'
#!/bin/bash
case "$2" in
  "linux-modules-$(uname -r)") echo '  Candidate: 1' ;;
  *) echo '  Candidate: (none)' ;;
esac
S
cat > "$WORK/bin/apt-get" <<'S'
#!/bin/bash
echo "apt-get $*" >> "$LOG"
[[ "$1" != install ]] || export MODPROBE_OK=1
[[ "$1" != install ]] || touch "$TEST_ROOT/installed"
S
# Установка имитирует появление модуля при следующем modprobe.
sed -i '/\[\[ ${MODPROBE_OK/ i [[ -f "$TEST_ROOT/installed" ]] \&\& MODPROBE_OK=1' "$WORK/bin/modprobe"
chmod +x "$WORK/bin/"*
touch "$NANOPI_PROC_SYS/net/ipv4/ip_forward"
: > "$LOG"
apply_sysctl_file "$ROOT/templates/99-nanopi-forward.conf"
grep -q 'net.ipv4.ip_forward=1' "$LOG"
! grep -q 'nf_conntrack' "$LOG"
: > "$LOG"
ensure_conntrack
test -e "$NANOPI_PROC_SYS/net/netfilter/nf_conntrack_max"
grep -Fq "linux-modules-$(uname -r)" "$LOG"
! grep -q 'linux-image-current' "$LOG"
: > "$LOG"
ensure_conntrack
test ! -s "$LOG"
rm "$NANOPI_PROC_SYS/net/netfilter/nf_conntrack_max" "$WORK/installed"
if ( MODINFO_STATUS=0 ensure_conntrack ) > "$WORK/failure" 2>&1; then
  echo 'FAIL: модуль без доступного ключа должен прервать установку' >&2; exit 1
fi
! grep -q 'apt-get' "$LOG"
grep -q 'nf_conntrack недоступен' "$WORK/failure"
echo 'Тесты conntrack пройдены'
