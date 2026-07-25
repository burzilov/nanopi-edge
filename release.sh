#!/bin/bash
# release.sh — patch-релиз: VERSION ↑, commit, tag, push.
#
#   ./release.sh           # 0.1.0 → 0.1.1, commit+tag+push
#   ./release.sh --dry-run # только показать следующую версию
#
# Требования: чистый working tree (кроме неотслеживаемых — их не трогаем),
# remote origin, право push. Первый коммит репозитория должен уже существовать.
#
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"

VERSION_FILE="$ROOT/VERSION"
DRY_RUN=0

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

usage() {
  cat <<EOF
Usage: $0 [--dry-run]

  Увеличивает patch в VERSION (X.Y.Z → X.Y.(Z+1)),
  создаёт commit «Release vX.Y.Z», annotated tag vX.Y.Z и пушит branch+tag.
EOF
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage ;;
    *) die "unknown arg: $arg (see --help)" ;;
  esac
done

command -v git >/dev/null || die "нужен git"
[[ -d "$ROOT/.git" ]] || die "не git-репозиторий: $ROOT"

# Должен быть хотя бы один коммит
git rev-parse HEAD >/dev/null 2>&1 || die "нет коммитов — сделай initial commit перед релизом"

# remote
git remote get-url origin >/dev/null 2>&1 || die "нет remote origin"

# чистый индекс и tracked files (untracked ок)
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  git status --short --untracked-files=no >&2
  die "working tree не чист (есть изменения в tracked-файлах). Закоммить или спрячь."
fi

current="0.0.0"
if [[ -f "$VERSION_FILE" ]]; then
  current=$(tr -d '[:space:]' < "$VERSION_FILE")
fi
[[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "некорректный VERSION: $current"

IFS=. read -r major minor patch <<<"$current"
next="${major}.${minor}.$((patch + 1))"
tag="v${next}"
msg="Release ${tag}"

info "Текущая: v${current} → следующая: ${tag} (patch++)"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "dry-run: не пишу VERSION, не коммичу, не пушу"
  exit 0
fi

# тег не должен существовать
if git rev-parse "$tag" >/dev/null 2>&1; then
  die "тег ${tag} уже есть"
fi

printf '%s\n' "$next" > "$VERSION_FILE"
git add "$VERSION_FILE"
git commit -m "$msg"

git tag -a "$tag" -m "$msg"

branch=$(git rev-parse --abbrev-ref HEAD)
info "Push branch «${branch}» и tag «${tag}»"
git push -u origin "HEAD:${branch}"
git push origin "$tag"

info "Готово: ${msg}"
echo "    GitHub Actions (webui-release) должен собрать артефакт для ${tag}"
