#!/usr/bin/env bash
# Run contrib-policy and aipr over the same repositories and print both verdicts.
#
# usage: compare_aipr.sh [options]
#
# options:
#   --repos FILE   repository table (default data/known10.tsv)
#   --aipr CMD     command that behaves like aipr; default is auto-detected
#   --src DIR      where the vendored aipr source lives (default tests/out/aipr-src)
#   --ref SHA      aipr commit to vendor                    (default $AIPR_REF below)
#   --no-fetch     never vendor aipr source; use only what is already on PATH
#   --tsv          tab separated instead of markdown
#   --parse        read one aipr --json document on stdin, print "verdict<TAB>autonomous_safe"
#
# aipr is resolved in this order: $CONTRIB_POLICY_AIPR, `aipr` on PATH,
# `gh aipr` (the extension), then the vendored source run with python3. aipr
# declares no dependencies outside the standard library, so the vendored path
# needs nothing installed. When none of the four works, the aipr columns read
# "n/a" and the reason is printed to stderr; the contrib-policy column is still
# produced, so the table is always complete on our side.
#
# aipr source is fetched as data and executed as the tool under comparison. It
# is not read for instructions, and the commit is pinned.
set -u

AIPR_REF=65a0f790a8c0c635034ebb2f8cc95332329ab56d   # 2026-09-18, aipr 0.2.2
AIPR_RAW=https://raw.githubusercontent.com/yunaremaia/aipr
AIPR_MODULES="__init__.py cli.py detector.py sarif.py"

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SCAN="$ROOT/scripts/policy_scan.sh"

REPOS="$ROOT/data/known10.tsv"
AIPR_CMD="${CONTRIB_POLICY_AIPR:-}"
SRC="$ROOT/tests/out/aipr-src"
NO_FETCH=0
FORMAT=md
PARSE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repos) REPOS="$2"; shift ;;
    --aipr)  AIPR_CMD="$2"; shift ;;
    --src)   SRC="$2"; shift ;;
    --ref)   AIPR_REF="$2"; shift ;;
    --no-fetch) NO_FETCH=1 ;;
    --tsv)   FORMAT=tsv ;;
    --md)    FORMAT=md ;;
    --parse) PARSE=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# ------------------------------------------------------------------ aipr json
# aipr --json prints one object per repository (an array only in batch mode).
# Anything else - a traceback, a rate-limit message - is reported as "error"
# rather than guessed at.
parse_aipr_json() { # stdin: aipr --json document; stdout: verdict<TAB>autonomous_safe
  local doc v s
  doc=$(cat)
  if ! printf '%s' "$doc" | jq -e 'type == "object" and has("verdict")' >/dev/null 2>&1; then
    printf 'error\t-\n'; return 1
  fi
  v=$(printf '%s' "$doc" | jq -r '.verdict')
  s=$(printf '%s' "$doc" | jq -r '.autonomous_safe | tostring')
  printf '%s\t%s\n' "$v" "$s"
}

if [ "$PARSE" = 1 ]; then parse_aipr_json; exit $?; fi

for t in curl jq bash; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing: $t" >&2; exit 2; }
done
[ -f "$REPOS" ] || { echo "no such repository table: $REPOS" >&2; exit 2; }

# ------------------------------------------------------------- aipr discovery
python_ok() { # aipr needs 3.10+
  command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null
}

vendor_aipr() { # download the pinned aipr source into $SRC/aipr
  local m dst="$SRC/aipr"
  mkdir -p "$dst" || return 1
  for m in $AIPR_MODULES; do
    [ -s "$dst/$m" ] && continue
    curl -sSL --max-time 30 -o "$dst/$m" "$AIPR_RAW/$AIPR_REF/src/aipr/$m" || return 1
    [ -s "$dst/$m" ] || return 1
  done
  return 0
}

AIPR_WHY=""
resolve_aipr() {
  [ -n "$AIPR_CMD" ] && { AIPR_WHY="given on the command line"; return 0; }
  if command -v aipr >/dev/null 2>&1; then
    AIPR_CMD="aipr"; AIPR_WHY="aipr on PATH"; return 0
  fi
  if command -v gh >/dev/null 2>&1 && gh extension list 2>/dev/null | grep -q 'yunaremaia/aipr'; then
    AIPR_CMD="gh aipr"; AIPR_WHY="gh extension"; return 0
  fi
  if ! python_ok; then AIPR_WHY="not installed and python3 >= 3.10 is missing"; return 1; fi
  if [ "$NO_FETCH" = 1 ]; then
    # already vendored by an earlier run is not the same as "fetch it now"
    [ -s "$SRC/aipr/cli.py" ] || { AIPR_WHY="not installed and --no-fetch was given"; return 1; }
  elif ! vendor_aipr; then
    AIPR_WHY="not installed and the source download failed"; return 1
  fi
  AIPR_CMD="python3 -c \"import sys; from aipr.cli import main; sys.exit(main())\""
  AIPR_WHY="vendored source at $AIPR_REF (no install: aipr has no dependencies)"
  return 0
}

HAVE_AIPR=0
resolve_aipr && HAVE_AIPR=1

# aipr talks to api.github.com itself; without a token it rate-limits after a
# few repositories. gh already holds one.
if [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
  GH_TOKEN=$(gh auth token 2>/dev/null) && [ -n "$GH_TOKEN" ] && export GH_TOKEN
fi
export AIPR_CACHE_DIR="${AIPR_CACHE_DIR:-$ROOT/tests/out/aipr-cache}"
export PYTHONPATH="$SRC${PYTHONPATH:+:$PYTHONPATH}"

run_aipr() { # run_aipr REPO -> "verdict<TAB>autonomous_safe<TAB>exit"
  local out rc parsed repo="$1"
  # The command is the user's own string and is meant to be parsed; the
  # repository name is data from a table and is passed as one quoted word.
  out=$(eval "$AIPR_CMD" --json '"$repo"' 2>/dev/null); rc=$?
  parsed=$(printf '%s' "$out" | parse_aipr_json)
  printf '%s\t%s\n' "$parsed" "$rc"
}

# ------------------------------------------------------------------- our scan
run_ours() { # run_ours REPO -> "verdict<TAB>exit"
  local v rc
  v=$(bash "$SCAN" --quiet --no-merges "$1" 2>/dev/null); rc=$?
  [ -n "$v" ] || v=ERROR
  printf '%s\t%s\n' "$v" "$rc"
}

# ------------------------------------------------------------------- the table
[ "$HAVE_AIPR" = 1 ] || echo "aipr: $AIPR_WHY - the aipr columns will read n/a" >&2

rows=""
while IFS=$'\t' read -r repo project want truth; do
  case "${repo:-}" in ''|'#'*) continue ;; esac
  case "$repo" in
    *:*)  # not on github.com: neither tool can reach it
      rows="$rows$project	$repo	$want	n/a	n/a	-	off github.com
"
      continue ;;
  esac
  IFS=$'\t' read -r ours ours_rc <<EOF
$(run_ours "$repo")
EOF
  if [ "$HAVE_AIPR" = 1 ]; then
    IFS=$'\t' read -r averdict asafe arc <<EOF
$(run_aipr "$repo")
EOF
  else
    averdict=n/a; asafe=-; arc=-
  fi
  rows="$rows$project	$repo	$want	$ours ($ours_rc)	$averdict ($arc)	$asafe	$truth
"
  printf '  %-14s %-30s ours %-12s aipr %s\n' "$project" "$repo" "$ours" "$averdict" >&2
done < "$REPOS"

hdr='project	repo	expected	contrib-policy (exit)	aipr (exit)	aipr autonomous_safe	ground truth'

if [ "$FORMAT" = tsv ]; then
  printf '%s\n' "$hdr"
  printf '%s' "$rows"
else
  printf '%s' "$hdr" | awk -F'\t' '{printf "|"; for (i=1;i<=NF;i++) printf " %s |", $i; printf "\n|"; for (i=1;i<=NF;i++) printf "---|"; printf "\n"}'
  printf '%s' "$rows" | awk -F'\t' 'NF { printf "|"; for (i=1;i<=NF;i++) printf " %s |", $i; printf "\n" }'
fi
