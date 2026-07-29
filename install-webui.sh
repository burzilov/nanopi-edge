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
set -euo pipefail

OPT_ROOT=/opt/nanopi-edge
OPT_ENV="$OPT_ROOT/.env"
BIN_DST=/usr/local/bin/nanopi-webui
UNIT_DST=/etc/systemd/system/nanopi-webui.service
SCRIPT_DST="$OPT_ROOT/install-webui.sh"
WEBUI_GITHUB_REPO="${WEBUI_GITHUB_REPO:-}"
WEBUI_VERSION="${WEBUI_VERSION:-}"
ASSET_NAME=nanopi-webui-linux-arm64.tar.gz
NONINTERACTIVE=0

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
ok() { echo "    OK: $*"; }

need_root() { [[ $(id -u) -eq 0 ]] || die "нужен root"; }

need_arch() {
  case $(uname -m) in
    aarch64|arm64) ;;
    *) die "ожидается aarch64 (NanoPi); сейчас: $(uname -m)" ;;
  esac
}

for arg in "$@"; do
  case "$arg" in
    --noninteractive|-y) NONINTERACTIVE=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--noninteractive]

  WEBUI_GITHUB_REPO  из окружения или ${OPT_ENV} (обязателен)
  WEBUI_VERSION       tag (v0.0.1) или пусто = latest
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
  curl -fsSL -o "$tmp/$ASSET_NAME" "$download_url"
  printf '%s\n' "$tag" > "$tmp/TAG"
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

  cat > "$UNIT_DST" <<'EOF'
[Unit]
Description=NanoPi sing-box web UI
After=network-online.target sing-box.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/opt/nanopi-edge/.env
Environment=WEBUI_ENV=/opt/nanopi-edge/.env
ExecStart=/usr/local/bin/nanopi-webui
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF
  [[ -n "$unit" ]] || true

  mkdir -p "$OPT_ROOT"
  # скрипт — отдельный ассет релиза; на плате сохраняем копию запускаемого файла
  if [[ -f "${BASH_SOURCE[0]}" ]]; then
    install -m 755 "${BASH_SOURCE[0]}" "$SCRIPT_DST"
  fi

  # дописать WEBUI_GITHUB_REPO в .env только если вызывающий явно передал репо
  if [[ -n "${WEBUI_GITHUB_REPO:-}" && -f "$OPT_ENV" ]] && ! grep -q '^WEBUI_GITHUB_REPO=' "$OPT_ENV"; then
    printf '\nWEBUI_GITHUB_REPO=%s\n' "$WEBUI_GITHUB_REPO" >> "$OPT_ENV"
  fi

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
  command -v curl >/dev/null || die "нужен curl"
  command -v jq >/dev/null || die "нужен jq"

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

  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  download_release "$tmp"
  install_from_archive "$tmp/$ASSET_NAME"

  if [[ "$NONINTERACTIVE" -eq 0 ]]; then
    smoke_test
  fi

  info "Готово. Скрипт на плате: ${SCRIPT_DST}"
}

main "$@"
