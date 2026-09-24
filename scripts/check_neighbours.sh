#!/usr/bin/env bash
# Re-verify the comparison table in README.md against the neighbours' own source.
#
# usage: check_neighbours.sh [--file TSV] [--local DIR] [--quiet]
#
#   --file TSV   claim table (default data/neighbours.tsv)
#   --local DIR  read PATH as DIR/PATH instead of fetching; the tests use this
#   --quiet      exit code only
#
# Output is one tab-separated line per claim:
#   ok|FAIL|unread <TAB> target <TAB> path <TAB> check <TAB> expected <TAB> actual <TAB> claim
# Exit 0 every claim holds, 1 a claim failed, 3 nothing failed but a file could
# not be read (offline, or the commit was garbage collected).
#
# The files are downloaded and read as text. Nothing in them is executed: this
# is grep over someone else's repository, and their repository is data.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
TSV="$ROOT/data/neighbours.tsv"
LOCAL=""
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --file)  TSV=${2:-}; shift 2 ;;
    --local) LOCAL=${2:-}; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -f "$TSV" ] || { echo "no claim table: $TSV" >&2; exit 2; }

CACHE=${CONTRIB_POLICY_CACHE:-$ROOT/.cache}/neighbours
mkdir -p "$CACHE" || exit 2

# fetch TARGET PATH -> prints the local file name, or nothing when unread
fetch() {
  local target=$1 path=$2 owner_repo commit dest
  if [ -n "$LOCAL" ]; then
    [ -f "$LOCAL/$path" ] && printf '%s\n' "$LOCAL/$path"
    return
  fi
  owner_repo=${target%@*}
  commit=${target#*@}
  dest="$CACHE/$(printf '%s' "$target/$path" | tr '/@' '__')"
  if [ ! -s "$dest" ]; then
    curl -sS -fL --max-time 30 \
      -o "$dest" "https://raw.githubusercontent.com/$owner_repo/$commit/$path" \
      2>/dev/null || { rm -f "$dest"; return; }
  fi
  [ -s "$dest" ] && printf '%s\n' "$dest"
}

FAILED=0; UNREAD=0
while IFS=$'\t' read -r target path check expect pattern claim; do
  case "$target" in ''|'#'*|target) continue ;; esac
  file=$(fetch "$target" "$path")
  if [ -z "$file" ]; then
    UNREAD=$((UNREAD + 1))
    [ "$QUIET" = 1 ] || printf 'unread\t%s\t%s\t%s\t%s\t-\t%s\n' \
      "$target" "$path" "$check" "$expect" "$claim"
    continue
  fi
  # -a: a policy file with a NUL byte in it must still be counted, not called
  # "binary file matches" and dropped
  n=$(grep -acE -- "$pattern" "$file" || true)
  case "$check" in
    count)   want=$expect ;;
    present) want="1+" ;;
    absent)  want=0 ;;
    *)       want="?" ;;
  esac
  case "$check" in
    count)   good=$([ "$n" = "$expect" ] && echo 1 || echo 0) ;;
    present) good=$([ "$n" -ge 1 ] && echo 1 || echo 0) ;;
    absent)  good=$([ "$n" = 0 ] && echo 1 || echo 0) ;;
    *)       good=0 ;;
  esac
  if [ "$good" = 1 ]; then
    [ "$QUIET" = 1 ] || printf 'ok\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$target" "$path" "$check" "$want" "$n" "$claim"
  else
    FAILED=$((FAILED + 1))
    [ "$QUIET" = 1 ] || printf 'FAIL\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$target" "$path" "$check" "$want" "$n" "$claim"
  fi
done < "$TSV"

[ "$FAILED" -gt 0 ] && exit 1
[ "$UNREAD" -gt 0 ] && exit 3
exit 0
