#!/usr/bin/env bash
# Rebuild data/policies.json from the README table of
# melissawm/open-source-ai-contribution-policies (CC0-1.0).
#
# usage: data/build_policies.sh [README.md]
# Reads the file if given, otherwise fetches the current README from GitHub.
set -u
cd "$(dirname "$0")" || exit 1

SRC_REPO="melissawm/open-source-ai-contribution-policies"
SRC_URL="https://raw.githubusercontent.com/$SRC_REPO/main/README.md"
OUT=policies.json
tmp=$(mktemp)
trap 'rm -f "$tmp" "$tmp.tsv"' EXIT

if [ $# -ge 1 ]; then
  cp "$1" "$tmp" || exit 1
else
  curl -sfL --max-time 30 "$SRC_URL" -o "$tmp" || { echo "fetch failed: $SRC_URL" >&2; exit 1; }
fi

# Table rows live between "## Policies" and the next "## " heading and start
# with a markdown link. Columns: project | policy link | allowed | disclosure |
# copyright | human in the loop | notes.
awk '
  /^## Policies/ { on = 1; next }
  on && /^## / { on = 0 }
  on && /^\[/ { print }
' "$tmp" | sed 's/\r$//' > "$tmp.tsv"

total=$(wc -l < "$tmp.tsv")

# One JSON object per row; rows with fewer than 6 columns are reported and dropped.
awk -F'|' -v OFS='\t' '
  function link_text(s) { sub(/^\[/, "", s); sub(/\].*$/, "", s); return s }
  function link_url(s)  { if (s !~ /\]\(/) return ""; sub(/^[^(]*\(/, "", s); sub(/\).*$/, "", s); return s }
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  function norm(s) {
    s = trim(s)
    if (s == "-" || s == "" ) return ""
    return s
  }
  {
    if (NF < 6) { print "DROP\t" NR "\t" $0 > "/dev/stderr"; next }
    if (NF == 6 && $6 !~ /[A-Za-z?]/) { print "DROP\t" NR "\t" $0 > "/dev/stderr"; next }
    project = trim($1); policy = trim($2)
    url = link_url(project); purl = link_url(policy)
    gh = ""
    if (match(url, /github\.com\/[^\/ ]+\/[^\/ #?]+/))  gh = substr(url, RSTART + 11, RLENGTH - 11)
    else if (match(purl, /github\.com\/[^\/ ]+\/[^\/ #?]+/)) gh = substr(purl, RSTART + 11, RLENGTH - 11)
    sub(/\.git$/, "", gh); sub(/\/$/, "", gh); sub(/:$/, "", gh)
    note = (NF >= 7) ? trim($7) : ""
    print link_text(project), url, link_text(policy), purl, norm($3), norm($4), norm($5), norm($6), note, tolower(gh)
  }
' "$tmp.tsv" 2> "$tmp.drop" | jq -R -s --arg src "$SRC_REPO" --arg date "$(date -u +%Y-%m-%d)" '
  split("\n") | map(select(length > 0) | split("\t")) |
  map({
    project: .[0], url: .[1], policy_title: .[2], policy_url: .[3],
    allowed: .[4], disclosure: .[5], copyright: .[6], human_oversight: .[7],
    note: .[8], github: (if .[9] == "" then null else .[9] end)
  }) |
  { source: $src, license: "CC0-1.0", fetched: $date, count: length, policies: . }
' > "$OUT"

kept=$(jq .count "$OUT")
echo "rows: $total, kept: $kept, dropped: $((total - kept))"
if [ -s "$tmp.drop" ]; then
  echo "dropped rows:"; cat "$tmp.drop"
fi
rm -f "$tmp.drop"
