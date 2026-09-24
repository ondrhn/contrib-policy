# contrib-policy: network etiquette, sourced by policy_scan.sh.
#
# Every host this tool reads from rate-limits: api.github.com 5000 calls an hour
# and 30 searches a minute for a token, raw.githubusercontent.com and the GitLab
# and Gitea instances per address. A scan that hits a limit must neither hammer
# the host nor turn the missing answer into a GO, so:
#
#   throttle    keeps consecutive requests $CONTRIB_POLICY_MIN_GAP_MS apart
#   limited     says whether an answer is a rate limit: 429, or 403 with the
#               X-RateLimit-Remaining header at 0 or a Retry-After header
#               (github's secondary limit answers that way)
#   retry_wait  reads Retry-After / X-RateLimit-Reset / RateLimit-Reset from the
#               answer headers and says how long to wait, or refuses when the
#               limit is further away than $CONTRIB_POLICY_MAX_WAIT seconds
#   http_get    curl with those retries ($CONTRIB_POLICY_RETRIES, default 2)
#   gh_api      the same for gh, whose stderr says "rate limit" and whose reset
#               time is read from the free /rate_limit endpoint
#
# State lives in files under $WORK, not in variables: the scanner calls these
# helpers inside $(...), and a variable set in a subshell is lost on return.
#   $WORK/limited.HOST   the host refused for longer than MAX_WAIT; content = seconds it asked for
#   $WORK/down.HOST      the host gave no answer after the retries
#   $WORK/last_req_ns    when the last request went out
# rl_load [HOST] reads them back into RATE_LIMITED / RATE_LIMITED_WAIT / HOST_DOWN
# for the caller; rl_blocked HOST says whether a host should not be asked again.
#
# Needs from the caller: $WORK (scratch dir), $TIMEOUT (curl --max-time).
# Bash 3.2 and macOS date are enough: without %N the throttle simply does nothing.

RETRIES="${CONTRIB_POLICY_RETRIES:-2}"
MAX_WAIT="${CONTRIB_POLICY_MAX_WAIT:-30}"
MIN_GAP_MS="${CONTRIB_POLICY_MIN_GAP_MS:-50}"
case "$RETRIES"    in ''|*[!0-9]*) RETRIES=2 ;; esac
case "$MAX_WAIT"   in ''|*[!0-9]*) MAX_WAIT=30 ;; esac
case "$MIN_GAP_MS" in ''|*[!0-9]*) MIN_GAP_MS=50 ;; esac

RATE_LIMITED=""      # host name once a limit was hit and the wait ran out
RATE_LIMITED_WAIT="" # seconds that host asked for, when it said
HOST_DOWN=""         # host name once it stopped answering

url_host() { local h="${1#*://}"; printf '%s' "${h%%/*}"; }

rl_mark_limited() { printf '%s' "${2:-}" > "$WORK/limited.$1"; }
rl_mark_down()    { : > "$WORK/down.$1"; }
rl_blocked()      { [ -f "$WORK/limited.$1" ] || [ -f "$WORK/down.$1" ]; }
rl_load() { # rl_load [HOST] -> RATE_LIMITED, RATE_LIMITED_WAIT, HOST_DOWN for that host, or for any host
  local f
  RATE_LIMITED=""; RATE_LIMITED_WAIT=""; HOST_DOWN=""
  for f in "$WORK"/limited.${1:-*}; do
    [ -f "$f" ] || continue
    RATE_LIMITED="${f##*/limited.}"; RATE_LIMITED_WAIT=$(cat "$f"); break
  done
  for f in "$WORK"/down.${1:-*}; do
    [ -f "$f" ] || continue
    HOST_DOWN="${f##*/down.}"; break
  done
  [ -n "$RATE_LIMITED" ] || [ -n "$HOST_DOWN" ]
}

throttle() { # keep consecutive network requests MIN_GAP_MS apart
  [ "$MIN_GAP_MS" -gt 0 ] || return 0
  local now last gap
  now=$(date +%s%N 2>/dev/null) || return 0
  case "$now" in ''|*[!0-9]*) return 0 ;; esac    # a date without %N prints the letter
  last=$(cat "$WORK/last_req_ns" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$last" -gt 0 ]; then
    gap=$(( (now - last) / 1000000 ))
    if [ "$gap" -lt "$MIN_GAP_MS" ]; then
      sleep "$(awk -v ms=$((MIN_GAP_MS - gap)) 'BEGIN { printf "%.3f", ms / 1000 }')"
    fi
  fi
  date +%s%N > "$WORK/last_req_ns"
}

limited() { # limited CODE HEADERFILE -> 0 when the answer is a rate limit
  case "$1" in
    429) return 0 ;;
    403) grep -aiqE '^(x-)?ratelimit-remaining: *0[^0-9]*$' "$2" 2>/dev/null \
         || grep -aiq '^retry-after:' "$2" 2>/dev/null ;;
    *)   return 1 ;;
  esac
}

retry_wait() { # retry_wait ATTEMPT HEADERFILE -> seconds to wait; non-zero when the limit is too far away
  local attempt="$1" hdr="$2" ra reset now w=""
  ra=$(grep -ai '^retry-after:' "$hdr" 2>/dev/null | tail -1 | cut -d: -f2- | tr -d '\r' | sed 's/^ *//; s/ *$//')
  if [ -n "$ra" ]; then
    case "$ra" in
      *[!0-9]*) # an http-date is allowed too; GNU date reads it, any other date means "no header"
        now=$(date +%s); reset=$(date -d "$ra" +%s 2>/dev/null)
        if [ -n "$reset" ]; then w=$((reset - now + 1)); [ "$w" -lt 1 ] && w=1; fi ;;
      *) w=$ra ;;
    esac
  else
    reset=$(grep -aiE '^(x-)?ratelimit-reset:' "$hdr" 2>/dev/null | tail -1 | tr -dc '0-9')
    if [ -n "$reset" ]; then
      now=$(date +%s)
      # github and gitlab send an epoch; a value smaller than a day is a delta
      if [ "$reset" -gt 86400 ]; then
        w=$((reset - now + 1)); [ "$w" -lt 1 ] && w=1
      else
        w=$reset
      fi
    fi
  fi
  [ -n "$w" ] || w=$((attempt * 2))                 # no header: 2 s, 4 s, 6 s
  if [ "$w" -gt "$MAX_WAIT" ]; then printf '%s' "$w"; return 1; fi
  printf '%s' "$w"
}

http_get() { # http_get URL OUT [ACCEPT] -> prints the http code (000 = no answer)
  local url="$1" out="$2" accept="${3:-}" hdr="$WORK/headers" host code attempt=0 w
  local -a hd=()
  [ -n "$accept" ] && hd=(-H "Accept: $accept")
  host=$(url_host "$url")
  # A host that already refused, or stopped answering, is not asked again in
  # this scan: every further request would be one more refusal or one more
  # TIMEOUT spent on nothing.
  if rl_blocked "$host"; then rm -f "$out"; printf '000'; return 0; fi
  while :; do
    throttle
    : > "$hdr"
    code=$(curl -sL --max-time "$TIMEOUT" -D "$hdr" ${hd[@]+"${hd[@]}"} -o "$out" -w '%{http_code}' "$url" 2>/dev/null) || code=000
    case "$code" in
      429|5[0-9][0-9]|000) ;;
      403) limited "$code" "$hdr" || break ;;
      *) break ;;
    esac
    attempt=$((attempt + 1))
    if [ "$attempt" -gt "$RETRIES" ]; then
      if limited "$code" "$hdr"; then rl_mark_limited "$host" "$(retry_wait "$attempt" "$hdr")"
      elif [ "$code" = 000 ]; then rl_mark_down "$host"; fi
      break
    fi
    if w=$(retry_wait "$attempt" "$hdr"); then
      sleep "$w"
    else
      rl_mark_limited "$host" "$w"; break
    fi
  done
  printf '%s' "$code"
}

gh_api() { # gh_api ARGS... -> body on stdout, only when gh succeeded; stderr of the last try in $WORK/gh.err
  local attempt=0 err="$WORK/gh.err" body res w reset now
  if rl_blocked github.com; then : > "$err"; return 1; fi
  while :; do
    throttle
    # gh prints the error body ({"message": "API rate limit exceeded ..."}) on
    # stdout too, so nothing reaches the caller until an attempt succeeds.
    if body=$(gh api "$@" 2>"$err"); then printf '%s' "$body"; return 0; fi
    grep -aqiE 'rate limit|HTTP 429|HTTP 50[0-9]|secondary rate|abuse detection' "$err" || return 1
    attempt=$((attempt + 1))
    # gh keeps the answer headers to itself; /rate_limit is free and says when
    # the bucket refills. search and core are separate buckets.
    res=core; case "$*" in *search/*) res=search ;; esac
    reset=$(gh api rate_limit --jq ".resources.$res.reset" 2>/dev/null | tr -dc '0-9')
    now=$(date +%s)
    if [ -n "$reset" ] && [ "$reset" -gt "$now" ]; then w=$((reset - now + 1)); else w=$((attempt * 2)); fi
    if [ "$attempt" -gt "$RETRIES" ] || [ "$w" -gt "$MAX_WAIT" ]; then
      grep -aqiE 'rate limit|HTTP 429|secondary rate|abuse detection' "$err" && rl_mark_limited github.com "$w"
      return 1
    fi
    sleep "$w"
  done
}
