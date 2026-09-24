#!/usr/bin/env bash
# contrib-policy PreToolUse gate: no pull request without a fresh receipt.
#
# Claude Code calls this before a tool runs and hands it the tool call as JSON
# on stdin. It answers on stdout with a PreToolUse decision:
#
#   allow  the command is not a pull request, or the receipt says GO
#   ask    the receipt says GO-DECLARE - a human confirms that the disclosure
#          line is in the pull request body
#   deny   no receipt, an unreadable one, a stale one, one for another
#          repository, or a verdict of STOP / STOP-CHECK / UNKNOWN
#
# Gated calls: `gh pr create`, `glab mr create`, and any MCP tool whose name
# ends in create_pull_request / create_merge_request. Everything else passes
# without a word.
#
# install (optional, see SKILL.md): merge hooks/hooks.json into
# .claude/settings.json, or point $CLAUDE_PROJECT_DIR at this repository.
#
# environment:
#   CONTRIB_POLICY_RECEIPT     receipt path (default <cwd>/.contrib-policy/receipt.json)
#   CONTRIB_POLICY_MAX_AGE_H   how old a receipt may be, in hours (default 24)
#   CONTRIB_POLICY_JQ          jq to use (default: jq on PATH)
#
# The receipt is data this tool wrote itself. Nothing in it is executed.
set -u

MAX_AGE_H="${CONTRIB_POLICY_MAX_AGE_H:-24}"
case "$MAX_AGE_H" in ''|*[!0-9]*) MAX_AGE_H=24 ;; esac
JQ="${CONTRIB_POLICY_JQ:-jq}"

IN=$(cat)

# A gate that cannot read the payload must not wave a pull request through, and
# must not break every other tool call either: without jq it answers on the raw
# text, closed for anything that looks like a pull request and open otherwise.
if ! command -v "$JQ" >/dev/null 2>&1; then
  case "$IN" in
    *"pr create"*|*"mr create"*|*create_pull_request*|*create_merge_request*)
      printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"contrib-policy: jq is not installed, so the receipt cannot be checked. Install jq, or remove this hook from .claude/settings.json."}}' ;;
  esac
  exit 0
fi

printf '%s' "$IN" | "$JQ" -e . >/dev/null 2>&1 || exit 0   # not a hook payload: say nothing

TOOL=$(printf '%s' "$IN" | "$JQ" -r '.tool_name // ""')
CMD=$(printf '%s' "$IN" | "$JQ" -r '.tool_input.command // ""')
CWD=$(printf '%s' "$IN" | "$JQ" -r '.cwd // "."')
# an MCP pull request call carries the repository in its arguments
MCP_REPO=$(printf '%s' "$IN" | "$JQ" -r '[.tool_input.owner // "", .tool_input.repo // ""] | select(.[0] != "" and .[1] != "") | join("/")' 2>/dev/null)

decide() { # decide DECISION REASON
  "$JQ" -n --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
  exit 0
}

# ---------------------------------------------------------------- is this a pull request?
GATED=0
case "$TOOL" in
  *create_pull_request|*create_merge_request) GATED=1 ;;
esac
# A compound command counts: `cd x && gh pr create` is still a pull request.
# So does the raw API behind the subcommand: `gh api repos/o/r/pulls -f ...`,
# `glab api projects/N/merge_requests -f ...` and the GraphQL createPullRequest
# mutation open one without ever saying "create". A read of the same path
# (`-X GET`, or no field at all) is not gated.
if [ "$GATED" = 0 ] && [ -n "$CMD" ]; then
  printf '%s' "$CMD" | grep -Eq '(^|[^a-zA-Z0-9_./-])(gh[[:space:]]+pr[[:space:]]+create|glab[[:space:]]+mr[[:space:]]+create)([^a-zA-Z0-9_-]|$)' && GATED=1
  if [ "$GATED" = 0 ] && printf '%s' "$CMD" | grep -Eq '(^|[^a-zA-Z0-9_./-])(gh|glab)[[:space:]]+api[[:space:]]'; then
    if printf '%s' "$CMD" | grep -Eq 'createPullRequest|createMergeRequest'; then
      GATED=1
    elif printf '%s' "$CMD" | grep -Eq '/(pulls|merge_requests)([^a-zA-Z0-9_/-]|$)' \
         && ! printf '%s' "$CMD" | grep -Eq -- '(-X|--method)[[:space:]=]*(GET|HEAD)' \
         && printf '%s' "$CMD" | grep -Eq -- '(-X|--method)[[:space:]=]*(POST|PUT)|(^|[[:space:]])(-f|-F|--field|--raw-field|--input)([[:space:]=]|$)'; then
      GATED=1
    fi
  fi
fi
[ "$GATED" = 1 ] || exit 0

# ---------------------------------------------------------------- the receipt
RECEIPT="${CONTRIB_POLICY_RECEIPT:-$CWD/.contrib-policy/receipt.json}"
HOW="run: scripts/policy_scan.sh OWNER/REPO --receipt   (or HOST/GROUP/PROJECT off github.com)"

[ -f "$RECEIPT" ] || decide deny "contrib-policy: no receipt at $RECEIPT, so nobody has read this project's contribution rules yet. $HOW"
"$JQ" -e . "$RECEIPT" >/dev/null 2>&1 || decide deny "contrib-policy: the receipt at $RECEIPT is not readable json. $HOW"

# Age is taken from the file, not from the timestamp inside it: the timestamp is
# a string in a file anyone can edit, the mtime is what the filesystem saw.
if [ -z "$(find "$RECEIPT" -mmin -$((MAX_AGE_H * 60)) 2>/dev/null)" ]; then
  decide deny "contrib-policy: the receipt at $RECEIPT is older than $MAX_AGE_H hour(s) and a policy can change between two pull requests. $HOW"
fi

VERDICT=$("$JQ" -r '.verdict // ""' "$RECEIPT")
R_REPO=$("$JQ" -r '.repo // ""' "$RECEIPT")
R_HOST=$("$JQ" -r '.host // "github.com"' "$RECEIPT")
DISCLOSURE=$("$JQ" -r '.disclosure // ""' "$RECEIPT")
REASONS=$("$JQ" -r '(.reasons // []) | join("; ")' "$RECEIPT")
TARGET="$R_REPO"
[ "$R_HOST" != github.com ] && [ -n "$R_REPO" ] && TARGET="$R_HOST/$R_REPO"

# A receipt for another project is not evidence about this one. Only checked
# when the call names the repository itself (-R/--repo, or the MCP arguments);
# otherwise the target is the checkout and the scan is assumed to match it.
WANT="$MCP_REPO"
if [ -z "$WANT" ] && [ -n "$CMD" ]; then
  WANT=$(printf '%s' "$CMD" | grep -oE '(-R|--repo)[ =]+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' | head -1 | grep -oE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')
fi
if [ -z "$WANT" ] && [ -n "$CMD" ]; then   # gh api repos/OWNER/REPO/pulls
  WANT=$(printf '%s' "$CMD" | grep -oE 'repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pulls' | head -1 | sed 's|^repos/||; s|/pulls$||')
fi
if [ -n "$WANT" ] && [ -n "$R_REPO" ] && [ "$WANT" != "$R_REPO" ]; then
  decide deny "contrib-policy: the receipt at $RECEIPT was written for $TARGET, but this pull request goes to $WANT. $HOW"
fi

case "$VERDICT" in
  GO)
    exit 0 ;;
  GO-DECLARE)
    decide ask "contrib-policy: $TARGET requires AI use to be disclosed. Put this line in the pull request before confirming:
  ${DISCLOSURE:-(no disclosure line in the receipt; rerun the scan)}
Reasons read from the project: ${REASONS:-none recorded}" ;;
  STOP|STOP-CHECK)
    decide deny "contrib-policy: $VERDICT for $TARGET. ${REASONS:-no reason recorded}. Do not open this pull request; take it to a human." ;;
  *)
    decide deny "contrib-policy: the receipt for $TARGET says ${VERDICT:-(nothing)}, which is not a green light. $HOW" ;;
esac
