#!/usr/bin/env bash
# contrib-policy: read a repository's contribution rules before opening a pull request.
#
# usage: policy_scan.sh OWNER/REPO [options]                      (github.com)
#        policy_scan.sh HOST/GROUP/PROJECT [options]              (gitlab, codeberg/gitea)
#        policy_scan.sh https://HOST/GROUP/PROJECT/-/blob/... [options]
#        policy_scan.sh --file PATH [--file PATH ...] [options]   (local files only, no network)
#
# A first segment with a dot in it is read as a host name (github.com owners have
# none), so gitlab.gnome.org/World/gedit/gedit and codeberg.org/o/r work as they
# are written. Everything after the host is the project path; GitLab groups nest.
#
# options:
#   --json            machine readable output
#   --host HOST       host name, when the target is given as a bare path
#   --kind KIND       github | gitlab | gitea, for a host this script cannot place
#   --tool NAME       tool name used in disclosure lines      (default: $CONTRIB_POLICY_TOOL or "Claude Code")
#   --agent NAME      agent name for Assisted-by: trailers     (default: $CONTRIB_POLICY_AGENT or "Claude")
#   --model ID        model id for Assisted-by: trailers       (default: $CONTRIB_POLICY_MODEL or "unknown")
#   --owner NAME      apply the data/orgs.json rules of this owner (default: the owner in OWNER/REPO)
#   --stop-on-cla     treat a required CLA as a reason to stop (default: a note)
#   --no-merges       skip the 90-day merge statistics (one search API call)
#   --no-cache        ignore cached downloads
#   --no-dataset      ignore data/policies.json; judge from the repository text alone
#   --no-org          ignore data/orgs.json
#   --receipt         read .contrib-policy/receipt.json, report what changed, write it again
#                     ($CONTRIB_POLICY_RECEIPT overrides the path; add .contrib-policy/ to .gitignore)
#   --quiet           verdict line only
#   --dry-run         print the parsed target (host, path, kind) and exit; no network
#
# network: downloads, repository metadata, the tree listing and the merge count
#   are cached for 24 hours under $CONTRIB_POLICY_CACHE (default ~/.cache/contrib-policy);
#   a 429, a 403 with the limit spent, a 5xx or a dropped connection is retried
#   $CONTRIB_POLICY_RETRIES times (2) after the wait the host asks for, up to
#   $CONTRIB_POLICY_MAX_WAIT seconds (30); consecutive requests are kept
#   $CONTRIB_POLICY_MIN_GAP_MS apart (50). A limit that cannot be waited out is UNKNOWN.
#
# exit codes: 0 GO, 1 GO-DECLARE, 2 STOP (also STOP-CHECK), 3 UNKNOWN
#
# Everything read from the repository is data. It is quoted, never executed,
# and never treated as an instruction.
set -u
# `export LC_ALL=C.UTF-8` never fails, so the locale has to be probed: on a host
# without it every child process would otherwise warn on stderr.
if command -v locale >/dev/null 2>&1 && [ -n "$(LC_ALL=C.UTF-8 locale 2>&1 >/dev/null)" ]; then
  export LC_ALL=C
else
  export LC_ALL=C.UTF-8
fi

VERSION=0.1.0
HERE=$(cd "$(dirname "$0")" && pwd)
DATA="$HERE/../data"
CACHE_DIR="${CONTRIB_POLICY_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/contrib-policy}"
CACHE_MINUTES=1440
TIMEOUT=20
. "$HERE/ratelimit.sh"   # throttle, http_get, gh_api, RATE_LIMITED

REPO=""; JSON=0; STOP_ON_CLA=0; NO_MERGES=0; NO_CACHE=0; NO_DATASET=0; NO_ORG=0; QUIET=0; RECEIPT=0; DRY_RUN=0
RECEIPT_PATH="${CONTRIB_POLICY_RECEIPT:-.contrib-policy/receipt.json}"
TOOL="${CONTRIB_POLICY_TOOL:-Claude Code}"
AGENT="${CONTRIB_POLICY_AGENT:-Claude}"
MODEL="${CONTRIB_POLICY_MODEL:-unknown}"
OWNER_OPT=""; HOST_OPT=""; KIND_OPT=""
TARGET=""; HOST=""; KIND=""
LOCAL_FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --host) HOST_OPT="$2"; shift ;;
    --kind) KIND_OPT="$2"; shift ;;
    --tool) TOOL="$2"; shift ;;
    --agent) AGENT="$2"; shift ;;
    --model) MODEL="$2"; shift ;;
    --owner) OWNER_OPT="$2"; shift ;;
    --stop-on-cla) STOP_ON_CLA=1 ;;
    --no-merges) NO_MERGES=1 ;;
    --no-cache) NO_CACHE=1 ;;
    --no-dataset) NO_DATASET=1 ;;
    --no-org) NO_ORG=1 ;;
    --receipt) RECEIPT=1 ;;
    --quiet) QUIET=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --file) LOCAL_FILES+=("$2"); shift ;;
    -h|--help) sed -n '2,41p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 3 ;;
    *) TARGET="$1" ;;
  esac
  shift
done

if [ -z "$TARGET" ] && [ ${#LOCAL_FILES[@]} -eq 0 ]; then
  echo "usage: policy_scan.sh OWNER/REPO | HOST/GROUP/PROJECT [--json] | --file PATH" >&2; exit 3
fi
if [ -n "$OWNER_OPT" ] && ! printf '%s' "$OWNER_OPT" | grep -Eq '^[A-Za-z0-9_.-]+$'; then
  echo "not an owner name: $OWNER_OPT" >&2; exit 3
fi

# ---------------------------------------------------------------- target
# A target is HOST + project path. The host decides which API answers, not which
# rules apply: the classifier, the injection scan and the verdict are the same
# everywhere, which is the point of reading more than one forge - the outright
# bans are concentrated on GNOME's GitLab and on Codeberg.
if [ -n "$TARGET" ]; then
  t=${TARGET#https://}; t=${t#http://}
  t=${t%/}; t=${t%.git}
  t=${t%%/-/*}                                        # gitlab web url: /-/blob/...
  case "$t" in */src/branch/*) t=${t%%/src/branch/*} ;; esac   # gitea web url
  t=${t%%/blob/*}; t=${t%%/tree/*}                    # github web url
  if [ -n "$HOST_OPT" ]; then
    HOST="$HOST_OPT"; REPO="$t"
  else
    case "${t%%/*}" in
      # A github.com owner name is alphanumeric with hyphens and never holds a
      # dot, so a dotted first segment is a host name and nothing else.
      *.*) HOST="${t%%/*}"; REPO="${t#*/}" ;;
      *)   HOST=github.com; REPO="$t" ;;
    esac
  fi
  if [ -n "$KIND_OPT" ]; then KIND="$KIND_OPT"
  else
    case "$HOST" in
      github.com)                                   KIND=github ;;
      codeberg.org|*gitea*|*forgejo*)               KIND=gitea ;;
      # the named instances are GitLab under another domain; git.kernel.org and
      # sr.ht are not in this list because they run neither of the two APIs.
      gitlab.com|gitlab.*|*.gitlab.*|salsa.debian.org|invent.kde.org|framagit.org) KIND=gitlab ;;
      *) echo "unknown forge software on $HOST: pass --kind github|gitlab|gitea" >&2; exit 3 ;;
    esac
  fi
  case "$KIND" in
    github|gitlab|gitea) ;;
    *) echo "not a kind: $KIND (github, gitlab, gitea)" >&2; exit 3 ;;
  esac
  if ! printf '%s' "$HOST" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$'; then
    echo "not a host name: $HOST" >&2; exit 3
  fi
  # GitLab groups nest, so the path is two segments or more there; github.com and
  # gitea take exactly owner/repo.
  # The path is also a directory under the cache, so "." and ".." segments are
  # refused here rather than resolved there.
  if ! printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+$' \
     || printf '%s' "$REPO" | grep -Eq '(^|/)\.\.?(/|$)'; then
    echo "not a project path: $REPO" >&2; exit 3
  fi
  if [ "$KIND" != gitlab ] && printf '%s' "$REPO" | grep -Fq '/' && [ "$(printf '%s' "$REPO" | tr -cd '/' | wc -c)" -ne 1 ]; then
    echo "not an OWNER/REPO for $HOST: $REPO" >&2; exit 3
  fi
fi

if [ "$DRY_RUN" = 1 ]; then
  printf '%s\t%s\t%s\n' "${HOST:-local}" "${REPO:-local files}" "${KIND:-local}"
  exit 0
fi

for t in curl jq awk sha256sum od; do command -v "$t" >/dev/null || { echo "missing: $t" >&2; exit 3; }; done
[ "$KIND" = github ] && ! command -v gh >/dev/null && { echo "missing: gh" >&2; exit 3; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/files"
: > "$WORK/units"      # FILE:LINE<TAB>sentence
: > "$WORK/hits"       # CLASS<TAB>FILE:LINE<TAB>sentence
: > "$WORK/injection"  # KIND<TAB>SEVERITY<TAB>FILE:LINE<TAB>quote
: > "$WORK/hashes"     # path<TAB>sha256
: > "$WORK/reasons"
: > "$WORK/notes"
: > "$WORK/fetch_errors"
FETCH_ERRORS=0

# ---------------------------------------------------------------- helpers
note()   { printf '%s\n' "$1" >> "$WORK/notes"; }
reason() { printf '%s\n' "$1" >> "$WORK/reasons"; }

urlenc() { printf '%s' "$1" | jq -sRr @uri; }   # jq, so a path with a slash or a space is encoded once and correctly

# The http code of the last api_json call is kept in a file, because api_json
# is called inside $(...) and a variable set there never reaches the caller.
api_code() { cat "$WORK/api.code" 2>/dev/null; }
api_json() { # api_json URL -> body on stdout; empty and non-zero unless the host answered 200
  local url="$1" out="$WORK/api.json" code
  code=$(http_get "$url" "$out" application/json)
  printf '%s' "$code" > "$WORK/api.code"
  [ "$code" = 200 ] || return 1
  jq -e . "$out" >/dev/null 2>&1 || { printf 'not json' > "$WORK/api.code"; return 1; }
  cat "$out"
}

# Answers that are not files - repository metadata, the tree listing, the merge
# count - are cached next to the files, for the same 24 hours: a scan repeated
# within a day (a test run, a retry after a limit, a second pull request to the
# same project) then makes no request at all. Only a complete answer is kept.
cache_get() { # cache_get NAME -> the cached body, non-zero when there is none or it is stale
  local f="$CACHE_DIR/$HOST/$REPO/$1"
  [ "$NO_CACHE" = 0 ] && [ -s "$f" ] && [ -n "$(find "$f" -mmin -"$CACHE_MINUTES" 2>/dev/null)" ] && cat "$f"
}
cache_put() { # cache_put NAME < body
  local f="$CACHE_DIR/$HOST/$REPO/$1"
  mkdir -p "$(dirname "$f")" && cat > "$f.tmp" && mv -f "$f.tmp" "$f"
}
# The default branch is remote data that ends up in a URL and in a cache path:
# git itself refuses ".." and control characters in a ref, so a name outside
# this shape is not a branch and HEAD is read instead.
branch_ok() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$' && ! printf '%s' "$1" | grep -Eq '(^|/)\.\.(/|$)'; }
rate_limited_exit() { # the host said no and the wait is longer than MAX_WAIT: not a verdict
  echo "rate limited by $RATE_LIMITED${RATE_LIMITED_WAIT:+; it asks for a wait of $RATE_LIMITED_WAIT s (CONTRIB_POLICY_MAX_WAIT=$MAX_WAIT)}; rerun later" >&2
  exit 3
}
# Repository metadata, once per forge: from the cache, or from CMD (which has to
# print one json object), and only a complete object is cached. Non-zero when
# the caller has to say what went wrong; a rate limit is reported here.
read_meta() { # read_meta CMD... -> META
  META=$(cache_get _meta.json) && return 0
  if META=$("$@") && printf '%s' "$META" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '%s' "$META" | cache_put _meta.json; return 0
  fi
  rl_load; [ -n "$RATE_LIMITED" ] && rate_limited_exit
  return 1
}

# One file, by whichever route the host offers. GitLab and Gitea answer 404 with
# a JSON body, which the http code catches before the body is ever read.
raw_url() { # raw_url PATH
  case "$KIND" in
    github) printf 'https://raw.githubusercontent.com/%s/%s/%s' "$REPO" "$DEFAULT_BRANCH" "$1" ;;
    gitlab) printf 'https://%s/api/v4/projects/%s/repository/files/%s/raw?ref=%s' \
                   "$HOST" "$(urlenc "$REPO")" "$(urlenc "$1")" "$(urlenc "$DEFAULT_BRANCH")" ;;
    gitea)  printf 'https://%s/api/v1/repos/%s/raw/%s?ref=%s' \
                   "$HOST" "$REPO" "$1" "$(urlenc "$DEFAULT_BRANCH")" ;;
  esac
}

fetch_raw() { # fetch_raw PATH -> writes $WORK/files/<flat>; echo local path on success
  local path="$1" flat out url code
  flat=$(printf '%s' "$path" | tr '/' '_')
  out="$WORK/files/$flat"
  url=$(raw_url "$path")
  # The cache name carries a hash of the exact path: on a case-insensitive
  # filesystem (a Windows mount, macOS) README.md and readme.md are one file,
  # and the empty entry left by a 404 on the first would answer for the second.
  local cached="$CACHE_DIR/$HOST/$REPO/$BRANCH_DIR/$flat.$(printf '%s' "$path" | sha256sum | cut -c1-8)"
  if [ "$NO_CACHE" = 0 ] && [ -f "$cached" ] && [ -n "$(find "$cached" -mmin -"$CACHE_MINUTES" 2>/dev/null)" ]; then
    if [ -s "$cached" ]; then cp "$cached" "$out"; echo "$out"; fi
    return 0
  fi
  # Once this host has refused for longer than the wait allows, or stopped
  # answering, the remaining files are not asked for: each would be one more
  # refusal. The note was written when it happened; here the file is only counted.
  local h; h=$(url_host "$url")
  if rl_blocked "$h"; then rm -f "$out"; echo "$path" >> "$WORK/fetch_errors"; return 0; fi
  code=$(http_get "$url" "$out")
  case "$code" in
    200) mkdir -p "$(dirname "$cached")"; cp "$out" "$cached"; echo "$out" ;;
    404) rm -f "$out"; mkdir -p "$(dirname "$cached")"; : > "$cached" ;;
    *)   rm -f "$out"; echo "$path" >> "$WORK/fetch_errors"
         rl_load "$h"
         if [ -n "$RATE_LIMITED" ]; then note "rate limited by $h at $path${RATE_LIMITED_WAIT:+ (it asks for $RATE_LIMITED_WAIT s)}; the remaining files were not requested"
         elif [ -n "$HOST_DOWN" ]; then note "no answer from $h at $path; the remaining files were not requested"
         else note "fetch failed ($code): $path"; fi ;;
  esac
}

add_file() { # add_file LOCALPATH LABEL [section]
  local local="$1" label="$2" section="${3:-}" src="$1"
  [ -f "$local" ] || return 0
  printf '%s\t%s\n' "$label" "$(sha256sum "$local" | cut -c1-64)" >> "$WORK/hashes"
  if [ "$section" = "contributing" ]; then
    # README: the sections about contributing and about AI. Several projects
    # (CapyPDF, LOVE) keep the only AI rule in a README heading of its own.
    # Both passes print one line per input line - blanked out when dropped - so
    # the line number in a quote is the line number in the file on GitHub.
    #
    # Pass 1 rewrites setext headings ("Contributing" over a row of dashes,
    # Decker's README) as ATX, keeping the line count.
    awk '{ if (have) {
             if ($0 ~ /^(=+|--+)[ \t]*$/ && buf ~ /[^ \t]/) {
               print ($0 ~ /^=/ ? "# " : "## ") buf; print ""; have=0; next }
             print buf }
           buf=$0; have=1 }
         END { if (have) print buf }' "$local" \
    | awk 'BEGIN{on=0;lvl=0}
      /^#+[ \t]/ { h=$0; sub(/[ \t].*/,"",h); n=length(h); t=tolower($0)
        if (t ~ /contribut/ || t ~ /artificial intelligence|generative|large language|machine learning/ \
            || t ~ /(^|[^a-z0-9])(ai|a\.i\.|llms?|bots?|agents?)([^a-z0-9]|$)/) {on=1; lvl=n; print; next}
        if (on && n<=lvl) {on=0} }
      { if (on) print; else print "" }' > "$local.section"
    src="$local.section"
  fi
  awk -v F="$label" -f "$HERE/sentences.awk" "$src" >> "$WORK/units"
  scan_injection "$local" "$label"
}

# Two severities, because a CONTRIBUTING.md that documents an install command is
# not an attack and must not stop the contributor:
#   suspicious - text written at the agent, or text hidden from the reader.
#                A human reads it before anything else happens (STOP-CHECK).
#   notice     - a shell pipeline or an opaque blob in a document. Printed only.
INJ_SUSPICIOUS='ignore (all |the |any |your )?(previous|prior|above|earlier|system) (instructions?|prompts?|rules?|guidance)|disregard (the |all |your |any )?(previous|prior|system|above|earlier)|you are now (a|an|in)|as an ai( language)? model|new instructions?:|(system|initial) prompt:|do not (tell|show|mention|reveal|report|log) (this |it |anything )?(to )?(the )?(user|human|operator|maintainer)|<\|im_start\|>|<\|im_end\|>|\[/?inst\]'
# Text addressed at the agent is normal in a contribution policy: Polars asks an
# agent to say so in the pull request, Processing puts a notice at the top of
# AGENTS.md. It is only a finding when the same line also tells the agent to do
# something - run, install, fetch, hide. Both halves have to be there.
INJ_ADDRESS='(dear|hey|attention|note to|instructions? for) (the )?(agent|assistant|ai|claude|copilot|llm|model)|if you(.re| are)? an? (ai|llm|agent|assistant|language model|coding)|(ai|llm|coding) (agents?|assistants?)[ ]*[:,]'
INJ_ACT='ignore|disregard|run |execute|install|download|fetch|curl |wget |send |e-?mail|upload|add this|append|modify|overwrite|delete|push |force-push|approve|merge|skip|bypass|disable|do not (tell|show|mention|reveal)|secret|token|credential|password|\.env'
INJ_NOTICE='run the following (command|script)|execute the following|before (contributing|starting|you begin),? (run|execute|install|download)|curl [^|]*\| *(ba|z)?sh|wget [^|]*\| *(ba|z)?sh|install this hook|add this to your (settings|config|configuration|hooks|claude|mcp)'

# Turn `grep -n` output into a finding row. Splitting on the first colon only:
# with awk -F: the rebuilt record would replace every other colon with a space
# and a quoted URL would come out as "https //example.com".
INJ_AWK='{ if (match($0, /^[0-9]+:/)) { ln = substr($0, 1, RLENGTH-1); t = substr($0, RLENGTH+1) }
           else { ln = "-"; t = $0 }
           gsub(/\t/, " ", t); printf "%s\t%s\t%s:%s\t%s\n", K, S, L, ln, t }'

scan_injection() { # scan_injection LOCALPATH LABEL
  local f="$1" label="$2"
  # -a everywhere: one NUL byte makes GNU grep answer "binary file matches" and
  # the finding, quote and line number are lost. Hiding text behind a NUL is
  # exactly what this scan is looking for.
  grep -aniE "$INJ_SUSPICIOUS" "$f" 2>/dev/null \
    | cut -c1-200 | awk -v L="$label" -v K=instruction -v S=suspicious "$INJ_AWK" >> "$WORK/injection"
  grep -aniE "$INJ_ADDRESS" "$f" 2>/dev/null | grep -aiE "$INJ_ACT" \
    | cut -c1-200 | awk -v L="$label" -v K=instruction -v S=suspicious "$INJ_AWK" >> "$WORK/injection"
  grep -aniE "$INJ_NOTICE" "$f" 2>/dev/null \
    | cut -c1-200 | awk -v L="$label" -v K=command -v S=notice "$INJ_AWK" >> "$WORK/injection"
  # html comments: hidden from the rendered page, so the same text weighs more.
  # The filter is the suspicious set, not a bag of words - "SPDX-License-Identifier:
  # curl" and "<!-- codespell:ignore -->" are comments, not attacks.
  local comments="$WORK/comments"
  tr '\n' ' ' < "$f" | grep -aoE '<!--([^-]|-[^-])*-->' 2>/dev/null | cut -c1-200 > "$comments"
  grep -aiE "$INJ_SUSPICIOUS" "$comments" 2>/dev/null \
    | awk -v L="$label" -v K=html-comment -v S=suspicious "$INJ_AWK" >> "$WORK/injection"
  grep -aiE "$INJ_ADDRESS" "$comments" 2>/dev/null | grep -aiE "$INJ_ACT" \
    | awk -v L="$label" -v K=html-comment -v S=suspicious "$INJ_AWK" >> "$WORK/injection"
  grep -aiE "$INJ_NOTICE" "$comments" 2>/dev/null \
    | awk -v L="$label" -v K=html-comment -v S=notice "$INJ_AWK" >> "$WORK/injection"
  # Zero width and bidi characters (utf-8 byte sequences; a BOM at offset 0 is
  # ignored). U+200C ZWNJ and U+200D ZWJ are left out on purpose: they are how
  # emoji sequences and Persian, Arabic and Indic text are written, and an
  # all-contributors table (Processing) is full of them. U+E0000-U+E007F, the
  # tag block, is the block that carries genuinely invisible smuggled text.
  local zw skip=1
  [ "$(od -An -N3 -tx1 < "$f" | tr -d ' \n')" = "efbbbf" ] && skip=4
  zw=$(tail -c "+$skip" "$f" | LC_ALL=C grep -acE $'\xE2\x80[\x8B\x8E\x8F]|\xE2\x81\xA0|\xEF\xBB\xBF|\xE2\x80[\xAA-\xAE]|\xE2\x81[\xA6-\xA9]|\xF3\xA0[\x80\x81][\x80-\xBF]' 2>/dev/null | tr -d ' ')
  [ "${zw:-0}" -gt 0 ] && printf 'hidden-unicode\tsuspicious\t%s:-\t%s line(s) with zero-width or bidi control characters\n' "$label" "$zw" >> "$WORK/injection"
  # hidden text in html. A <details> block is not in this set: it collapses the
  # text on github.com but leaves it in the file, so the plain-text passes above
  # already read every line of it. Escalating a collapsed setup command would
  # only cost false positives - half the READMEs on github.com put the long
  # install instructions in one.
  grep -aniE 'font-size: ?0|color: ?(white|#fff(fff)?)|display: ?none|visibility: ?hidden|opacity: ?0([^.0-9]|$)' "$f" 2>/dev/null \
    | cut -c1-200 | awk -v L="$label" -v K=hidden-html -v S=suspicious "$INJ_AWK" >> "$WORK/injection"
  # encoded blobs (data: uris, e.g. badges, are stripped first)
  sed -E 's/data:[^ )"'"'"']*//g' "$f" | grep -anE '[A-Za-z0-9+/]{120,}={0,2}|(0x)?[0-9a-fA-F]{96,}' 2>/dev/null \
    | cut -c1-120 | awk -v L="$label" -v K=encoded-blob -v S=notice "$INJ_AWK" >> "$WORK/injection"
}

# ---------------------------------------------------------------- repository metadata
VERDICT=""; DEFAULT_BRANCH=""; BRANCH_DIR=""; ARCHIVED=null; HAS_PRS=null; PR_POLICY=null
ORG_ID=""; ORG_STANCE=""; ORG_JSON=""; ORG_NAME=""; ORG_RULE=""; ORG_URL=""; ORG_LINE=""; ORG_APPLIED=false
MERGES_TOTAL=null; MERGES_EXT=null; MERGES_SAMPLE=null
OWNER_LC=""
# data/orgs.json keys on github.com owner names, so a group of the same name on
# another host is not the same body: World/gedit on gitlab.gnome.org is not the
# github.com "world" owner, and a self-hosted group called "apache" is not the
# ASF. On another host the owner has to be named with --owner.
[ "$KIND" = github ] && OWNER_LC=$(printf '%s' "${REPO%%/*}" | tr 'A-Z' 'a-z')
# --owner is what makes this testable without the network, and it is also the way
# to ask "what would the foundation say" for a repository that is not on GitHub.
[ -n "$OWNER_OPT" ] && OWNER_LC=$(printf '%s' "$OWNER_OPT" | tr 'A-Z' 'a-z')

# Organisation or foundation level rules, read before any repository file: they
# apply only where the repository itself says nothing, but the CLA and DCO facts
# in them hold either way.
if [ "$NO_ORG" = 0 ] && [ -n "$OWNER_LC" ]; then
  ORG_JSON=$(jq -c --arg o "$OWNER_LC" '.orgs[] | select(.owners | map(ascii_downcase) | index($o))' "$DATA/orgs.json" 2>/dev/null | head -1)
  if [ -n "$ORG_JSON" ]; then
    ORG_ID=$(printf '%s' "$ORG_JSON" | jq -r '.id')
    ORG_NAME=$(printf '%s' "$ORG_JSON" | jq -r '.name')
    ORG_STANCE=$(printf '%s' "$ORG_JSON" | jq -r '.stance')
    ORG_RULE=$(printf '%s' "$ORG_JSON" | jq -r '.rule // ""')
    ORG_URL=$(printf '%s' "$ORG_JSON" | jq -r '.policy_url // ""')
    # jq does the placeholder substitution, not sed: a tool name with a slash or
    # an ampersand in it would rewrite a sed expression.
    ORG_LINE=$(printf '%s' "$ORG_JSON" | jq -r --arg tool "$TOOL" --arg agent "$AGENT" --arg model "$MODEL" \
      '(.disclosure_line // "") | gsub("\\{tool\\}"; $tool) | gsub("\\{agent\\}"; $agent) | gsub("\\{model\\}"; $model)')
  fi
fi
if [ -n "$REPO" ]; then
  case "$KIND" in
    github)
      read_meta gh_api "repos/$REPO" || {
        if grep -qiE 'not found|404' "$WORK/gh.err"; then echo "repository not found: $REPO" >&2; else echo "gh api failed: $(head -c 200 "$WORK/gh.err")" >&2; fi
        exit 3
      }
      DEFAULT_BRANCH=$(printf '%s' "$META" | jq -r '.default_branch // "main"')
      ARCHIVED=$(printf '%s' "$META" | jq '.archived')
      HAS_PRS=$(printf '%s' "$META" | jq '.has_pull_requests // true')
      PR_POLICY=$(printf '%s' "$META" | jq '.pull_request_creation_policy // null')
      ;;
    gitlab)
      read_meta api_json "https://$HOST/api/v4/projects/$(urlenc "$REPO")" || {
        if [ "$(api_code)" = 404 ]; then echo "project not found: $HOST/$REPO" >&2
        else echo "gitlab api failed ($(api_code)): $HOST/$REPO" >&2; fi
        exit 3
      }
      DEFAULT_BRANCH=$(printf '%s' "$META" | jq -r '.default_branch // "main"')
      ARCHIVED=$(printf '%s' "$META" | jq '.archived // false')
      # merge_requests_access_level is the GitLab field for "who may open one":
      # disabled closes merge requests, private keeps them inside the project.
      MR_LEVEL=$(printf '%s' "$META" | jq -r '.merge_requests_access_level // ""')
      case "$MR_LEVEL" in
        disabled|private) HAS_PRS=false; reason "merge_requests_access_level is $MR_LEVEL: an outside contributor cannot open a merge request here" ;;
        "") HAS_PRS=$(printf '%s' "$META" | jq '.merge_requests_enabled // true') ;;
        *)  HAS_PRS=true ;;
      esac
      # There is no pull_request_creation_policy on GitLab; the field stays null
      # rather than being invented, and the openness line says so.
      ;;
    gitea)
      read_meta api_json "https://$HOST/api/v1/repos/$REPO" || {
        if [ "$(api_code)" = 404 ]; then echo "repository not found: $HOST/$REPO" >&2
        else echo "gitea api failed ($(api_code)): $HOST/$REPO" >&2; fi
        exit 3
      }
      DEFAULT_BRANCH=$(printf '%s' "$META" | jq -r '.default_branch // "main"')
      ARCHIVED=$(printf '%s' "$META" | jq '.archived // false')
      HAS_PRS=$(printf '%s' "$META" | jq '.has_pull_requests // true')
      [ "$(printf '%s' "$META" | jq -r '.mirror // false')" = true ] && note "this is a mirror of another repository; the pull request may have to go to the original"
      ;;
  esac
  if ! branch_ok "$DEFAULT_BRANCH"; then
    note "the default branch name is not usable in a path ($(printf '%s' "$DEFAULT_BRANCH" | cut -c1-40 | tr -cd 'A-Za-z0-9._/-')); reading HEAD"
    DEFAULT_BRANCH=HEAD
  fi
  BRANCH_DIR=$(printf '%s' "$DEFAULT_BRANCH" | tr '/' '_')
  [ "$ARCHIVED" = true ] && reason "repository is archived"
  [ "$HAS_PRS" = false ] && reason "pull requests are disabled on this repository"
  [ "$PR_POLICY" = '"collaborators_only"' ] && reason "pull_request_creation_policy is collaborators_only: outside contributors cannot open pull requests"
  if [ -s "$WORK/reasons" ]; then VERDICT=STOP; fi

  # The fixed list below misses the file names projects actually pick:
  # cilium and TorchGeo write AI-POLICY.md with a hyphen, curl keeps the rules in
  # docs/CONTRIBUTE.md, QGIS in qep-408-ai-tool-policy.md. One tree listing finds
  # them. A truncated tree (very large repository) falls back to the fixed list.
  DISCOVERED=""
  if [ "$VERDICT" != STOP ]; then
    : > "$WORK/tree"
    # The listing is the largest answer a scan asks for (megabytes on a big
    # repository), so the filtered path list is what gets cached.
    if ! cache_get "$BRANCH_DIR/_tree.txt" > "$WORK/tree"; then
      case "$KIND" in
        github)
          TREE=$(gh_api "repos/$REPO/git/trees/$DEFAULT_BRANCH?recursive=1") || TREE=""
          if [ -n "$TREE" ] && [ "$(printf '%s' "$TREE" | jq -r '.truncated // false')" != true ]; then
            printf '%s' "$TREE" | jq -r '(.tree // [])[] | select(.type == "blob" and (.size // 0) < 200000) | .path' > "$WORK/tree"
          fi ;;
        gitlab)
          # One page of 100 is enough for the files this looks for: they sit at the
          # top of the tree and the filter below keeps only three levels anyway.
          TREE=$(api_json "https://$HOST/api/v4/projects/$(urlenc "$REPO")/repository/tree?ref=$(urlenc "$DEFAULT_BRANCH")&recursive=true&per_page=100") || TREE=""
          [ -n "$TREE" ] && printf '%s' "$TREE" | jq -r '.[]? | select(.type == "blob") | .path' > "$WORK/tree" ;;
        gitea)
          TREE=$(api_json "https://$HOST/api/v1/repos/$REPO/git/trees/$(urlenc "$DEFAULT_BRANCH")?recursive=true&per_page=1000") || TREE=""
          if [ -n "$TREE" ] && [ "$(printf '%s' "$TREE" | jq -r '.truncated // false')" != true ]; then
            printf '%s' "$TREE" | jq -r '(.tree // [])[] | select(.type == "blob" and (.size // 0) < 200000) | .path' > "$WORK/tree"
          fi ;;
      esac
      [ -s "$WORK/tree" ] && cache_put "$BRANCH_DIR/_tree.txt" < "$WORK/tree"
      if [ ! -s "$WORK/tree" ] && rl_load; then
        note "the tree listing could not be read (${RATE_LIMITED:+rate limited by $RATE_LIMITED}${HOST_DOWN:+no answer from $HOST_DOWN}); files are looked for under their usual names only"
      fi
    fi
    # A tree listing is remote data and goes into a URL, so anything that is not
    # a plain path is dropped before it is used. Three levels deep: gedit keeps
    # its rule in docs/guidelines/no-llm-tools.md.
    DISCOVERED=$(grep -E '^[A-Za-z0-9][A-Za-z0-9._/-]*$' "$WORK/tree" \
      | awk -F/ 'NF <= 3' \
      | grep -iE '(^|/)[^/]*(contribut|governance|covenant|ai[-_. ]?(policy|polic|tool|use|usage|rule|guidance|guideline)|(no|use)[-_. ]?(of[-_. ]?)?(ai|llm|llms)[-_. ]|(policy|policies|guideline|guidelines|rules)[^/]*(ai|llm|generative)|agents|claude|copilot-instructions)[^/]*(\.(md|rst|txt|markdown))?$' \
      | grep -ivE '\.(png|jpg|jpeg|svg|gif|py|js|jsx|ts|tsx|rs|go|c|h|cc|cpp|lua|java|zig|rb|php|json|yaml|yml|lock|toml|cfg|ini|html|css)$' \
      | head -n 12)
  fi

  if [ "$VERDICT" != STOP ]; then
    for p in CONTRIBUTING.md .github/CONTRIBUTING.md docs/CONTRIBUTING.md CONTRIBUTING.rst CONTRIBUTING.txt CONTRIBUTING \
             AI_POLICY.md .github/AI_POLICY.md AI.md .github/AI.md docs/ai-policy.md \
             .github/PULL_REQUEST_TEMPLATE.md .github/pull_request_template.md PULL_REQUEST_TEMPLATE.md docs/PULL_REQUEST_TEMPLATE.md \
             AGENTS.md CLAUDE.md .github/copilot-instructions.md .cursorrules \
             CODE_OF_CONDUCT.md .github/CODE_OF_CONDUCT.md \
             CLA.md .github/CLA.md .clabot .github/cla.yml .github/workflows/cla.yml .github/workflows/dco.yml; do
      lf=$(fetch_raw "$p"); [ -n "$lf" ] && add_file "$lf" "$p"
    done
    # The same documents under the names the other forges use. GIMP's only AI
    # rule is in .gitlab/merge_request_templates/default.md.
    if [ "$KIND" = gitlab ]; then
      for p in .gitlab/merge_request_templates/default.md .gitlab/merge_request_templates/Default.md \
               .gitlab/CONTRIBUTING.md .gitlab/issue_templates/Default.md; do
        lf=$(fetch_raw "$p"); [ -n "$lf" ] && add_file "$lf" "$p"
      done
    elif [ "$KIND" = gitea ]; then
      for p in .gitea/PULL_REQUEST_TEMPLATE.md .gitea/pull_request_template.md .gitea/CONTRIBUTING.md \
               .forgejo/PULL_REQUEST_TEMPLATE.md .forgejo/CONTRIBUTING.md; do
        lf=$(fetch_raw "$p"); [ -n "$lf" ] && add_file "$lf" "$p"
      done
    fi
    if [ -n "$DISCOVERED" ]; then
      printf '%s\n' "$DISCOVERED" > "$WORK/discovered"
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        [ -f "$WORK/files/$(printf '%s' "$p" | tr '/' '_')" ] && continue
        lf=$(fetch_raw "$p"); [ -n "$lf" ] && add_file "$lf" "$p"
      done < "$WORK/discovered"
    fi
    # raw.githubusercontent is case sensitive; Readme.md is not a rare spelling
    for p in README.md Readme.md readme.md README.rst README.markdown README; do
      lf=$(fetch_raw "$p"); if [ -n "$lf" ]; then add_file "$lf" "$p" contributing; break; fi
    done
    for p in .github/ISSUE_TEMPLATE/bug_report.md .github/ISSUE_TEMPLATE/bug_report.yml .github/ISSUE_TEMPLATE/bug.yml .github/ISSUE_TEMPLATE/config.yml; do
      lf=$(fetch_raw "$p"); [ -n "$lf" ] && add_file "$lf" "$p"
    done
  fi
else
  for lf in "${LOCAL_FILES[@]}"; do
    [ -f "$lf" ] || { echo "no such file: $lf" >&2; exit 3; }
    add_file "$lf" "$(basename "$lf")"
  done
  NO_MERGES=1
fi

FETCH_ERRORS=$(wc -l < "$WORK/fetch_errors" | tr -d ' ')

# ---------------------------------------------------------------- classification
awk -f "$HERE/classify.awk" "$WORK/units" > "$WORK/hits"
count() { awk -F'\t' -v c="$1" '$1==c' "$WORK/hits" | wc -l | tr -d ' '; }
N_FORBID=$(count FORBID); N_PARTIAL=$(count FORBID_PARTIAL); N_DISCLOSE=$(count DISCLOSE); N_SOFT=$(count DISCLOSE_SOFT)
N_OVERSIGHT=$(count OVERSIGHT); N_ALLOW=$(count ALLOW); N_MENTION=$(count MENTION); N_ISSUE=$(count ISSUE_ONLY)
N_NOCOAUTHOR=$(count NOCOAUTHOR); N_MEDIA=$(count MEDIA_ONLY); N_CLA=$(count CLA); N_NOCLA=$(count NOCLA); N_DCO=$(count DCO)
N_NOAI=$(count NOAI_ATTEST)

# A pull request template that makes you affirm "no AI was used here" is a ban
# when the project offers no way to say the opposite; where a disclosure rule
# exists too, the same line is just the "none used" branch of that rule.
if [ "$N_NOAI" -gt 0 ]; then
  if [ "$N_DISCLOSE" -eq 0 ] && [ "$N_SOFT" -eq 0 ]; then
    N_FORBID=$((N_FORBID + N_NOAI))
  else
    N_DISCLOSE=$((N_DISCLOSE + N_NOAI))
  fi
fi

# A ban with a size on it ("no fully AI-generated pull requests", "no substantial
# use of AI-generated content") does not close the door: it says a human has to
# do the work and, where the project also asks for it, say so. The quoted line
# goes into the notes either way, because it is the line that decides how much
# of the change may come from the tool.
TEXT_STANCE=silent
if   [ "$N_FORBID" -gt 0 ]; then TEXT_STANCE=forbid
elif [ "$N_PARTIAL" -gt 0 ] && [ "$N_DISCLOSE" -gt 0 ]; then TEXT_STANCE=disclose
elif [ "$N_PARTIAL" -gt 0 ]; then TEXT_STANCE=oversight
elif [ "$N_DISCLOSE" -gt 0 ]; then TEXT_STANCE=disclose
elif [ "$N_OVERSIGHT" -gt 0 ]; then TEXT_STANCE=oversight
elif [ "$N_ALLOW" -gt 0 ] || [ "$N_SOFT" -gt 0 ]; then TEXT_STANCE=allow
elif [ "$N_MENTION" -gt 0 ] || [ "$N_ISSUE" -gt 0 ]; then TEXT_STANCE=mention
fi

# CLA / DCO
CLA_TEXT=""; DCO=false
if [ "$N_CLA" -gt 0 ] && [ "$N_NOCLA" -eq 0 ]; then
  CLA_TEXT=$(awk -F'\t' '$1=="CLA"{print $3; exit}' "$WORK/hits" | cut -c1-160)
fi
for p in .clabot .github_cla.yml .github_workflows_cla.yml CLA.md .github_CLA.md; do
  [ -f "$WORK/files/$p" ] && { [ -z "$CLA_TEXT" ] && CLA_TEXT="CLA configuration present: $(printf '%s' "$p" | tr '_' '/')"; }
done
[ "$N_DCO" -gt 0 ] && DCO=true
[ -f "$WORK/files/.github_workflows_dco.yml" ] && DCO=true
if [ -n "$ORG_JSON" ]; then
  [ "$(printf '%s' "$ORG_JSON" | jq -r .dco)" = true ] && DCO=true
  [ -z "$CLA_TEXT" ] && CLA_TEXT=$(printf '%s' "$ORG_JSON" | jq -r '.cla // ""')
fi

# dataset cross-check (melissawm list). --no-dataset turns it off so the pattern
# set can be measured against that list instead of being fed by it.
DS_STANCE=""; DS_NOTE=""
if [ -n "$REPO" ] && [ "$NO_DATASET" = 0 ]; then
  REPO_LC=$(printf '%s' "$REPO" | tr 'A-Z' 'a-z')
  if [ "$KIND" = github ]; then
    DS=$(jq -c --arg r "$REPO_LC" '.policies[] | select(.github == $r)' "$DATA/policies.json" | head -1)
  else
    # Off github.com the list has no "github" field to match on, but 183 of its
    # entries link to a gitlab or codeberg page. The project url and the policy
    # url are cut back to host/path and compared with the target: the link to
    # gitlab.gnome.org/World/gedit/gedit/-/blob/master/docs/... identifies the
    # project it is a link into.
    DS=$(jq -c --arg t "$HOST/$REPO_LC" '
      def key(u): (u // "") | ascii_downcase | sub("^https?://"; "") | sub("^www\\."; "")
                  | split("/-/")[0] | split("/src/branch/")[0] | split("/src/commit/")[0]
                  | sub("/$"; "");
      .policies[] | select(key(.url) == $t or key(.policy_url) == $t)' "$DATA/policies.json" | head -1)
  fi
  # Asahi Linux and curl publish their policy on their own website, so the list
  # has no repository for them. data/aliases.tsv says which repository it governs.
  if [ -z "$DS" ] && [ -f "$DATA/aliases.tsv" ]; then
    DS_PROJECT=$(awk -F'\t' -v r="$REPO_LC" '
      /^#/ || NF < 2 { next }
      { p = tolower($1); o = p; sub(/\/.*/, "", o)
        if (p == r || (p == o "/*" && o == substr(r, 1, index(r, "/") - 1))) { print $2; exit } }
      ' "$DATA/aliases.tsv")
    [ -n "$DS_PROJECT" ] && DS=$(jq -c --arg p "$DS_PROJECT" '.policies[] | select(.project == $p)' "$DATA/policies.json" | head -1)
  fi
  if [ -n "$DS" ]; then
    a=$(printf '%s' "$DS" | jq -r .allowed); d=$(printf '%s' "$DS" | jq -r .disclosure); h=$(printf '%s' "$DS" | jq -r .human_oversight)
    case "$a" in
      No|No\*) DS_STANCE=forbid ;;
      Yes|Yes\*) if [ "$d" = Yes ] || [ "$d" = 'Yes*' ]; then DS_STANCE=disclose; elif [ "$h" = Yes ]; then DS_STANCE=oversight; else DS_STANCE=allow; fi ;;
      *) DS_STANCE=unknown ;;
    esac
    DS_NOTE="$(printf '%s' "$DS" | jq -r '"\(.project): allowed=\(.allowed) disclosure=\(.disclosure) human_oversight=\(.human_oversight) \(.policy_url)"')"
  fi
fi

# effective stance: text first, dataset and org fill silence; on conflict the stricter wins
rank() { case "$1" in forbid) echo 4 ;; disclose) echo 3 ;; oversight) echo 2 ;; allow) echo 1 ;; *) echo 0 ;; esac; }
STANCE=$TEXT_STANCE; STANCE_SOURCE=text
if [ -n "$DS_STANCE" ] && [ "$DS_STANCE" != unknown ]; then
  if [ "$(rank "$DS_STANCE")" -gt "$(rank "$STANCE")" ]; then
    [ "$(rank "$STANCE")" -gt 0 ] && note "text scan says $TEXT_STANCE, policy list says $DS_STANCE; applying the stricter one"
    STANCE=$DS_STANCE; STANCE_SOURCE=dataset
  elif [ "$(rank "$DS_STANCE")" -lt "$(rank "$STANCE")" ] && [ "$(rank "$STANCE")" -gt 0 ]; then
    note "policy list says $DS_STANCE, text scan says $TEXT_STANCE; applying the stricter one"
  fi
fi
# The organisation rule is a default, not an override: it is read only where the
# repository and the policy list are both silent. A project that publishes its
# own rule is the authority on its own pull requests, even when the foundation
# above it is stricter (an ASF project may forbid what the ASF allows, and a
# GNOME project on the GitHub mirror may say something of its own).
if [ "$(rank "$STANCE")" -eq 0 ] && [ -n "$ORG_STANCE" ] && [ "$ORG_STANCE" != silent ]; then
  STANCE=$ORG_STANCE; STANCE_SOURCE=org; ORG_APPLIED=true
fi

# ---------------------------------------------------------------- merge statistics
MERGES_CHECKED=0
# The 90-day split between member and outside merges comes from author_association
# in the GitHub search API. GitLab and Gitea list merged requests but say nothing
# about the author's standing in the project, so the number is left unread rather
# than guessed at, and the openness line says it was not scored.
if [ "$NO_MERGES" = 0 ] && [ "$KIND" != github ]; then
  NO_MERGES=1
  note "the 90-day merge statistics are read from the GitHub search API; $HOST does not report whether a merge came from outside the project"
fi
if [ "$NO_MERGES" = 0 ] && [ "$VERDICT" != STOP ]; then
  SINCE=$(date -u -d '90 days ago' +%Y-%m-%d 2>/dev/null || date -u -v-90d +%Y-%m-%d)
  # The search bucket is the smallest one (30 a minute), and a 90-day count does
  # not move within a day: it is cached like everything else.
  M=$(cache_get _merges.tsv) || {
    M=$(gh_api -X GET search/issues -f q="repo:$REPO is:pr is:merged merged:>=$SINCE" -f per_page=100 \
        --jq '[.total_count, ([.items[]|select(.author_association=="NONE" or .author_association=="CONTRIBUTOR" or .author_association=="FIRST_TIME_CONTRIBUTOR" or .author_association=="FIRST_TIMER")]|length), (.items|length)]|@tsv') || M=""
    [ -n "$M" ] && printf '%s' "$M" | cache_put _merges.tsv
  }
  if [ -n "$M" ]; then
    MERGES_TOTAL=$(printf '%s' "$M" | cut -f1); ext=$(printf '%s' "$M" | cut -f2); MERGES_SAMPLE=$(printf '%s' "$M" | cut -f3)
    if [ "$MERGES_SAMPLE" -gt 0 ] && [ "$MERGES_TOTAL" -gt "$MERGES_SAMPLE" ]; then MERGES_EXT=$(( ext * MERGES_TOTAL / MERGES_SAMPLE )); else MERGES_EXT=$ext; fi
    MERGES_CHECKED=1
    if [ "$MERGES_TOTAL" -eq 0 ]; then reason "no pull request merged in the last 90 days"
    elif [ "$ext" -eq 0 ]; then reason "no pull request from an outside contributor merged in the last 90 days ($MERGES_TOTAL merges, all from members)"
    elif [ "$MERGES_EXT" -le 2 ]; then note "only $MERGES_EXT outside pull request(s) merged in 90 days; expect slow review"
    fi
  else
    rl_load github.com
    if [ -n "$RATE_LIMITED" ]; then note "the 90-day merge statistics could not be read: rate limited by $RATE_LIMITED${RATE_LIMITED_WAIT:+ (it asks for $RATE_LIMITED_WAIT s)}"
    else note "the 90-day merge statistics could not be read (search API)"; fi
    FETCH_ERRORS=$((FETCH_ERRORS + 1))
  fi
fi

# One number for "will a pull request from an outsider be read here?", with the
# counts it was made from printed next to it. The scale lives in openness.awk so
# it can be graded on its own, without a repository.
if [ -z "$REPO" ]; then
  OPENNESS_SCORE=null; OPENNESS_TEXT="not scored (local files, no repository)"
else
  OPENNESS=$(awk -v archived="$ARCHIVED" -v has_prs="$HAS_PRS" \
                 -v policy="$(printf '%s' "$PR_POLICY" | tr -d '"')" \
                 -v total="$MERGES_TOTAL" -v ext="$MERGES_EXT" -v sample="$MERGES_SAMPLE" \
                 -v checked="$MERGES_CHECKED" -f "$HERE/openness.awk")
  OPENNESS_SCORE=$(printf '%s' "$OPENNESS" | cut -f1)
  OPENNESS_TEXT=$(printf '%s' "$OPENNESS" | cut -f2)
fi

# ---------------------------------------------------------------- verdict
quote_lines() { awk -F'\t' -v c="$1" '$1==c {print $2"\t"$3}' "$WORK/hits" | head -n "${2:-4}"; }
DISCLOSURE=""
[ "$N_NOCOAUTHOR" -gt 0 ] && note "the tool must not appear in a Co-authored-by trailer"
[ "$N_PARTIAL" -gt 0 ] && note "part of the AI use is refused: $(awk -F'\t' '$1=="FORBID_PARTIAL"{print $3; exit}' "$WORK/hits" | cut -c1-200)"
[ "$N_ISSUE" -gt 0 ] && note "a rule about AI-generated issues or comments was found (not about pull requests)"
[ "$N_MEDIA" -gt 0 ] && note "AI-generated media (images, audio, translations) is not accepted; code and text rules apply as quoted"

# Where the verdict comes from the organisation, the sentence printed is the
# organisation's rule and its url, not a summary: the repository said nothing,
# so the quoted evidence has to be the rule that was inherited.
org_said() { printf 'the repository states no rule; %s: %s (%s)' "$ORG_NAME" "$ORG_RULE" "$ORG_URL"; }
if [ -s "$WORK/reasons" ]; then
  VERDICT=STOP
else
  case "$STANCE" in
    forbid)
      VERDICT=STOP
      if [ "$STANCE_SOURCE" = org ]; then reason "$(org_said)"
      else reason "AI-assisted contributions are not accepted ($STANCE_SOURCE)"; fi ;;
    disclose)
      VERDICT=GO-DECLARE
      if [ "$STANCE_SOURCE" = org ]; then reason "$(org_said)"
      else reason "AI use must be disclosed ($STANCE_SOURCE)"; fi ;;
    oversight)
      VERDICT=GO
      if [ "$STANCE_SOURCE" = org ]; then note "$(org_said)"
      else note "AI use is allowed with human review and understanding of every change ($STANCE_SOURCE)"; fi ;;
    allow)
      VERDICT=GO
      if [ "$STANCE_SOURCE" = org ]; then note "$(org_said)"
      else note "AI use is allowed ($STANCE_SOURCE)"; fi
      [ "$N_SOFT" -gt 0 ] && note "disclosure is appreciated but not required; the disclosure line below is recommended" ;;
    mention)
      VERDICT=GO; note "AI is mentioned but no rule for contributions was found; read the quoted lines" ;;
    *)
      VERDICT=GO; note "no AI contribution rule found in the files read" ;;
  esac
  # A CLA does not stop a pull request from being opened, it stops it from being
  # merged until a human signs it. It is a note, not a verdict, unless asked for.
  if [ -n "$CLA_TEXT" ] && [ "$VERDICT" != STOP ]; then
    if [ "$STOP_ON_CLA" = 1 ]; then VERDICT=STOP; reason "a contributor license agreement is required (--stop-on-cla): $CLA_TEXT"
    else note "a contributor license agreement is required before this can be merged; you sign it, never the agent ($CLA_TEXT)"; fi
  fi
fi

# Disclosure line for GO-DECLARE (and recommended for GO with soft disclosure),
# in the form the project asked for. Signed-off-by is never one of the forms:
# only a human can certify the DCO. Documentation/process/coding-assistants.rst
# in the kernel tree says it outright - "AI agents MUST NOT add Signed-off-by
# tags" - and the same file gives the Assisted-by format as
# "Assisted-by: LLM [TOOL1] [TOOL2]", where the bracketed slots are optional
# analysis tools (coccinelle, sparse), not the name of the agent's own tool.
# The addendum reads that format as "Assisted-by: AGENT:MODEL [TOOL]"; the
# source does not support putting the editor in a tool slot, so the agent goes
# in the first slot as one token and the slots stay empty.
#
# An organisation that inherited the verdict also owns the wording: for an ASF
# project with a silent CONTRIBUTING.md the answer is the ASF trailer, not a
# sentence of ours. The same line is offered - as a recommendation, not a
# requirement - when the organisation allows AI work and still publishes a form
# of words for it (the PSF asks CPython contributors to say so).
if [ "$STANCE_SOURCE" = org ] && [ -n "$ORG_LINE" ] \
   && { [ "$VERDICT" = GO-DECLARE ] || [ "$VERDICT" = GO ]; }; then
  DISCLOSURE="$ORG_LINE"
  [ "$VERDICT" = GO ] && note "the organisation does not require a disclosure; the line below is the form it uses"
elif [ "$VERDICT" = GO-DECLARE ] || { [ "$VERDICT" = GO ] && [ "$N_SOFT" -gt 0 ]; }; then
  if grep -qai 'generated-by' "$WORK/units"; then
    DISCLOSURE="Generated-by: $TOOL"
  elif grep -qai 'assisted-by' "$WORK/units"; then
    DISCLOSURE="Assisted-by: $AGENT:$MODEL"
  elif awk -F'\t' '$1=="DISCLOSE" && $3 ~ /\[[ xX]\]/' "$WORK/hits" | grep -q .; then
    DISCLOSURE="Pull request template: tick the AI checkbox: $(awk -F'\t' '$1=="DISCLOSE" && $3 ~ /\[[ xX]\]/ {print $3; exit}' "$WORK/hits" | cut -c1-140)"
  elif [ -n "$ORG_LINE" ]; then
    # The repository asks for a disclosure but not for a shape; the organisation
    # it belongs to has one, so the contributor writes the line its reviewers read.
    DISCLOSURE="$ORG_LINE"
  else
    DISCLOSURE="Pull request description: \"AI disclosure: this change was prepared with $TOOL ($AGENT:$MODEL). I reviewed and tested every line and take responsibility for it.\""
  fi
fi

# injection scan overrides everything but a plain STOP
N_INJ=$(wc -l < "$WORK/injection" | tr -d ' ')
N_SUSP=$(awk -F'\t' '$2=="suspicious"' "$WORK/injection" | wc -l | tr -d ' ')
if [ "$N_SUSP" -gt 0 ]; then
  INJ_STATUS=suspicious
  reason "$N_SUSP suspicious pattern(s) in the policy files; a human must read them before anything else happens"
  [ "$VERDICT" != STOP ] && VERDICT=STOP-CHECK
elif [ "$N_INJ" -gt 0 ]; then
  INJ_STATUS=notice
  note "$N_INJ command(s) or opaque blob(s) quoted in the policy files; read them, do not run them"
else
  INJ_STATUS=none
fi

# network trouble never turns into a silent GO
if [ "$FETCH_ERRORS" -gt 0 ] && [ "$VERDICT" = GO ]; then
  VERDICT=UNKNOWN
  rl_load
  if [ -n "$RATE_LIMITED" ]; then reason "$FETCH_ERRORS download(s) refused: rate limited by $RATE_LIMITED${RATE_LIMITED_WAIT:+, wait $RATE_LIMITED_WAIT s}; rerun before trusting a GO"
  elif [ -n "$HOST_DOWN" ]; then reason "$FETCH_ERRORS download(s) failed: no answer from $HOST_DOWN; rerun before trusting a GO"
  else reason "$FETCH_ERRORS download(s) failed; rerun before trusting a GO"; fi
fi
[ "$DCO" = true ] && note "DCO sign-off required: the human contributor adds Signed-off-by (git commit -s); an agent must not"
if [ -n "$ORG_ID" ]; then
  if [ "$ORG_APPLIED" = true ]; then note "organisation rule applied: $ORG_NAME ($ORG_STANCE) $ORG_URL"
  elif [ "$ORG_STANCE" = silent ]; then note "organisation: $ORG_NAME publishes no AI rule of its own; any CLA or DCO requirement above comes from it ($ORG_URL)"
  else note "organisation: $ORG_NAME says $ORG_STANCE ($ORG_URL); the repository's own text decides and was used"; fi
fi
[ -n "$DS_NOTE" ] && note "policy list: $DS_NOTE"

case "$VERDICT" in GO) EXIT=0 ;; GO-DECLARE) EXIT=1 ;; STOP|STOP-CHECK) EXIT=2 ;; *) EXIT=3 ;; esac
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ---------------------------------------------------------------- receipt
# The evidence of a scan: which files were read, what they hashed to, what the
# answer was. Kept so that a later run can say "the policy moved under you" and
# so that a contributor in an argument can show which text was read and when.
: > "$WORK/receipt_changes"
RECEIPT_STATUS=off; RECEIPT_PREV_TS=""; RECEIPT_PREV_VERDICT=""
CUR_FILES=$(jq -n --rawfile h "$WORK/hashes" \
  '[$h | split("\n")[] | select(length > 0) | split("\t") | {(.[0]): .[1]}] | add // {}')
if [ "$RECEIPT" = 1 ]; then
  RECEIPT_STATUS=new
  if [ -f "$RECEIPT_PATH" ] && jq -e . "$RECEIPT_PATH" >/dev/null 2>&1; then
    prev_repo=$(jq -r '.repo // ""' "$RECEIPT_PATH")
    # The host is part of the target: the same path on two forges is two
    # projects. A receipt written before this field existed is a github.com one.
    prev_host=$(jq -r '.host // "github.com"' "$RECEIPT_PATH")
    [ -z "$prev_repo" ] && prev_host=""
    if [ "$prev_repo" != "${REPO:-}" ] || [ "$prev_host" != "${HOST:-}" ]; then
      RECEIPT_STATUS=other-target
      note "the receipt at $RECEIPT_PATH was written for ${prev_host:+$prev_host/}${prev_repo:-local files}; it is being replaced"
    else
      RECEIPT_PREV_TS=$(jq -r '.ts // ""' "$RECEIPT_PATH")
      RECEIPT_PREV_VERDICT=$(jq -r '.verdict // ""' "$RECEIPT_PATH")
      jq -r --argjson cur "$CUR_FILES" '
        (.files // {}) as $old
        | [ ($cur  | keys[] | select($old[.] == null)        | . + " (new)") ]
        + [ ($cur  | keys[] | select($old[.] != null and $old[.] != $cur[.]) | . + " (changed)") ]
        + [ ($old  | keys[] | select($cur[.] == null)        | . + " (gone)") ]
        | .[]' "$RECEIPT_PATH" > "$WORK/receipt_changes" 2>/dev/null
      if [ -s "$WORK/receipt_changes" ]; then
        RECEIPT_STATUS=changed
        note "the policy changed since the receipt of $RECEIPT_PREV_TS: $(awk '{printf "%s%s", sep, $0; sep=", "}' "$WORK/receipt_changes"); read the quoted lines again"
      else
        RECEIPT_STATUS=unchanged
      fi
      if [ -n "$RECEIPT_PREV_VERDICT" ] && [ "$RECEIPT_PREV_VERDICT" != "$VERDICT" ]; then
        note "the verdict changed since the receipt of $RECEIPT_PREV_TS: $RECEIPT_PREV_VERDICT -> $VERDICT"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------- output
build_json() {
  jq -n \
    --arg version "$VERSION" --arg ts "$TS" --arg repo "${REPO:-}" --arg host "$HOST" --arg kind "$KIND" \
    --arg verdict "$VERDICT" --arg stance "$STANCE" --arg stance_source "$STANCE_SOURCE" \
    --arg disclosure "$DISCLOSURE" --arg cla "$CLA_TEXT" --argjson dco "$DCO" \
    --arg org "$ORG_ID" --arg org_stance "$ORG_STANCE" --arg org_name "$ORG_NAME" --arg org_rule "$ORG_RULE" \
    --arg org_url "$ORG_URL" --argjson org_applied "$ORG_APPLIED" \
    --argjson archived "$ARCHIVED" --argjson has_prs "$HAS_PRS" --argjson pr_policy "$PR_POLICY" \
    --argjson mt "$MERGES_TOTAL" --argjson me "$MERGES_EXT" --argjson ms "$MERGES_SAMPLE" \
    --arg score "$OPENNESS_SCORE" --arg otext "$OPENNESS_TEXT" \
    --rawfile reasons "$WORK/reasons" --rawfile notes "$WORK/notes" --rawfile hits "$WORK/hits" --rawfile inj "$WORK/injection" --rawfile hashes "$WORK/hashes" \
    --argjson fetch_errors "$FETCH_ERRORS" --arg text_stance "$TEXT_STANCE" --arg ds_stance "$DS_STANCE" --arg inj_status "$INJ_STATUS" \
    --arg r_status "$RECEIPT_STATUS" --arg r_path "$RECEIPT_PATH" --arg r_ts "$RECEIPT_PREV_TS" --arg r_verdict "$RECEIPT_PREV_VERDICT" \
    --rawfile r_changes "$WORK/receipt_changes" '
    def lines(s): s | split("\n") | map(select(length > 0));
    {
      version: $version, ts: $ts, repo: (if $repo == "" then null else $repo end),
      host: (if $host == "" then null else $host end),
      kind: (if $kind == "" then null else $kind end),
      verdict: $verdict,
      reasons: lines($reasons),
      notes: lines($notes),
      stance: {effective: $stance, source: $stance_source, text: $text_stance, dataset: (if $ds_stance == "" then null else $ds_stance end)},
      quotes: (lines($hits) | map(split("\t") | select(.[0] != "MENTION") | {class: .[0], at: .[1], text: .[2]})),
      disclosure: (if $disclosure == "" then null else $disclosure end),
      openness: {score: (if $score == "null" then null else ($score | tonumber) end), summary: $otext,
                 archived: $archived, has_pull_requests: $has_prs, pull_request_creation_policy: $pr_policy,
                 merged_90d: $mt, merged_90d_external: $me, sample: $ms},
      injection: {status: $inj_status,
                  findings: (lines($inj) | map(split("\t") | {kind: .[0], severity: .[1], at: .[2], text: .[3]}))},
      cla: (if $cla == "" then null else $cla end),
      dco: $dco,
      org_policy: (if $org == "" then null
                   else {id: $org, name: $org_name, stance: $org_stance, rule: $org_rule,
                         policy_url: $org_url, applied: $org_applied} end),
      files: (lines($hashes) | map(split("\t") | {(.[0]): .[1]}) | add // {}),
      receipt: (if $r_status == "off" then null
                else {path: $r_path, status: $r_status,
                      previous_ts: (if $r_ts == "" then null else $r_ts end),
                      previous_verdict: (if $r_verdict == "" then null else $r_verdict end),
                      changed: lines($r_changes)} end),
      fetch_errors: $fetch_errors
    }'
}

OUT_JSON="$WORK/out.json"
build_json > "$OUT_JSON"

# The receipt is written last, so it holds the run exactly as it was reported.
if [ "$RECEIPT" = 1 ]; then
  if mkdir -p "$(dirname "$RECEIPT_PATH")" 2>/dev/null && cp "$OUT_JSON" "$RECEIPT_PATH" 2>/dev/null; then
    :
  else
    echo "could not write the receipt: $RECEIPT_PATH" >&2
    RECEIPT_STATUS=failed
  fi
fi

if [ "$JSON" = 1 ]; then
  cat "$OUT_JSON"
else
  if [ "$QUIET" = 1 ]; then echo "$VERDICT"; exit $EXIT; fi
  # github.com is the unwritten default, so only another host is named.
  if [ -z "$REPO" ]; then WHERE="local files"
  elif [ "$HOST" = github.com ]; then WHERE="$REPO"
  else WHERE="$HOST/$REPO ($KIND)"; fi
  echo "contrib-policy $VERSION  $WHERE  $TS"
  echo "verdict: $VERDICT"
  if [ -s "$WORK/reasons" ]; then echo "reasons:"; sed 's/^/  - /' "$WORK/reasons"; fi
  if [ "$(awk -F'\t' '$1!="MENTION"' "$WORK/hits" | wc -l)" -gt 0 ]; then
    echo "quotes:"
    for c in FORBID FORBID_PARTIAL NOAI_ATTEST DISCLOSE OVERSIGHT ALLOW DISCLOSE_SOFT NOCOAUTHOR ISSUE_ONLY MEDIA_ONLY CLA NOCLA DCO; do
      quote_lines "$c" 3 | awk -F'\t' -v c="$c" '{printf "  - [%s] %s  \"%s\"\n", c, $1, substr($2,1,220)}'
    done
  fi
  echo "disclosure: ${DISCLOSURE:-none required}"
  echo "openness: $OPENNESS_TEXT"
  if [ "$N_INJ" -gt 0 ]; then
    echo "injection: $INJ_STATUS ($N_SUSP suspicious, $((N_INJ - N_SUSP)) notice)"
    sort -t"$(printf '\t')" -k2,2 "$WORK/injection" \
      | awk -F'\t' '{printf "  - [%s] %s %s  \"%s\"\n", $2, $1, $3, substr($4,1,160)}' | head -n 10
  else echo "injection: none"; fi
  echo "cla: ${CLA_TEXT:-none found}"
  echo "dco: $DCO"
  if [ -z "$ORG_ID" ]; then echo "org_policy: none"
  elif [ "$ORG_APPLIED" = true ]; then echo "org_policy: $ORG_ID ($ORG_STANCE) applied"
  else echo "org_policy: $ORG_ID ($ORG_STANCE) not applied"; fi
  if [ "$RECEIPT" = 1 ]; then
    echo "receipt: $RECEIPT_PATH ($RECEIPT_STATUS)"
    [ "$RECEIPT_STATUS" = new ] && echo "  add .contrib-policy/ to .gitignore"
    [ -s "$WORK/receipt_changes" ] && sed 's/^/  - /' "$WORK/receipt_changes"
  fi
  if [ -s "$WORK/notes" ]; then echo "notes:"; sed 's/^/  - /' "$WORK/notes"; fi
  echo "files read: $(wc -l < "$WORK/hashes" | tr -d ' ')"
fi
exit $EXIT
