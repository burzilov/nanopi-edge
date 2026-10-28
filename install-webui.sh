#!/bin/bash
# install-webui.sh — установка / обновление nanopi-webui с GitHub Release.
#
# Интерактивно (первый раз):
#   bash install-webui.sh
#
# Неинтерактивно (WebUI «Обновления» / cron):
#   bash install-webui.sh --noninteractive
#   WEBUI_VERSION=v0.0.2 bash install-webui.sh --noninteractive
#
# Репозиторий: WEBUI_GITHUB_REPO из окружения или /opt/nanopi-edge/.env
# (пишет install-singbox.sh).
#
# После установки EDGE_VERSION в .env выставляется равным тегу поставленного
# релиза (не понижается, остальные строки .env не трогаются).
#
set -euo pipefail

OPT_ROOT=/opt/nanopi-edge
OPT_ENV="$OPT_ROOT/.env"
BIN_DST=/usr/local/bin/nanopi-webui
UNIT_DST=/etc/systemd/system/nanopi-webui.service
SCRIPT_DST="$OPT_ROOT/install-webui.sh"
WEBUI_GITHUB_REPO="${WEBUI_GITHUB_REPO:-}"
WEBUI_VERSION="${WEBUI_VERSION:-}"
ASSET_NAME=            # nanopi-webui-linux-<amd64|arm64>.tar.gz — по uname -m (need_arch)
NONINTERACTIVE=0
_WEBUI_INSTALL_TMP=
WEBUI_TAG=            # фактический тег скачанного релиза (download_release)

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
ok() { echo "    OK: $*"; }

cleanup_tmp() { rm -rf "${_WEBUI_INSTALL_TMP:-}"; }

need_root() { [[ $(id -u) -eq 0 ]] || die "нужен root"; }

# uname -m → GOARCH ассета релиза (NANOPI_UNAME_M — для тестов).
webui_arch() {
  case "${1:-$(uname -m)}" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) return 1 ;;
  esac
}

need_arch() {
  local m arch
  m="${NANOPI_UNAME_M:-$(uname -m)}"
  arch=$(webui_arch "$m") \
    || die "архитектура ${m} не поддерживается: есть сборки только для x86_64 (amd64) и aarch64 (arm64)"
  ASSET_NAME="nanopi-webui-linux-${arch}.tar.gz"
}

# curl и jq нужны для GitHub API; если их нет — ставим из apt (неинтерактивно).
ensure_deps() {
  local missing=() c
  for c in curl jq; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  command -v apt-get >/dev/null 2>&1 || die "нужны: ${missing[*]} (apt-get нет — поставь вручную)"
  info "Ставлю: ${missing[*]} ca-certificates"
  DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null \
    || die "apt-get update не прошёл"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    "${missing[@]}" ca-certificates >/dev/null \
    || die "не удалось поставить: ${missing[*]}"
}

for arg in "$@"; do
  case "$arg" in
    --noninteractive|-y) NONINTERACTIVE=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--noninteractive]

  WEBUI_GITHUB_REPO  из окружения или ${OPT_ENV} (обязателен)
  WEBUI_VERSION       tag (v0.0.1) или пусто = latest
  Архитектура по uname -m: x86_64 → nanopi-webui-linux-amd64.tar.gz,
  aarch64 → nanopi-webui-linux-arm64.tar.gz
EOF
      exit 0
      ;;
    *) die "unknown arg: $arg" ;;
  esac
done

api_get() {
  local url="$1"
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "User-Agent: nanopi-webui-installer" \
    "$url"
}

download_release() {
  local tmp="$1"
  local api_base="https://api.github.com/repos/${WEBUI_GITHUB_REPO}"
  local meta download_url tag

  info "Скачиваю ${ASSET_NAME} из ${WEBUI_GITHUB_REPO} (${WEBUI_VERSION:-latest})"

  if [[ -n "$WEBUI_VERSION" ]]; then
    meta=$(api_get "${api_base}/releases/tags/${WEBUI_VERSION}")
  else
    meta=$(api_get "${api_base}/releases/latest")
  fi

  tag=$(echo "$meta" | jq -r '.tag_name // empty')
  [[ -n "$tag" ]] || die "не удалось получить tag release"

  download_url=$(echo "$meta" | jq -r --arg n "$ASSET_NAME" \
    '.assets[] | select(.name == $n) | .browser_download_url' | head -1)
  [[ -n "$download_url" && "$download_url" != null ]] \
    || die "в release ${tag} нет ассета ${ASSET_NAME}"

  info "Release ${tag}"
  WEBUI_TAG="$tag"
  curl -fsSL -o "$tmp/$ASSET_NAME" "$download_url"
  printf '%s\n' "$tag" > "$tmp/TAG"
}

# 0, если тег $1 строго меньше $2 (vX.Y.Z, сравнение sort -V).
semver_lt() {
  local a="${1#v}" b="${2#v}"
  [[ "$a" != "$b" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)" == "$a" ]]
}

# Идемпотентно выставить KEY=VAL в dotenv-файле:
#  - существующая строка KEY= заменяется на месте (дубли удаляются),
#    иначе строка дописывается в конец;
#  - остальные строки и их порядок не меняются;
#  - перевод строки в конце файла гарантируется (в т.ч. если его не было);
#  - запись через `cat >` в тот же файл — права/владелец/inode сохраняются;
#  - если содержимое не изменилось, файл не перезаписывается.
env_file_set_kv() {
  local file="$1" key="$2" val="$3" tmp
  val=${val//$'\n'/}
  tmp=$(mktemp)
  if ! K="$key" V="$val" awk '
    BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"]; done = 0 }
    {
      l = $0
      sub(/^[ \t]+/, "", l)
      if (index(l, k "=") == 1) {
        if (!done) { print k "=" v; done = 1 }
        next
      }
      print
    }
    END { if (!done) print k "=" v }
  ' "$file" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! cmp -s "$tmp" "$file"; then
    cat "$tmp" >"$file"
  fi
  rm -f "$tmp"
}

# EDGE_VERSION в .env = тег ставящегося релиза (монорепо: один тег на панель
# и edge-скрипты). Метку не понижаем: если в .env уже более новая версия
# (например, отдельно поставили старую панель), оставляем её.
# install-singbox.sh пишет EDGE_VERSION только когда его передали явно, поэтому
# при обновлении edge → webui (WebUI «Обновить», CI) оба пишут один и тот же тег.
sync_edge_version() {
  local tag="$1" cur=""
  [[ -n "$tag" && -f "$OPT_ENV" ]] || return 0
  if [[ ! "$tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    echo "    WARN: тег '${tag}' не похож на vX.Y.Z — EDGE_VERSION не трогаю"
    return 0
  fi
  cur=$(sed -n 's/^[[:space:]]*EDGE_VERSION=//p' "$OPT_ENV" | head -1 | tr -d "\"'[:space:]")
  if [[ "$cur" == "$tag" ]]; then
    ok "EDGE_VERSION=${tag} (без изменений)"
    return 0
  fi
  if [[ "$cur" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]] && semver_lt "$tag" "$cur"; then
    ok "EDGE_VERSION=${cur} новее ${tag} — не понижаю"
    return 0
  fi
  env_file_set_kv "$OPT_ENV" EDGE_VERSION "$tag"
  ok "EDGE_VERSION: ${cur:-<нет>} → ${tag}"
}

install_from_archive() {
  local archive="$1"
  local stage
  stage=$(mktemp -d)
  tar -xzf "$archive" -C "$stage"
  local bin unit
  bin=$(find "$stage" -type f -name nanopi-webui | head -1)
  unit=$(find "$stage" -type f -name nanopi-webui.service | head -1)
  [[ -n "$bin" && -f "$bin" ]] || die "в архиве нет nanopi-webui"

  info "Ставлю бинарь → ${BIN_DST}"
  install -m 755 "$bin" "$BIN_DST"

  if [[ -n "$unit" && -f "$unit" ]]; then
    install -m 644 "$unit" "$UNIT_DST"
  else
    cat > "$UNIT_DST" <<'EOF'
[Unit]
Description=NanoPi sing-box web UI
After=network-online.target sing-box.service
Wants=network-online.target

[Service]
Type=simple
KillMode=process
EnvironmentFile=-/opt/nanopi-edge/.env
Environment=WEBUI_ENV=/opt/nanopi-edge/.env
ExecStart=/usr/local/bin/nanopi-webui
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF
  fi

  mkdir -p "$OPT_ROOT"
  # скрипт — отдельный ассет релиза; на плате сохраняем копию запускаемого файла
  # (если уже запущен из SCRIPT_DST — не трогаем: install src==dst → exit 1)
  if [[ -f "${BASH_SOURCE[0]}" ]]; then
    local src_abs dst_abs
    src_abs=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")
    dst_abs=$(readlink -f "$SCRIPT_DST" 2>/dev/null || realpath "$SCRIPT_DST" 2>/dev/null || echo "$SCRIPT_DST")
    if [[ "$src_abs" != "$dst_abs" ]]; then
      install -m 755 "${BASH_SOURCE[0]}" "$SCRIPT_DST"
    else
      chmod 755 "$SCRIPT_DST" 2>/dev/null || true
    fi
  fi

  # дописать WEBUI_GITHUB_REPO в .env только если вызывающий явно передал репо
  if [[ -n "${WEBUI_GITHUB_REPO:-}" && -f "$OPT_ENV" ]] && ! grep -q '^WEBUI_GITHUB_REPO=' "$OPT_ENV"; then
    printf '\nWEBUI_GITHUB_REPO=%s\n' "$WEBUI_GITHUB_REPO" >> "$OPT_ENV"
  fi

  # Метка версии edge в .env — до restart (воркер apply может умереть вместе с панелью).
  sync_edge_version "${WEBUI_TAG:-${WEBUI_VERSION:-}}" \
    || echo "    WARN: не удалось записать EDGE_VERSION в ${OPT_ENV}"

  # До restart: зафиксировать apply=ok. Иначе при KillMode=cgroup воркер
  # (--apply-update / setsid) может умереть вместе с панелью, а UI навсегда
  # останется на «Обновляю WebUI…» (status=running).
  mark_update_status_ok_before_restart

  systemctl daemon-reload
  systemctl enable nanopi-webui
  systemctl restart nanopi-webui
  sleep 1
  systemctl is-active --quiet nanopi-webui || {
    journalctl -u nanopi-webui -n 40 --no-pager >&2 || true
    die "nanopi-webui не active"
  }
  ok "nanopi-webui active"
  rm -rf "$stage"
}

# Пишет update-status.json state=ok, если идёт фоновый apply.
mark_update_status_ok_before_restart() {
  local path="${UPDATE_STATUS_PATH:-$OPT_ROOT/update-status.json}"
  [[ -f "$path" ]] || return 0
  grep -q '"state"[[:space:]]*:[[:space:]]*"running"' "$path" 2>/dev/null || return 0
  local ver=""
  ver=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$path" | head -1)
  [[ -n "$ver" ]] || ver="${WEBUI_VERSION:-unknown}"
  local tmp="${path}.tmp"
  cat >"$tmp" <<EOF
{
  "state": "ok",
  "version": "$ver",
  "step": "done",
  "updated_at": $(date +%s)
}
EOF
  mv -f "$tmp" "$path"
  ok "update-status → ok (до restart панели)"
}

smoke_test() {
  # shellcheck disable=SC1090
  source "$OPT_ENV"
  local listen="${WEBUI_LISTEN:-10.10.10.1:80}"
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 "http://${listen}/" || echo "000")
  if [[ "$code" =~ ^[23] ]]; then
    ok "HTTP ${code} на http://${listen}/"
  else
    echo "    WARN: HTTP ${code} на http://${listen}/"
  fi
  if curl -fsS --connect-timeout 3 "http://${listen}/api/version" >/dev/null 2>&1; then
    ok "GET /api/version"
    curl -fsS "http://${listen}/api/version" | jq -c . || true
  fi
}

main() {
  need_root
  need_arch

  if [[ "$NONINTERACTIVE" -eq 0 ]]; then
    cat <<EOF
╔══════════════════════════════════════════════════════════╗
║  NanoPi webui install                                    ║
╚══════════════════════════════════════════════════════════╝
EOF
  fi

  [[ -f "$OPT_ENV" ]] || die "нет ${OPT_ENV} — сначала install-singbox.sh"
  [[ -f /etc/sing-box/config.json ]] || die "нет /etc/sing-box/config.json"
  ensure_deps

  # shellcheck disable=SC1090
  # CLI/env вызывающего имеют приоритет над значениями из .env
  local repo_cli="${WEBUI_GITHUB_REPO:-}"
  local ver_cli="${WEBUI_VERSION:-}"
  source "$OPT_ENV"
  [[ -n "${CLASH_SECRET:-}" ]] || die "в .env нет CLASH_SECRET"
  if [[ -n "$repo_cli" ]]; then
    WEBUI_GITHUB_REPO="$repo_cli"
  fi
  WEBUI_GITHUB_REPO="${WEBUI_GITHUB_REPO:-}"
  [[ -n "$WEBUI_GITHUB_REPO" ]] || die "нет WEBUI_GITHUB_REPO — добавь в ${OPT_ENV} (install-singbox) или передай в env"
  if [[ -n "$ver_cli" ]]; then
    WEBUI_VERSION="$ver_cli"
  fi

  info "repo=${WEBUI_GITHUB_REPO} version=${WEBUI_VERSION:-latest}"

  _WEBUI_INSTALL_TMP=$(mktemp -d)
  trap cleanup_tmp EXIT

  download_release "$_WEBUI_INSTALL_TMP"
  install_from_archive "$_WEBUI_INSTALL_TMP/$ASSET_NAME"

  if [[ "$NONINTERACTIVE" -eq 0 ]]; then
    smoke_test
  fi

  info "Готово. Скрипт на плате: ${SCRIPT_DST}"
  # явная уборка до выхода — чтобы EXIT-trap не споткнулся о set -u
  cleanup_tmp
  trap - EXIT
}

# INSTALL_WEBUI_LIB_ONLY=1 — только подключить функции (тесты), без main.
[[ -n "${INSTALL_WEBUI_LIB_ONLY:-}" ]] || main "$@"
