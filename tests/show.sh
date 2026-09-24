#!/usr/bin/env bash
# Print every sentence of a repository's policy files that names AI, with the
# class classify.awk gives it. Used to work on the pattern set; not a test.
#
# usage: bash tests/show.sh OWNER/REPO [OWNER/REPO ...]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
export CONTRIB_POLICY_CACHE="$HERE/out/cache"

for repo in "$@"; do
  echo "=== $repo"
  bash "$ROOT/scripts/policy_scan.sh" --no-merges --no-dataset --quiet "$repo" >/dev/null 2>&1
  d="$CONTRIB_POLICY_CACHE/$repo"
  for branch in "$d"/*; do
    [ -d "$branch" ] || continue
    for f in "$branch"/*; do
      [ -s "$f" ] || continue
      awk -v F="$(basename "$f")" -f "$ROOT/scripts/sentences.awk" "$f"
    done
  done | awk -f "$ROOT/scripts/classify.awk" | sed 's/^/  /'
done
