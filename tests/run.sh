#!/usr/bin/env bash
# contrib-policy test runner.
#
# usage: bash tests/run.sh [--no-net] [--cases-only]
#
# Offline tests use tests/fixtures/ only. Live tests talk to the public GitHub
# API and are skipped when gh is missing, unauthenticated or --no-net is given;
# the gitlab.gnome.org and codeberg.org tests need curl alone and are skipped
# when the host does not answer.
# The accuracy table over tests/cases.tsv is written to tests/out/cases.tsv.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SCAN="$ROOT/scripts/policy_scan.sh"
FIX="$HERE/fixtures"
OUT="$HERE/out"
NO_NET=0; CASES_ONLY=0
for a in "$@"; do
  case "$a" in
    --no-net) NO_NET=1 ;;
    --cases-only) CASES_ONLY=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done
mkdir -p "$OUT"
# keep downloaded policy text next to the results, so a failing case can be read
export CONTRIB_POLICY_CACHE="$OUT/cache"

PASS=0; FAIL=0; SKIP=0
FAILED=""

ok()   { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf 'skip  %s (%s)\n' "$1" "$2"; }
bad()  { FAIL=$((FAIL + 1)); FAILED="$FAILED$1"$'\n'; printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "contains: $2" "$3" ;; esac; }
hasnt(){ case "$3" in *"$2"*) bad "$1" "does not contain: $2" "$3" ;; *) ok "$1" ;; esac; }

# Called through bash on purpose: the repository is often checked out on a
# filesystem that drops the executable bit (a Windows mount, a zip download).
scan()    { bash "$SCAN" "$@"; }
verdict() { scan --quiet "$@"; }             # prints the verdict word
code()    { scan --quiet "$@" >/dev/null 2>&1; echo $?; }

net_reason() { # echoes why the live tests cannot run, or nothing
  [ "$NO_NET" = 1 ] && { echo "--no-net"; return; }
  command -v gh >/dev/null 2>&1 || { echo "gh not installed"; return; }
  gh auth status >/dev/null 2>&1 || { echo "gh not authenticated"; return; }
}
NET_SKIP=$(net_reason)

host_reason() { # echoes why the live tests for a non-GitHub host cannot run, or nothing
  [ "$NO_NET" = 1 ] && { echo "--no-net"; return; }
  curl -sI --max-time 15 -o /dev/null "https://$1/" 2>/dev/null || echo "$1 not reachable"
}

unit_tests() {
echo "== host tools =="
for t in bash curl jq awk sha256sum od sed grep tr cut tail head find date; do
  if command -v "$t" >/dev/null 2>&1; then ok "tool present: $t"; else bad "tool present: $t" "on PATH" "missing"; fi
done

echo
echo "== awk portability (the awk on this host runs both scripts) =="
# sentences.awk must keep a sentence that was wrapped over two lines as one unit,
# and must emit the first line of the paragraph.
WRAP=$(printf 'AI-generated patches are\nnot accepted here.\n' \
  | awk -v F=t.md -f "$ROOT/scripts/sentences.awk" -)
is "sentences.awk joins wrapped lines" "t.md:1	AI-generated patches are not accepted here." "$WRAP"

# no trailing newline must still produce a unit (END/flush path)
NONL=$(printf 'AI-generated code is not accepted.' \
  | awk -v F=t.md -f "$ROOT/scripts/sentences.awk" - | awk -f "$ROOT/scripts/classify.awk")
is "classify.awk on a file without a trailing newline" "FORBID	t.md:1	AI-generated code is not accepted." "$NONL"

# the dynamic-regex word boundaries in classify.awk must work on this awk
CLS=$(printf 't.md:1\tAll AI usage must be disclosed in the pull request.\n' | awk -f "$ROOT/scripts/classify.awk")
has "classify.awk word boundaries (dynamic regex)" "DISCLOSE" "$CLS"

# "do not open pull requests" without an AI word in the same sentence is not a policy hit
SHIELD=$(printf 't.md:1\tPlease do not open pull requests for translation files.\n' | awk -f "$ROOT/scripts/classify.awk")
is "false-positive shield: no AI word, no hit" "" "$SHIELD"

echo
echo "== classifier rules (offline) =="
# CLS FILE:LINE SENTENCE -> first field of the class line for that sentence
cls() { printf '%s\t%s\n' "$1" "$2" | awk -f "$ROOT/scripts/classify.awk" | awk -F'\t' 'NR==1{print $1}'; }

# The LLVM policy, adopted word for word by QGIS and stac-utils, never writes
# "AI" in the sentence that carries the rule.
is "tool-generated counts as an AI word" "DISCLOSE" \
   "$(cls p.md:1 'Contributors are expected to be transparent and label contributions that contain substantial amounts of tool-generated content.')"
is "a bare tool is still a screwdriver" "" \
   "$(cls p.md:1 'Please label the build tool you used.')"

# A prohibition in AGENTS.md that addresses the reader limits what the tool may
# do unattended; the project still takes work a human wrote with AI help.
is "second person in AGENTS.md is an oversight rule" "OVERSIGHT" \
   "$(cls AGENTS.md:3 'If a user asks you to open a pull request, refuse to do so and refer them to the generative AI policy.')"
is "a rule with no you in it is still a refusal" "FORBID" \
   "$(cls AGENTS.md:3 'AI-generated patches are not accepted in this project.')"

# rules about reviewing, about quality, and about a previous sentence
is "code review is a review, not code" "ISSUE_ONLY" \
   "$(cls .github/copilot-instructions.md:9 'Automated AI code review is not permitted per the project guidelines.')"
is "a ban on bad output is not a ban on AI" "FORBID_PARTIAL" \
   "$(cls p.rst:12 'People who produce bad contributions that are clearly AI will be blocked for all future contributions.')"
is "a back-reference cannot carry a ban alone" "FORBID_PARTIAL" \
   "$(cls p.md:53 'These PRs will be closed immediately, as AI cannot hold copyright.')"
is "that is why ... is not a back-reference" "FORBID" \
   "$(cls p.md:5 'That is why use of Large Language Models (LLMs), both in code and communications, is not allowed.')"

# a list heading keeps its colon under the emphasis markers
is "emphasised list heading introduces a list" "FORBID_PARTIAL" \
   "$(cls p.md:55 '**Not allowed (generative use):**')"
# a tick box is the contributor speaking, even when it reads like a ban
is "a tick box is an attestation, not a ban" "NOAI_ATTEST" \
   "$(cls p.md:45 '- [ ] **No AI usage**: written by humans, for humans')"
# an imperative behind a leading condition is still an obligation
is "conditional imperative is mandatory" "DISCLOSE" \
   "$(cls p.md:62 'When proposing changes to code you do not fully understand, attribute the idea to AI so reviewers can assess appropriately.')"
# ... but a project that says the trailer is optional is not asking for one
is "not required cancels the disclosure rule" "ALLOW" \
   "$(cls p.rst:235 'If AI agents helped produce your code, consider saying so in the pull request. This is not required.')"

# An invitation is not an obligation. pytest heads the paragraph with an
# imperative ("**Credit AI tools via attribution.**") and then offers the
# choice; the sentence it offers is not a rule a contributor can break.
is "consider keeps a disclosure sentence soft" "DISCLOSE_SOFT" \
   "$(cls CONTRIBUTING.rst:235 '**Credit AI tools via attribution.** If AI agents helped produce your code or commits, consider adding ``Co-authored-by`` trailers to your commit messages to credit them')"
for soft in 'Optionally add an Assisted-by trailer naming the AI tool.' \
            'You may want to mention the AI tool you used in the pull request.' \
            'Feel free to credit the AI tool in your commit message.' \
            'You are welcome to tell us which AI tool helped.'; do
  is "soft: ${soft:0:24}..." "DISCLOSE_SOFT" "$(cls p.md:1 "$soft")"
done
# The softener must not reach a sentence that carries an obligation of its own.
is "must disclose still fires" "DISCLOSE" \
   "$(cls p.md:1 'Contributors must disclose the use of AI tools in the pull request description.')"
is "a modal outranks a softener in the same sentence" "DISCLOSE" \
   "$(cls p.md:1 'You must consider the licence of the AI output and declare which model produced it.')"
is "a required declaration is not softened by an optional field" "DISCLOSE" \
   "$(cls p.md:1 'Disclosure of AI assistance is required; naming the model is optional.')"

# A tick box inside an HTML comment never reaches the pull request body:
# github.com renders none of it. pytest's whole checklist is commented out,
# attrs and gentoo put their AI boxes after the comment closes.
TICKC=$(printf '%s\n' \
  'c.md:1	<!-- Here is a quick checklist that should be present in PRs.' \
  'c.md:5	- [ ] If AI agents were used, they are credited in `Co-authored-by` commit trailers.' \
  'c.md:9	-->' | awk -f "$ROOT/scripts/classify.awk" | awk -F'\t' '{print $1}')
is "a tick box inside a comment is not a rule" "DISCLOSE_SOFT" "$TICKC"
TICKV=$(printf '%s\n' \
  'v.md:1	<!-- Please describe your change above. -->' \
  'v.md:5	- [ ] If AI agents were used, they are credited in `Co-authored-by` commit trailers.' \
  | awk -f "$ROOT/scripts/classify.awk" | awk -F'\t' '{print $1}')
is "a tick box after the comment closes is a rule" "DISCLOSE" "$TICKV"
is "a tick box inside a one-line comment is not a rule" "DISCLOSE_SOFT" \
   "$(cls v.md:5 '<!-- - [ ] If AI agents were used, they are credited in `Co-authored-by` trailers. -->')"
# The state must not leak from one file into the next, or an unclosed comment in
# the first file would silence every tick box after it.
TICKR=$(printf '%s\n' \
  'a.md:1	<!-- checklist for the author' \
  'b.md:7	- [ ] I confirm any AI assistance is declared in the commit message.' \
  | awk -f "$ROOT/scripts/classify.awk" | awk -F'\t' '{print $1}')
is "comment state does not cross files" "DISCLOSE" "$TICKR"
# and the text inside a comment is still policy text
is "a ban inside a comment is still a ban" "FORBID" \
   "$(cls c.md:2 '<!-- AI-generated patches are not accepted in this project. -->')"
# the same two templates end to end, because the verdict is what a caller sees
is "a commented checklist reads GO"        "GO" \
   "$(verdict --file "$FIX/tickbox-commented.md")"
is "a visible checklist reads GO-DECLARE"  "GO-DECLARE" \
   "$(verdict --file "$FIX/tickbox-visible.md")"
has "the soft box is still quoted"         "DISCLOSE_SOFT" \
   "$(scan --file "$FIX/tickbox-commented.md")"

echo
echo "== other languages (offline) =="
# One fixture per language, read end to end, plus the classifier rules behind
# them. The pairing is the point: naming AI is not a rule, and a refusal with no
# AI word in it is about something else (the shield below).
is "german ban"     "STOP"       "$(verdict --file "$FIX/lang-de.md")"
is "french ban"     "STOP"       "$(verdict --file "$FIX/lang-fr.md")"
is "japanese ban"   "STOP"       "$(verdict --file "$FIX/lang-ja.md")"
is "spanish rule"   "GO-DECLARE" "$(verdict --file "$FIX/lang-es.md")"
is "russian rule"   "GO-DECLARE" "$(verdict --file "$FIX/lang-ru.md")"
is "chinese rule"   "GO-DECLARE" "$(verdict --file "$FIX/lang-zh.md")"

# The verdict has to be quoted in the language it was read in - a reason a
# maintainer cannot check against their own CONTRIBUTING.md is worth nothing.
has "the german sentence is quoted" "KI-generierter Code wird nicht akzeptiert" \
    "$(scan --file "$FIX/lang-de.md" --json | jq -r '.quotes[] | select(.class == "FORBID") | .text')"
has "the chinese sentence is quoted" "请在拉取请求中说明" \
    "$(scan --file "$FIX/lang-zh.md" --json | jq -r '.quotes[] | select(.class == "DISCLOSE") | .text')"

is "german ban is FORBID"      "FORBID"   "$(cls p.md:1 'KI-generierter Code wird nicht akzeptiert.')"
is "french ban is FORBID"      "FORBID"   "$(cls p.md:1 "Le code généré par une IA n'est pas accepté.")"
is "spanish ban is FORBID"     "FORBID"   "$(cls p.md:1 'No se aceptan contribuciones generadas con inteligencia artificial.')"
is "russian ban is FORBID"     "FORBID"   "$(cls p.md:1 'Код, написанный с помощью ИИ, не принимается.')"
is "japanese ban is FORBID"    "FORBID"   "$(cls p.md:1 '生成AIで書かれたコードは受け付けません。')"
is "chinese ban is FORBID"     "FORBID"   "$(cls p.md:1 '本项目不接受由人工智能生成的代码。')"
is "german disclosure"         "DISCLOSE" "$(cls p.md:1 'Die Nutzung von KI musst du im Pull Request angeben.')"
is "french disclosure"         "DISCLOSE" "$(cls p.md:1 "Merci d'indiquer dans la pull request si une IA vous a aidé.")"
is "spanish disclosure"        "DISCLOSE" "$(cls p.md:1 'Si usaste inteligencia artificial, debes indicarlo en el pull request.')"
is "russian disclosure"        "DISCLOSE" "$(cls p.md:1 'Если код написан с помощью ИИ, укажите это в описании.')"
is "japanese disclosure"       "DISCLOSE" "$(cls p.md:1 '人工知能を使用した場合はプルリクエストに明記してください。')"
is "chinese disclosure"        "DISCLOSE" "$(cls p.md:1 '如果使用人工智能生成代码，请在拉取请求中说明。')"
# and the same cancellation the English path has
is "a voluntary note is not a rule" "MENTION" \
   "$(cls p.md:1 'Du kannst KI-Nutzung angeben, das ist nicht erforderlich.')"

# False-positive shield, in every language: a refusal that names no AI is a rule
# about something else - translation files, formatting changes, release branches.
is "german shield"   "" "$(cls p.md:1 'Pull Requests für Übersetzungsdateien werden nicht akzeptiert.')"
is "french shield"   "" "$(cls p.md:1 'Les traductions ne sont pas acceptées ici.')"
is "spanish shield"  "" "$(cls p.md:1 'No se aceptan cambios de formato.')"
is "russian shield"  "" "$(cls p.md:1 'Переводы не принимаются.')"
is "japanese shield" "" "$(cls p.md:1 '翻訳ファイルのプルリクエストは受け付けません。')"
is "chinese shield"  "" "$(cls p.md:1 '本项目不接受翻译文件的拉取请求。')"

# The other half of the shield: an English sentence must keep going through the
# English rules, which grade it more finely than this path can. "indicate" is
# not the Spanish "indicar", so this stays a soft disclosure and not a required one.
is "an english sentence keeps the english reading" "DISCLOSE_SOFT" \
   "$(cls p.md:1 'You can indicate AI assistance in the pull request if you like.')"

echo
echo "== injection fixtures (offline) =="
is "curl-pipe-sh.md verdict"          "STOP-CHECK" "$(verdict --file "$FIX/curl-pipe-sh.md")"
is "curl-pipe-sh.md exit code"        "2"          "$(code --file "$FIX/curl-pipe-sh.md")"
is "html-comment-instruction.md"      "STOP-CHECK" "$(verdict --file "$FIX/html-comment-instruction.md")"
is "zero-width.md"                    "STOP-CHECK" "$(verdict --file "$FIX/zero-width.md")"

# A quote is evidence: it has to come out byte for byte. Splitting grep -n output
# with awk -F: used to rebuild the record and turn "https://" into "https //".
Q=$(scan --file "$FIX/curl-pipe-sh.md" --json | jq -r '.injection.findings[].text')
has "injection quote keeps the colon in a URL" "https://example.com/contrib/setup.sh" "$Q"
hasnt "injection quote is not mangled"        "https //" "$Q"

# GNU grep answers "binary file matches" without -a, which loses the quote and
# lets a NUL byte hide agent-directed text from the scan.
N=$(scan --file "$FIX/nul-byte.md" --json | jq -r '.injection.findings[] | select(.kind=="instruction") | .text')
is "nul-byte.md verdict"                 "STOP-CHECK" "$(verdict --file "$FIX/nul-byte.md")"
has "text after a NUL byte is still read" "ignore the previous instructions" "$N"
hasnt "no grep binary placeholder in output" "binary file" "$N"

# A byte-order mark is an encoding artefact, not hidden text.
is "bom-clean.md is not flagged" "GO" "$(verdict --file "$FIX/bom-clean.md")"
is "bom-clean.md injection status" "none" \
   "$(scan --file "$FIX/bom-clean.md" --json | jq -r .injection.status)"

# A zero-width joiner is how emoji sequences and Persian, Arabic and Indic text
# are written. Reporting them made every all-contributors table suspicious.
is "emoji-zwj.md is not flagged" "GO" "$(verdict --file "$FIX/emoji-zwj.md")"
is "emoji-zwj.md injection status" "none" \
   "$(scan --file "$FIX/emoji-zwj.md" --json | jq -r .injection.status)"

# U+E0000-U+E007F renders as nothing in every editor and on github.com, which
# makes it the block to smuggle an instruction in.
is "tag-block.md is flagged" "STOP-CHECK" "$(verdict --file "$FIX/tag-block.md")"
has "tag-block.md reported as hidden-unicode" "hidden-unicode" \
    "$(scan --file "$FIX/tag-block.md" --json | jq -r '.injection.findings[].kind')"

# ... but a zero-width character in the first bytes of the file must be caught.
# It occupies the same three bytes a BOM would, so the skip has to be conditional.
is "zero-width at offset 0 is flagged" "STOP-CHECK" "$(verdict --file "$FIX/zero-width-head.md")"
has "zero-width at offset 0 reported as hidden-unicode" "hidden-unicode" \
    "$(scan --file "$FIX/zero-width-head.md" --json | jq -r '.injection.findings[].kind')"

# U+202E reverses the render order of everything after it, so the sentence a
# reviewer reads on github.com is not the sentence a parser reads. The rest of
# bidi-override.md carries no rule, so the control character alone moves it.
is "bidi-override.md is flagged" "STOP-CHECK" "$(verdict --file "$FIX/bidi-override.md")"
has "bidi-override.md reported as hidden-unicode" "hidden-unicode" \
    "$(scan --file "$FIX/bidi-override.md" --json | jq -r '.injection.findings[].kind')"

# The other half of the screen: a finding that is only worth printing. A shell
# pipeline in a setup section and an opaque blob in a document are common and
# must not stop a contributor - they are quoted, and the verdict stands.
is "install-command.md stays GO"      "GO"      "$(verdict --file "$FIX/install-command.md")"
is "install-command.md is a notice"   "notice"  "$(scan --file "$FIX/install-command.md" --json | jq -r .injection.status)"
has "the pipeline is quoted"          "curl -fsSL https://example.org/install.sh | sh" \
    "$(scan --file "$FIX/install-command.md" --json | jq -r '.injection.findings[].text')"
is "encoded-blob.md stays GO"         "GO"      "$(verdict --file "$FIX/encoded-blob.md")"
is "encoded-blob.md is a notice"      "notice"  "$(scan --file "$FIX/encoded-blob.md" --json | jq -r .injection.status)"
is "both the base64 and the hex run are reported" "2" \
   "$(scan --file "$FIX/encoded-blob.md" --json | jq '[.injection.findings[] | select(.kind=="encoded-blob")] | length')"

# A base64 badge is in half the READMEs on github.com. data: URIs are stripped
# before the blob scan, or every project with a build badge gets a finding.
is "badge-data-uri.md injection status" "none" \
   "$(scan --file "$FIX/badge-data-uri.md" --json | jq -r .injection.status)"

# Addressing the agent is normal in AGENTS.md - Polars asks one to say so in the
# pull request. It is a finding only when the same line also tells the agent to
# run, install, fetch or hide something. Only the verdict-neutral half is
# asserted here; what the classifier makes of the text is a separate question.
is "an address with no action is not an injection finding" "none" \
   "$(scan --file "$FIX/agents-address.md" --json | jq -r .injection.status)"
is "an address with no action produces no finding" "0" \
   "$(scan --file "$FIX/agents-address.md" --json | jq '.injection.findings | length')"

# Every fixture that carries hidden or agent-directed text has to reach the same
# place: status suspicious, exit 2, and a quote a human can read.
for f in curl-pipe-sh html-comment-instruction zero-width zero-width-head tag-block bidi-override nul-byte; do
  is "$f.md is suspicious" "suspicious" "$(scan --file "$FIX/$f.md" --json | jq -r .injection.status)"
  is "$f.md exits 2"       "2"          "$(code --file "$FIX/$f.md")"
  is "$f.md quotes its finding" "true" \
     "$(scan --file "$FIX/$f.md" --json | jq '[.injection.findings[] | select(.text != "" and .text != null)] | length > 0')"
done

echo
echo "== hardening: hidden text, look-alikes, markup, phrasing (offline) =="
# Every one of these files carries a refusal a reader sees and a pattern would
# have missed. The rule has to be read (STOP with the sentence quoted), and the
# trick has to be reported where there is one.
for f in hidden-zwnj-word homoglyph-cyrillic fullwidth-ai html-split intraword-emphasis list-heading-items phrases-ban nul-mid-sentence; do
  is "$f.md is refused"        "STOP" "$(verdict --file "$FIX/$f.md")"
  is "$f.md quotes a FORBID"   "true" "$(scan --file "$FIX/$f.md" --json | jq '[.quotes[] | select(.class == "FORBID")] | length > 0')"
done
is "a zero-width joiner inside a word is reported"  "hidden-unicode" "$(scan --file "$FIX/hidden-zwnj-word.md" --json | jq -r '.injection.findings[0].kind')"
is "a Cyrillic look-alike inside a word is reported" "mixed-script" "$(scan --file "$FIX/homoglyph-cyrillic.md" --json | jq -r '.injection.findings[0].kind')"
is "a NUL byte is reported"                          "hidden-control" "$(scan --file "$FIX/nul-mid-sentence.md" --json | jq -r '.injection.findings[0].kind')"
has "the list heading is carried onto its items" "Not allowed: AI-generated pull requests" \
    "$(scan --file "$FIX/list-heading-items.md" --json | jq -r '.quotes[].text')"
is "phrases-ban.md: every sentence is a refusal" "5" \
   "$(scan --file "$FIX/phrases-ban.md" --json | jq '[.quotes[] | select(.class == "FORBID")] | length')"
# and the same shapes in innocent text stay innocent
is "a benign list heading is not a ban"   "GO"   "$(verdict --file "$FIX/list-heading-benign.md")"
is "a benign list heading is not flagged" "none" "$(scan --file "$FIX/list-heading-benign.md" --json | jq -r .injection.status)"
is "emoji joiners are still not flagged"  "none" "$(scan --file "$FIX/emoji-zwj.md" --json | jq -r .injection.status)"
is "a Russian refusal is still read as Russian" "STOP" "$(verdict --file "$FIX/lang-ru-ban.md")"
is "a Russian disclosure rule is still read as Russian" "GO-DECLARE" "$(verdict --file "$FIX/lang-ru.md")"
# a list of products with a comma after "Claude" is a list, not a vocative
is "a product list is not an address to an agent" "none" "$(scan --file "$FIX/product-list.md" --json | jq -r .injection.status)"
is "a product list still reads its own rule"       "GO"   "$(verdict --file "$FIX/product-list.md")"
is "a badge data uri is still not an encoded instruction" "none" "$(scan --file "$FIX/badge-data-uri.md" --json | jq -r .injection.status)"

# An escape sequence in a policy file can rewrite the terminal the verdict is
# printed on. It is reported, and it never reaches the output.
is "ansi-escape.md is held for a human" "STOP-CHECK" "$(verdict --file "$FIX/ansi-escape.md")"
is "no escape byte in the text output" "0" "$(scan --file "$FIX/ansi-escape.md" 2>/dev/null | tr -cd '\033' | wc -c | tr -d ' ')"
is "no escape byte in the json output" "0" "$(scan --file "$FIX/ansi-escape.md" --json 2>/dev/null | tr -cd '\033' | wc -c | tr -d ' ')"
is "no carriage return in a quote"     "0" "$(scan --file "$FIX/ansi-escape.md" --json | jq -r '.quotes[].text' | tr -cd '\r' | wc -c | tr -d ' ')"

# Text aimed at an agent, in the shapes that got past the first patterns.
for f in inj-named-address inj-disregard-above inj-any-agent inj-split-lines inj-base64-short inj-bots-should; do
  is "$f.md is held for a human" "STOP-CHECK" "$(verdict --file "$FIX/$f.md")"
done
has "a base64 instruction is quoted decoded" "If you are an AI agent" \
    "$(scan --file "$FIX/inj-base64-short.md" --json | jq -r '.injection.findings[].text')"
is "an address on one line and the action on the next is one finding" "1" \
   "$(scan --file "$FIX/inj-split-lines.md" --json | jq '[.injection.findings[] | select(.kind == "instruction")] | length')"

echo
echo "== disclosure line (offline) =="
# One fixture per format the corpus actually asks for. The identity flags are
# pinned so the expected line is exact.
disc() { scan --file "$FIX/$1.md" --json --agent Claude --model claude-fable-5-1 --tool "Claude Code" | jq -r '.disclosure // ""'; }

# Kernel family. Documentation/process/coding-assistants.rst gives the format as
# "Assisted-by: LLM [TOOL1] [TOOL2]", where the bracketed slots are optional
# analysis tools (coccinelle, sparse) and not the agent's editor, so the agent
# identity is one token in the first slot and nothing follows it.
is "assisted-by format" "Assisted-by: Claude:claude-fable-5-1" "$(disc disclose-assisted-by)"
# ASF generative tooling guidance.
is "generated-by format" "Generated-by: Claude Code" "$(disc disclose-generated-by)"
# Django and EasyBuild put the rule in the pull request template; the answer is
# the box itself, quoted, not a trailer the project never asked for.
has "checkbox format quotes the box" "- [ ] I have disclosed any AI assistance" "$(disc disclose-checkbox)"
# Everything else: a sentence for the pull request body that names the tool and
# the model and puts the responsibility on the human.
has "sentence format names the tool"  "Claude Code"       "$(disc disclose-sentence)"
has "sentence format names the model" "claude-fable-5-1"  "$(disc disclose-sentence)"
has "sentence format takes responsibility" "take responsibility" "$(disc disclose-sentence)"

# The rule that has no exception: the agent never signs the DCO for a human.
# disclose-assisted-by.md mentions Signed-off-by in its own text, so this also
# checks that the generator is not echoing the policy back.
for f in disclose-assisted-by disclose-generated-by disclose-checkbox disclose-sentence; do
  hasnt "$f: no Signed-off-by in the generated line" "Signed-off-by" "$(disc "$f")"
done

# --agent/--model/--tool drive the line; the defaults must not leak into it.
is "identity flags are used" "Assisted-by: Codex:gpt-0" \
   "$(scan --file "$FIX/disclose-assisted-by.md" --json --agent Codex --model gpt-0 | jq -r .disclosure)"

# A project that says no is not given a form of words to say it in.
is "no disclosure line on STOP" "" \
   "$(scan --file "$FIX/curl-pipe-sh.md" --json | jq -r '.disclosure // ""')"

# data/orgs.json is the other source of a disclosure line, so the same rule has
# to hold there - an organisation entry cannot smuggle a DCO trailer in.
is "no org disclosure line signs the DCO" "" \
   "$(jq -r '[.orgs[] | select(.disclosure_line | test("Signed-off-by"; "i")) | .id] | join(" ")' "$ROOT/data/orgs.json")"

echo
echo "== organisation inheritance (offline) =="
# org-silent.md is a contribution guide with no rule about tooling in it, so
# whatever comes out is what the owner in --owner brought. --owner is also how
# this is testable without a repository: it names the owner directly.
ORG="$ROOT/data/orgs.json"
org()  { scan --file "$FIX/${2:-org-silent}.md" --owner "$1" --json --agent Claude --model claude-fable-5-1 --tool "Claude Code"; }
orgv() { scan --file "$FIX/${2:-org-silent}.md" --owner "$1" --quiet; }

# ASF: the checklist case. A silent Apache project inherits the foundation's
# disclosure rule and the trailer its reviewers expect.
is "apache: silent repository inherits disclose" "GO-DECLARE" "$(orgv apache)"
is "apache: the verdict is sourced to the organisation" "org" "$(org apache | jq -r .stance.source)"
is "apache: disclosure line is the ASF trailer" "Generated-by: Claude Code" "$(org apache | jq -r .disclosure)"
is "apache: org_policy is marked applied" "true" "$(org apache | jq -r .org_policy.applied)"
has "apache: the reason carries the rule and its url" "generative-tooling.html" \
    "$(org apache | jq -r '.reasons | join(" ")')"
# An owner name is not case sensitive on GitHub and must not be here either
# (data/orgs.json spells one owner Mesa3D).
is "owner match is case insensitive" "GO-DECLARE" "$(orgv APACHE)"
is "mixed-case owner in the data file matches" "linux-kernel-family" \
   "$(org Mesa3D | jq -r .org_policy.id)"

# Kernel family: trailer and the DCO fact, which is the half that is not a stance.
is "zephyr: inherits the kernel trailer" "Assisted-by: Claude:claude-fable-5-1" \
   "$(org zephyrproject-rtos | jq -r .disclosure)"
is "zephyr: dco is inherited" "true" "$(org zephyrproject-rtos | jq -r .dco)"

# CNCF and Eclipse publish no AI rule. Their entries still carry a DCO or an
# agreement, and a silent repository under them stays a plain GO.
is "kubernetes: no AI rule inherited"  "GO"   "$(orgv kubernetes)"
is "kubernetes: org is not applied"    "false" "$(org kubernetes | jq -r .org_policy.applied)"
is "kubernetes: dco is inherited"      "true" "$(org kubernetes | jq -r .dco)"
is "eclipse: dco is inherited"         "true" "$(org eclipse | jq -r .dco)"
has "eclipse: the ECA is reported as the agreement" "Eclipse Contributor Agreement" \
    "$(org eclipse | jq -r '.cla // ""')"

# PSF allows AI work and still publishes a form of words, so the line is offered
# as a recommendation while the verdict stays GO.
is "python: allow does not become GO-DECLARE" "GO" "$(orgv python)"
has "python: the PSF wording is offered" "prepared with the help of Claude Code" \
    "$(org python | jq -r '.disclosure // ""')"
has "python: the line is marked as not required" "does not require a disclosure" \
    "$(org python | jq -r '.notes | join(" ")')"

# GNOME on github.com is a mirror that does not take pull requests.
is "gnome: silent repository stops"  "STOP" "$(orgv gnome)"
is "gnome: exit code"                "2"    "$(code --file "$FIX/org-silent.md" --owner gnome)"
has "gnome: the reason is the mirror, not an invented AI ban" "read-only mirror" \
    "$(org gnome | jq -r '.reasons | join(" ")')"

# The organisation rule is a default. A project that publishes its own rule
# decides, even when the foundation above it is more permissive.
is "repository text beats the organisation"   "STOP"  "$(orgv apache org-forbid)"
is "text verdict is sourced to the text"      "text"  "$(org apache org-forbid | jq -r .stance.source)"
is "org_policy is reported but not applied"   "false" "$(org apache org-forbid | jq -r .org_policy.applied)"

# An owner with no entry, and the switch that turns the whole file off.
is "unknown owner has no org policy" "null" "$(org no-such-owner-42 | jq -r '.org_policy // "null"')"
is "unknown owner is still scanned"  "GO"   "$(orgv no-such-owner-42)"
is "--no-org ignores data/orgs.json" "GO"   \
   "$(scan --file "$FIX/org-silent.md" --owner apache --no-org --quiet)"
is "--no-org drops the org policy"   "null" \
   "$(scan --file "$FIX/org-silent.md" --owner apache --no-org --json | jq -r '.org_policy // "null"')"

echo
echo "== data/orgs.json integrity =="
if jq -e . "$ORG" >/dev/null 2>&1; then ok "orgs.json is valid json"; else bad "orgs.json is valid json" "parseable" "parse error"; fi
# The six bodies the work order names have to be in the file.
for id in asf cncf gnome linux-kernel-family psf eclipse; do
  is "orgs.json has an entry: $id" "1" "$(jq --arg i "$id" '[.orgs[] | select(.id == $i)] | length' "$ORG")"
done
is "every entry is complete" "" \
   "$(jq -r '[.orgs[] | select((.id // "") == "" or (.name // "") == "" or ((.owners // []) | length) == 0
        or (.stance // "") == "" or (.rule // "") == "" or (.policy_url // "") == ""
        or (has("dco") | not) or (has("disclosure_line") | not)) | (.id // "?")] | join(" ")' "$ORG")"
is "every stance is one of the five" "" \
   "$(jq -r '[.orgs[] | select((["forbid","disclose","oversight","allow","silent"] | index(.stance)) == null) | .id] | join(" ")' "$ORG")"
# Two entries claiming the same owner would make the verdict depend on the order
# of the file (the lookup takes the first match).
is "no owner is claimed by two entries" "" \
   "$(jq -r '[.orgs[].owners[] | ascii_downcase] | group_by(.) | map(select(length > 1) | .[0]) | join(" ")' "$ORG")"
is "every policy_url is https" "" \
   "$(jq -r '[.orgs[] | select(.policy_url | startswith("https://") | not) | .id] | join(" ")' "$ORG")"
# A stance of disclose with no line would send the contributor away to guess.
is "a disclose stance carries a line" "" \
   "$(jq -r '[.orgs[] | select(.stance == "disclose" and (.disclosure_line | length) == 0) | .id] | join(" ")' "$ORG")"
# Only the three placeholders the script substitutes; anything else would be
# printed to the contributor verbatim.
is "only known placeholders are used" "" \
   "$(jq -r '[.orgs[] | select((.disclosure_line | [scan("\\{[a-z]+\\}")]) - ["{tool}","{agent}","{model}"] | length > 0) | .id] | join(" ")' "$ORG")"

echo
echo "== openness score (offline) =="
# The scale is graded on its own: openness.awk takes the five facts and prints
# SCORE<TAB>TEXT, so every step of it can be checked without a repository.
opn()  { awk -v archived="$1" -v has_prs="$2" -v policy="$3" -v total="$4" -v ext="$5" -v sample="$6" -v checked="$7" \
             -f "$ROOT/scripts/openness.awk"; }
opns() { opn "$@" | cut -f1; }
opnt() { opn "$@" | cut -f2; }

# A shut door is zero whatever the history says.
is "archived scores 0"            "0" "$(opns true false all 534 405 100 1)"
has "archived says why"           "archived" "$(opnt true false all 534 405 100 1)"
is "pull requests disabled score" "0" "$(opns false false all 534 405 100 1)"
is "collaborators_only scores 0"  "0" "$(opns false true collaborators_only 534 405 100 1)"
has "collaborators_only says why" "collaborators_only" "$(opnt false true collaborators_only 100 50 100 1)"

# Not read is not zero: --no-merges and a failed search must not look like a
# closed repository.
is "unread statistics score null" "null" "$(opns false true all null null null 0)"
has "unread statistics say so"    "not scored" "$(opnt false true all null null null 0)"

# The steps.
is "no merges at all"              "0"  "$(opns false true all 0 0 0 1)"
is "merges but none from outside"  "1"  "$(opns false true all 100 0 100 1)"
is "two outside merges"            "3"  "$(opns false true all 100 2 100 1)"
is "nine outside merges"           "5"  "$(opns false true all 100 9 100 1)"
is "ten outside merges, low share" "7"  "$(opns false true all 200 10 100 1)"
is "a fifth from outside adds one" "8"  "$(opns false true all 100 20 100 1)"
is "half from outside adds two"    "7"  "$(opns false true all 10 5 10 1)"
is "a busy open project"           "10" "$(opns false true all 534 405 100 1)"
is "the score is capped at ten"    "10" "$(opns false true all 1000 900 100 1)"
has "the counts are printed with the score" "external merges 90d: 405/534, sample 100" \
    "$(opnt false true all 534 405 100 1)"

# Local files have no repository to score.
is "local files are not scored" "null" \
   "$(scan --file "$FIX/org-silent.md" --json | jq -r '.openness.score // "null"')"
has "local files say why" "no repository" \
   "$(scan --file "$FIX/org-silent.md" --json | jq -r .openness.summary)"

echo
echo "== receipt (offline) =="
# The receipt is the evidence of a scan: the files that were read, their
# sha256, the verdict, the time and the version of the script. A second run
# with --receipt compares the hashes and says what moved.
RDIR="$OUT/receipt"
rm -rf "$RDIR"
mkdir -p "$RDIR"
cp "$FIX/org-silent.md" "$RDIR/policy.md"
RFILE="$RDIR/receipt.json"
rscan() { CONTRIB_POLICY_RECEIPT="$RFILE" scan --file "$RDIR/policy.md" --receipt "$@"; }

R1=$(rscan --json)
if [ -f "$RFILE" ]; then ok "the receipt file is written"; else bad "the receipt file is written" "$RFILE" "missing"; fi
is "the receipt is valid json" "true" "$(jq -e . "$RFILE" >/dev/null 2>&1 && echo true)"
is "first run reports a new receipt" "new" "$(printf '%s' "$R1" | jq -r .receipt.status)"
# What the addendum asks a receipt to carry.
for k in version ts verdict files; do
  is "the receipt carries: $k" "true" "$(jq --arg k "$k" 'has($k)' "$RFILE")"
done
is "the receipt hash is the file's sha256" "$(sha256sum "$RDIR/policy.md" | cut -c1-64)" \
   "$(jq -r '.files["policy.md"]' "$RFILE")"
is "the receipt holds the verdict" "GO" "$(jq -r .verdict "$RFILE")"
T1=$(jq -r .ts "$RFILE")

# Nothing changed: no warning, and the receipt points back at the first run.
R2=$(rscan --json)
is "an unchanged policy is reported unchanged" "unchanged" "$(printf '%s' "$R2" | jq -r .receipt.status)"
is "an unchanged policy lists no changes" "0" "$(printf '%s' "$R2" | jq '.receipt.changed | length')"
is "the previous timestamp is carried" "$T1" "$(printf '%s' "$R2" | jq -r .receipt.previous_ts)"
hasnt "no warning on an unchanged policy" "the policy changed" "$(printf '%s' "$R2" | jq -r '.notes | join(" ")')"

# The policy moves under the contributor: same file, different bytes, and the
# verdict flips with it.
printf '\nAI-generated code is not accepted in this project.\n' >> "$RDIR/policy.md"
R3=$(rscan --json)
is "a modified policy is reported changed" "changed" "$(printf '%s' "$R3" | jq -r .receipt.status)"
is "the changed file is named" "policy.md (changed)" "$(printf '%s' "$R3" | jq -r '.receipt.changed[0]')"
has "the warning says to read it again" "the policy changed since the receipt" \
    "$(printf '%s' "$R3" | jq -r '.notes | join(" ")')"
has "a changed verdict is called out" "GO -> STOP" "$(printf '%s' "$R3" | jq -r '.notes | join(" ")')"
is "the receipt was replaced with the new scan" "STOP" "$(jq -r .verdict "$RFILE")"

# A file that is no longer read has to be reported too - a project that deletes
# its AI_POLICY.md is a change of policy.
cp "$FIX/org-silent.md" "$RDIR/second.md"
CONTRIB_POLICY_RECEIPT="$RFILE" scan --file "$RDIR/policy.md" --file "$RDIR/second.md" --receipt --json >/dev/null
R4=$(rscan --json)
has "a file that disappeared is reported" "second.md (gone)" "$(printf '%s' "$R4" | jq -r '.receipt.changed | join(" ")')"

# A receipt written for another repository is not compared against, it is replaced.
# A receipt from before the host field existed is a github.com one, so the note
# names the target as github.com/other/repo.
printf '{"repo":"other/repo","ts":"2026-01-01T00:00:00Z","verdict":"GO","files":{}}\n' > "$RFILE"
R5=$(rscan --json)
is "a receipt for another target is replaced" "other-target" "$(printf '%s' "$R5" | jq -r .receipt.status)"
has "replacing it is said out loud" "written for github.com/other/repo" "$(printf '%s' "$R5" | jq -r '.notes | join(" ")')"

# The same path on two forges is two projects, and a receipt for one is not a
# receipt for the other.
printf '{"repo":"o/r","host":"codeberg.org","ts":"2026-01-01T00:00:00Z","verdict":"GO","files":{}}\n' > "$RFILE"
R5B=$(rscan --json)
is "a receipt from another host is replaced" "other-target" "$(printf '%s' "$R5B" | jq -r .receipt.status)"
has "the other host is named" "written for codeberg.org/o/r" "$(printf '%s' "$R5B" | jq -r '.notes | join(" ")')"

# Without the flag there is no receipt and no receipt section.
is "no receipt without --receipt" "null" \
   "$(scan --file "$FIX/org-silent.md" --json | jq -r '.receipt // "null"')"

# The default path is the one the work order names, relative to where the
# contributor is standing - normally the clone they are about to open a pull
# request from. The directory is created if it is not there.
( cd "$RDIR" && bash "$SCAN" --file policy.md --receipt --quiet ) >/dev/null 2>&1
if [ -f "$RDIR/.contrib-policy/receipt.json" ]; then ok "the default receipt path is .contrib-policy/receipt.json"
else bad "the default receipt path is .contrib-policy/receipt.json" "written" "missing"; fi
has "the default receipt holds the scan" "policy.md" \
    "$(jq -r '.files | keys | join(" ")' "$RDIR/.contrib-policy/receipt.json" 2>/dev/null)"
has "the text output names the receipt and its state" "receipt: $RFILE (unchanged)" \
    "$(CONTRIB_POLICY_RECEIPT="$RFILE" scan --file "$RDIR/policy.md" --receipt)"
has "the first write suggests a gitignore line" "add .contrib-policy/ to .gitignore" \
    "$(CONTRIB_POLICY_RECEIPT="$RDIR/fresh.json" scan --file "$RDIR/policy.md" --receipt)"

echo
echo "== rate limits and cache (offline) =="
# scripts/ratelimit.sh is sourced by the scanner; here it is sourced on its own
# so the arithmetic can be graded without a host that says 429.
RL="$OUT/ratelimit"; rm -rf "$RL"; mkdir -p "$RL"
rl() { # rl ENV... -- FUNCTION ARGS...: run one helper in a fresh shell, print stdout and "rc=N"
  ( WORK="$RL"; TIMEOUT=5; HOST=example.org
    while [ "$1" != -- ]; do export "$1"; shift; done; shift
    . "$ROOT/scripts/ratelimit.sh"
    out=$("$@"); rc=$?; printf '%s rc=%s' "$out" "$rc" )
}
printf 'HTTP/2 429\r\nretry-after: 3\r\n' > "$RL/h-retry-after"
printf 'HTTP/2 403\r\nx-ratelimit-remaining: 0\r\nx-ratelimit-reset: %s\r\n' "$(( $(date +%s) + 7 ))" > "$RL/h-reset-soon"
printf 'HTTP/2 403\r\nx-ratelimit-remaining: 0\r\nx-ratelimit-reset: %s\r\n' "$(( $(date +%s) + 3600 ))" > "$RL/h-reset-far"
printf 'HTTP/2 403\r\nx-ratelimit-remaining: 4321\r\n' > "$RL/h-forbidden"
printf 'HTTP/2 429\r\nRateLimit-Reset: 12\r\n' > "$RL/h-gitlab-delta"
printf 'HTTP/2 500\r\n' > "$RL/h-none"
is "429 is a limit"                          " rc=0" "$(rl -- limited 429 "$RL/h-forbidden")"
is "403 with the bucket empty is a limit"    " rc=0" "$(rl -- limited 403 "$RL/h-reset-soon")"
is "403 with budget left is a refusal"       " rc=1" "$(rl -- limited 403 "$RL/h-forbidden")"
is "200 is not a limit"                      " rc=1" "$(rl -- limited 200 "$RL/h-forbidden")"
is "Retry-After is the wait"                 "3 rc=0"  "$(rl -- retry_wait 1 "$RL/h-retry-after")"
has "X-RateLimit-Reset (epoch) becomes a delta" " rc=0" "$(rl -- retry_wait 1 "$RL/h-reset-soon")"
W=$(rl -- retry_wait 1 "$RL/h-reset-soon" | cut -d' ' -f1)
is "the delta is close to the reset"         "true" "$([ "$W" -ge 6 ] && [ "$W" -le 9 ] && echo true)"
is "a small RateLimit-Reset is taken as seconds" "12 rc=0" "$(rl -- retry_wait 1 "$RL/h-gitlab-delta")"
is "no header: linear backoff"               "4 rc=0"  "$(rl -- retry_wait 2 "$RL/h-none")"
has "a reset an hour away is refused"        " rc=1"   "$(rl -- retry_wait 1 "$RL/h-reset-far")"
has "the refusal still says how long"        "36"      "$(rl -- retry_wait 1 "$RL/h-reset-far")"
is "the ceiling is configurable"             "3 rc=1"  "$(rl CONTRIB_POLICY_MAX_WAIT=2 -- retry_wait 1 "$RL/h-retry-after")"
is "a bad ceiling falls back to the default" "3 rc=0"  "$(rl CONTRIB_POLICY_MAX_WAIT=abc -- retry_wait 1 "$RL/h-retry-after")"
# Retry-After may be an http-date (RFC 7231); a date far off is refused, a date
# a few seconds off is waited for, and a date this date cannot read is a plain backoff
printf 'HTTP/2 429\r\nretry-after: Thu, 01 Jan 2099 00:00:00 GMT\r\n' > "$RL/h-date-far"
printf 'HTTP/2 429\r\nretry-after: %s\r\n' "$(date -u -d '5 seconds' '+%a, %d %b %Y %H:%M:%S GMT' 2>/dev/null || echo 'not a date')" > "$RL/h-date-soon"
if date -d 'Thu, 01 Jan 2099 00:00:00 GMT' +%s >/dev/null 2>&1; then
  has "an http-date far away is refused" " rc=1" "$(rl -- retry_wait 1 "$RL/h-date-far")"
else
  is "an unreadable http-date is a backoff" "2 rc=0" "$(rl -- retry_wait 1 "$RL/h-date-far")"
fi
has "an http-date a few seconds off is waited for" " rc=0" "$(rl -- retry_wait 1 "$RL/h-date-soon")"
is "403 with Retry-After is a limit (secondary limit)" " rc=0" "$(rl -- limited 403 "$RL/h-date-soon")"

# The state has to survive $(...): the scanner calls http_get and gh_api inside
# command substitutions, so a variable set there would be lost. A fake curl
# that always answers 429 shows the parent shell still learns about it, and
# that the host is not asked a second time.
mkdir -p "$RL/bin"
cat > "$RL/bin/curl" <<'EOF'
#!/bin/sh
hdr=""; out=""
while [ $# -gt 0 ]; do case "$1" in -D) hdr=$2; shift ;; -o) out=$2; shift ;; esac; shift; done
echo x >> "${CURL_STUB_CALLS:?}"
printf 'HTTP/2 429\r\nretry-after: 99\r\n' > "$hdr"; : > "$out"; printf '429'
EOF
cat > "$RL/bin/gh" <<'EOF'
#!/bin/sh
case "$*" in *rate_limit*) exit 0 ;; esac
n=$(cat "${GH_STUB_COUNT:?}" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$GH_STUB_COUNT"
if [ "$n" = 1 ]; then printf '{"message":"API rate limit exceeded"}'; echo "gh: API rate limit exceeded for user (HTTP 403)" >&2; exit 1; fi
printf '{"ok":true}'
EOF
chmod +x "$RL/bin/curl" "$RL/bin/gh"
: > "$RL/calls"
is "a limit met inside \$(...) reaches the caller" "429 example.org 99 rc=0" \
   "$(rl PATH="$RL/bin:$PATH" CURL_STUB_CALLS="$RL/calls" CONTRIB_POLICY_RETRIES=0 CONTRIB_POLICY_MIN_GAP_MS=0 -- \
      eval 'code=$(http_get https://example.org/a "$RL/o"); code2=$(http_get https://example.org/b "$RL/o"); rl_load example.org; printf "%s %s %s" "$code" "$RATE_LIMITED" "$RATE_LIMITED_WAIT"')"
is "the host is not asked again after the limit" "1" "$(wc -l < "$RL/calls" | tr -d ' ')"
is "another host is still asked" "2" \
   "$(rl PATH="$RL/bin:$PATH" CURL_STUB_CALLS="$RL/calls" CONTRIB_POLICY_RETRIES=0 CONTRIB_POLICY_MIN_GAP_MS=0 -- \
      eval 'http_get https://other.example/a "$RL/o" >/dev/null; wc -l < "$RL/calls" | tr -d " "' | cut -d' ' -f1)"
rm -f "$RL/ghn"
is "gh_api prints only the successful answer" '{"ok":true} rc=0' \
   "$(rl PATH="$RL/bin:$PATH" GH_STUB_COUNT="$RL/ghn" CONTRIB_POLICY_MIN_GAP_MS=0 -- gh_api repos/o/r)"
# the throttle: two requests in a row are at least MIN_GAP_MS apart
T0=$(date +%s%N 2>/dev/null); case "$T0" in ''|*[!0-9]*) T0="" ;; esac
if [ -n "$T0" ]; then
  rl CONTRIB_POLICY_MIN_GAP_MS=300 -- eval 'throttle; throttle' >/dev/null
  T1=$(date +%s%N); GAP=$(( (T1 - T0) / 1000000 ))
  is "throttle keeps requests apart" "true" "$([ "$GAP" -ge 300 ] && echo true)"
  rl CONTRIB_POLICY_MIN_GAP_MS=0 -- eval 'throttle; throttle' >/dev/null
  T2=$(date +%s%N); GAP=$(( (T2 - T1) / 1000000 ))
  is "MIN_GAP_MS=0 turns the throttle off" "true" "$([ "$GAP" -lt 300 ] && echo true)"
else
  skip "throttle timing" "date has no %N"
fi
# a host that never answers is retried and then reported, not turned into a verdict
is "no answer is 000 after the retries" "000 rc=0" \
   "$(rl CONTRIB_POLICY_RETRIES=1 CONTRIB_POLICY_MIN_GAP_MS=0 -- http_get https://127.0.0.1:9/x "$RL/out")"
# --help has to say all of this
has "--help names the cache"     "CONTRIB_POLICY_CACHE"   "$(scan --help)"
has "--help names the retries"   "CONTRIB_POLICY_RETRIES" "$(scan --help)"
has "--help names the ceiling"   "CONTRIB_POLICY_MAX_WAIT" "$(scan --help)"
has "--help ends at the exit codes" "exit codes" "$(scan --help)"

echo
echo "== other hosts: target parsing (offline) =="
# --dry-run prints HOST<TAB>PATH<TAB>KIND and stops before any network call, so
# the rule that decides which API is asked can be graded on its own. The rule:
# a first segment with a dot in it is a host name, because a github.com owner
# name never has one.
tgt() { scan --dry-run "$@"; }
is "a bare owner/repo is github.com" "$(printf 'github.com\towner/repo\tgithub')" "$(tgt owner/repo)"
is "a dotted first segment is a host" "$(printf 'gitlab.com\tgroup/project\tgitlab')" "$(tgt gitlab.com/group/project)"
is "gitlab groups nest" "$(printf 'gitlab.gnome.org\tWorld/gedit/gedit\tgitlab')" "$(tgt gitlab.gnome.org/World/gedit/gedit)"
is "codeberg.org runs gitea" "$(printf 'codeberg.org\tEtchedPixels/EmulatorKit\tgitea')" "$(tgt codeberg.org/EtchedPixels/EmulatorKit)"
is "salsa.debian.org runs gitlab" "$(printf 'salsa.debian.org\tdebian/hello\tgitlab')" "$(tgt salsa.debian.org/debian/hello)"
# the forms a contributor actually pastes: a url from the browser's address bar
is "a gitlab blob url is cut back to the project" "$(printf 'gitlab.gnome.org\tGNOME/libadwaita\tgitlab')" \
   "$(tgt https://gitlab.gnome.org/GNOME/libadwaita/-/blob/main/CONTRIBUTING.md)"
is "a gitea source url is cut back to the project" "$(printf 'codeberg.org\to/r\tgitea')" \
   "$(tgt https://codeberg.org/o/r/src/branch/main/CONTRIBUTING.md)"
is "a github blob url is cut back to the project" "$(printf 'github.com\to/r\tgithub')" \
   "$(tgt https://github.com/o/r/blob/main/AGENTS.md)"
is "a clone url loses its .git" "$(printf 'codeberg.org\to/r\tgitea')" "$(tgt https://codeberg.org/o/r.git)"
is "a trailing slash is dropped" "$(printf 'gitlab.com\tg/p\tgitlab')" "$(tgt https://gitlab.com/g/p/)"
# a self-hosted instance the host name says nothing about
is "--host and --kind name an unknown instance" "$(printf 'git.example.org\to/r\tgitea')" \
   "$(tgt --host git.example.org --kind gitea o/r)"
is "an unplaceable host is refused" "3" "$(code --dry-run git.example.org/o/r)"
has "an unplaceable host says what to pass" "pass --kind github|gitlab|gitea" \
    "$(scan --dry-run git.example.org/o/r 2>&1)"
is "a made-up kind is refused" "3" "$(code --dry-run --kind svn gitlab.com/g/p)"
is "github.com takes exactly owner/repo" "3" "$(code --dry-run owner/repo/extra)"
# the project path is a directory under the cache as well as a url
is "a dot-dot segment is refused"     "3" "$(code --dry-run 'gitlab.com/g/../p')"
is "a lone dot segment is refused"    "3" "$(code --dry-run 'gitlab.com/./p')"
is "a dot inside a name is fine"      "$(printf 'github.com\to/r.js\tgithub')" "$(tgt o/r.js)"
is "a path with no project is refused" "3" "$(code --dry-run gitlab.com/onlygroup)"
is "local files have no host" "$(printf 'local\tlocal files\tlocal')" "$(tgt --file "$FIX/org-silent.md")"
is "local files report no host in json" "null" "$(scan --file "$FIX/org-silent.md" --json | jq -r '.host // "null"')"

echo
echo "== other hosts: the same pipeline (offline fixtures) =="
# What the other two forges serve that github.com does not: GIMP keeps its only
# AI rule inside an html comment in .gitlab/merge_request_templates/default.md,
# and EmulatorKit on Codeberg writes the tool's name with a hyphen.
is "a gitlab merge request template is read" "STOP" "$(verdict --file "$FIX/gitlab-mr-template.md")"
has "the merge request template is quoted" "No AI-generated contents allowed" \
    "$(scan --file "$FIX/gitlab-mr-template.md" --json | jq -r '.quotes[] | select(.class == "FORBID") | .text')"
is "a codeberg rules file is read" "STOP" "$(verdict --file "$FIX/forge-copilot-rules.md")"
is "co-pilot with a hyphen is an AI word" "FORBID" \
   "$(cls ContributionRules:3 'Microsoft co-pilot laundered code is not accepted in this project')"

echo
echo "== pull request gate hook (offline) =="
# hooks/pr_gate.sh is what Claude Code runs before a tool call. It is fed the
# tool call as json on stdin and answers with a PreToolUse decision. No Claude
# Code is needed to grade it: the payloads below are what the harness sends.
HOOK="$ROOT/hooks/pr_gate.sh"
HDIR="$OUT/hook"
rm -rf "$HDIR"; mkdir -p "$HDIR"

PR_BASH='{"tool_name":"Bash","tool_input":{"command":"gh pr create --fill"},"cwd":"."}'
PR_GLAB='{"tool_name":"Bash","tool_input":{"command":"glab mr create --fill"},"cwd":"."}'
PR_CHAIN='{"tool_name":"Bash","tool_input":{"command":"cd /tmp/work && gh pr create -t x -b y"},"cwd":"."}'
PR_MCP='{"tool_name":"mcp__github__create_pull_request","tool_input":{"owner":"o","repo":"r","title":"x"},"cwd":"."}'
NOT_PR='{"tool_name":"Bash","tool_input":{"command":"gh pr list --limit 5"},"cwd":"."}'
PR_OTHER='{"tool_name":"Bash","tool_input":{"command":"gh pr create --repo other/project --fill"},"cwd":"."}'

gate()    { printf '%s' "$2" | CONTRIB_POLICY_RECEIPT="$1" bash "$HOOK" | jq -r '.hookSpecificOutput.permissionDecision // ""'; }
greason() { printf '%s' "$2" | CONTRIB_POLICY_RECEIPT="$1" bash "$HOOK" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'; }

# Receipts written by the scanner itself, not by hand: the hook has to read what
# --receipt actually produces.
CONTRIB_POLICY_RECEIPT="$HDIR/go.json"      scan --file "$FIX/org-silent.md" --receipt --json >/dev/null
CONTRIB_POLICY_RECEIPT="$HDIR/declare.json" scan --file "$FIX/disclose-assisted-by.md" --receipt --json \
  --agent Claude --model claude-fable-5-1 >/dev/null
CONTRIB_POLICY_RECEIPT="$HDIR/stop.json"    scan --file "$FIX/lang-de.md" --receipt --json >/dev/null
is "the GO receipt was written"      "GO"         "$(jq -r .verdict "$HDIR/go.json")"
is "the GO-DECLARE receipt was written" "GO-DECLARE" "$(jq -r .verdict "$HDIR/declare.json")"
is "the STOP receipt was written"    "STOP"       "$(jq -r .verdict "$HDIR/stop.json")"

# Anything that is not a pull request passes without a word. `gh pr list` is the
# case that matters: a gate that fires on every gh call gets turned off.
is "a command that is not a pull request is untouched" "" "$(gate "$HDIR/go.json" "$NOT_PR")"
is "a shell command is untouched"                      "" \
   "$(gate "$HDIR/go.json" '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"cwd":"."}')"
is "a Read call is untouched" "" \
   "$(gate "$HDIR/go.json" '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"},"cwd":"."}')"

# GO: the project allows it and the receipt is fresh, so the gate stays out of
# the way. The other verdicts each get their own answer.
is "GO lets the pull request through"    ""     "$(gate "$HDIR/go.json" "$PR_BASH")"
is "STOP blocks the pull request"        "deny" "$(gate "$HDIR/stop.json" "$PR_BASH")"
has "STOP says why"  "AI-assisted contributions are not accepted" "$(greason "$HDIR/stop.json" "$PR_BASH")"
is "GO-DECLARE asks a human"             "ask"  "$(gate "$HDIR/declare.json" "$PR_BASH")"
has "GO-DECLARE hands over the exact line" "Assisted-by: Claude:claude-fable-5-1" \
    "$(greason "$HDIR/declare.json" "$PR_BASH")"
# the other two ways to open one
is "glab mr create is gated"             "deny" "$(gate "$HDIR/stop.json" "$PR_GLAB")"
is "a pull request behind a cd is gated" "deny" "$(gate "$HDIR/stop.json" "$PR_CHAIN")"
is "an mcp pull request tool is gated"   "deny" "$(gate "$HDIR/stop.json" "$PR_MCP")"
# ... and the raw API behind the subcommand, which never says "pr create"
PR_API='{"tool_name":"Bash","tool_input":{"command":"gh api repos/o/r/pulls -f title=x -f head=b -f base=main"},"cwd":"."}'
PR_API_POST='{"tool_name":"Bash","tool_input":{"command":"gh api -X POST repos/o/r/pulls --input body.json"},"cwd":"."}'
PR_API_GET='{"tool_name":"Bash","tool_input":{"command":"gh api repos/o/r/pulls?state=open"},"cwd":"."}'
is "gh api ... /pulls -f is gated"        "deny" "$(gate "$HDIR/stop.json" "$PR_API")"
is "gh api -X POST ... /pulls is gated"   "deny" "$(gate "$HDIR/stop.json" "$PR_API_POST")"
is "gh api reading /pulls is untouched"   ""     "$(gate "$HDIR/stop.json" "$PR_API_GET")"
is "gh api -X GET with query fields is untouched" "" \
   "$(gate "$HDIR/stop.json" '{"tool_name":"Bash","tool_input":{"command":"gh api -X GET repos/o/r/pulls -f state=open -f per_page=100"},"cwd":"."}')"
is "glab api ... /merge_requests -f is gated" "deny" \
   "$(gate "$HDIR/stop.json" '{"tool_name":"Bash","tool_input":{"command":"glab api projects/123/merge_requests -f source_branch=b -f target_branch=main -f title=x"},"cwd":"."}')"
is "a graphql createPullRequest mutation is gated" "deny" \
   "$(gate "$HDIR/stop.json" '{"tool_name":"Bash","tool_input":{"command":"gh api graphql -f query='"'"'mutation { createPullRequest(input: {repositoryId: \"x\"}) { pullRequest { id } } }'"'"'"},"cwd":"."}')"
is "a tab between gh and pr is still a pull request" "deny" \
   "$(gate "$HDIR/stop.json" '{"tool_name":"Bash","tool_input":{"command":"gh\tpr\tcreate --fill"},"cwd":"."}')"

# No receipt at all is the case the hook exists for.
is "no receipt blocks the pull request" "deny" "$(gate "$HDIR/absent.json" "$PR_BASH")"
has "no receipt says how to make one" "--receipt" "$(greason "$HDIR/absent.json" "$PR_BASH")"
printf 'not json\n' > "$HDIR/broken.json"
is "an unreadable receipt blocks" "deny" "$(gate "$HDIR/broken.json" "$PR_BASH")"
printf '{"verdict":"UNKNOWN","repo":"o/r","files":{}}\n' > "$HDIR/unknown.json"
is "an UNKNOWN verdict blocks" "deny" "$(gate "$HDIR/unknown.json" "$PR_BASH")"

# A policy can change between two pull requests, so a receipt has a shelf life.
cp "$HDIR/go.json" "$HDIR/stale.json"
touch -d '3 days ago' "$HDIR/stale.json" 2>/dev/null || touch -t 202501010000 "$HDIR/stale.json"
is "a stale receipt blocks"   "deny"  "$(gate "$HDIR/stale.json" "$PR_BASH")"
has "a stale receipt says so" "older than" "$(greason "$HDIR/stale.json" "$PR_BASH")"
is "the shelf life is configurable" "" \
   "$(printf '%s' "$PR_BASH" | CONTRIB_POLICY_RECEIPT="$HDIR/stale.json" CONTRIB_POLICY_MAX_AGE_H=99999 \
      bash "$HOOK" | jq -r '.hookSpecificOutput.permissionDecision // ""')"

# A receipt for one project says nothing about another.
jq '.repo = "o/r" | .verdict = "GO"' "$HDIR/go.json" > "$HDIR/repo.json"
is "a receipt for another repository blocks" "deny" "$(gate "$HDIR/repo.json" "$PR_OTHER")"
has "it names both sides" "other/project" "$(greason "$HDIR/repo.json" "$PR_OTHER")"
is "the same repository passes" "" \
   "$(gate "$HDIR/repo.json" '{"tool_name":"Bash","tool_input":{"command":"gh pr create --repo o/r --fill"},"cwd":"."}')"
# the same check on the mcp side, where the repository is in the arguments and
# not in a command line: owner/repo is o/r in the receipt, other/project here
is "an mcp call for another repository blocks" "deny" \
   "$(gate "$HDIR/repo.json" '{"tool_name":"mcp__github__create_pull_request","tool_input":{"owner":"other","repo":"project","title":"x"},"cwd":"."}')"
is "an mcp call for the same repository passes" "" "$(gate "$HDIR/repo.json" "$PR_MCP")"

# The command text can be written many ways. The ones a hook can still read:
for c in $'gh pr\ncreate --fill' '/usr/bin/gh pr create --fill' 'gh p"r" create --fill' "gh pr cre''ate --fill" \
         'curl -X POST -H "Authorization: token x" https://api.github.com/repos/o/r/pulls -d "{}"' \
         'python3 -c "import requests;requests.post(\"https://api.github.com/repos/o/r/pulls\")"' \
         'gh api graphql -F query=@mutation.graphql' 'gh api --method=POST repos/o/r/pulls -f title=x'; do
  is "gated: ${c:0:44}" "deny" \
     "$(jq -cn --arg c "$c" '{tool_name:"Bash",tool_input:{command:$c},cwd:"."}' | CONTRIB_POLICY_RECEIPT="$HDIR/stop.json" bash "$HOOK" | jq -r '.hookSpecificOutput.permissionDecision // ""')"
done
for c in 'curl -s https://api.github.com/repos/o/r/pulls?state=open' "gh api graphql -f query='{ viewer { login } }'" 'gh api -X GET repos/o/r/pulls -f state=open'; do
  is "not gated: ${c:0:44}" "" \
     "$(jq -cn --arg c "$c" '{tool_name:"Bash",tool_input:{command:$c},cwd:"."}' | CONTRIB_POLICY_RECEIPT="$HDIR/stop.json" bash "$HOOK" | jq -r '.hookSpecificOutput.permissionDecision // ""')"
done
# a payload that is not json, or whose tool_input is a bare string, does not become an allow
is "a non-json payload that names a pull request is denied" "deny" \
   "$(printf 'tool: Bash, command: gh pr create --fill' | CONTRIB_POLICY_RECEIPT="$HDIR/stop.json" bash "$HOOK" | jq -r '.hookSpecificOutput.permissionDecision // ""')"
is "a non-json payload with no pull request in it is left alone" "" \
   "$(printf 'not json' | CONTRIB_POLICY_RECEIPT="$HDIR/stop.json" bash "$HOOK")"
is "tool_input as a bare string is still read" "deny" \
   "$(printf '%s' '{"tool_name":"Bash","tool_input":"gh pr create","cwd":"."}' | CONTRIB_POLICY_RECEIPT="$HDIR/stop.json" bash "$HOOK" | jq -r '.hookSpecificOutput.permissionDecision // ""')"
# a receipt written for local files says nothing about a named repository
is "a local-files receipt does not cover -R other/repo" "deny" \
   "$(gate "$HDIR/go.json" '{"tool_name":"Bash","tool_input":{"command":"gh pr create -R other/repo --fill"},"cwd":"."}')"
is "a gh api call names its repository too" "deny" \
   "$(gate "$HDIR/repo.json" '{"tool_name":"Bash","tool_input":{"command":"gh api repos/other/project/pulls -f title=x"},"cwd":"."}')"

# Without jq the payload cannot be read at all. A gate that fails open there is
# not a gate; one that fails closed on every tool call is a broken session. It
# has to do both: closed for a pull request, open for everything else.
is "no jq blocks a pull request" "deny" \
   "$(printf '%s' "$PR_BASH" | CONTRIB_POLICY_JQ=/nonexistent/jq bash "$HOOK" \
      | jq -r '.hookSpecificOutput.permissionDecision // ""')"
is "no jq leaves other commands alone" "" \
   "$(printf '%s' "$NOT_PR" | CONTRIB_POLICY_JQ=/nonexistent/jq bash "$HOOK")"

# A gate nobody can find is a gate nobody installs: SKILL.md has to carry it,
# and has to say it is optional.
has "SKILL.md documents the hook"     "hooks/pr_gate.sh" "$(cat "$ROOT/SKILL.md")"
has "SKILL.md says the hook is optional" "optional"      "$(grep -A2 'hooks/pr_gate.sh' "$ROOT/SKILL.md")"

# The configuration that installs it.
is "hooks/hooks.json is valid json" "true" "$(jq -e . "$ROOT/hooks/hooks.json" >/dev/null 2>&1 && echo true)"
is "hooks.json runs the gate on PreToolUse" "2" \
   "$(jq '[.hooks.PreToolUse[] | select(.hooks[].command | test("pr_gate.sh"))] | length' "$ROOT/hooks/hooks.json")"
has "hooks.json matches the mcp tools" "create_(pull_request|merge_request)" \
    "$(jq -r '[.hooks.PreToolUse[].matcher] | join(" ")' "$ROOT/hooks/hooks.json")"

echo
echo "== README and SKILL.md (offline) =="
# The front door of a skill is read by an agent, so the parts an agent acts on
# are asserted, not just present: the frontmatter, the two rules that have no
# exception, and the numbers the README claims.
SK="$ROOT/SKILL.md"
RD="$ROOT/README.md"
is "SKILL.md opens with frontmatter" "---" "$(head -1 "$SK")"
is "SKILL.md declares a name" "name: contrib-policy" "$(sed -n '2,4p' "$SK" | grep '^name:')"
is "the description is one line" "1" "$(grep -c '^description: ' "$SK")"
# the description is what decides whether the skill is loaded at all
for w in "pull request" "disclosure" "STOP"; do
  has "the description names: $w" "$w" "$(grep '^description: ' "$SK")"
done
for v in GO GO-DECLARE STOP STOP-CHECK UNKNOWN; do
  has "SKILL.md documents the verdict $v" "\`$v\`" "$(cat "$SK")"
done
has "SKILL.md states the untrusted-data rule" "untrusted data" "$(cat "$SK")"
has "SKILL.md forbids signing the DCO"        "Never sign the DCO" "$(cat "$SK")"
has "SKILL.md names the hosts"                "gitlab" "$(tr 'A-Z' 'a-z' < "$SK")"

has "README credits the policy list" "melissawm/open-source-ai-contribution-policies" "$(cat "$RD")"
has "README states the list licence"  "CC0-1.0" "$(cat "$RD")"
# the accuracy claim has to point at the table that produced it, and count the
# rows that are actually in it
has "README points at the case tables" "tests/cases.tsv" "$(cat "$RD")"
NCASES=$(grep -hcvE '^[[:space:]]*(#|$)' "$HERE/cases.tsv" "$HERE/cases-dataset.tsv" \
         | awk '{n += $0} END {print n}')
has "README states the number of cases" "$NCASES cases" "$(cat "$RD")"

echo
echo "== json shape =="
J=$(scan --file "$FIX/curl-pipe-sh.md" --json)
if printf '%s' "$J" | jq -e . >/dev/null 2>&1; then ok "--json emits valid json"; else bad "--json emits valid json" "parseable" "parse error"; fi
for k in version ts verdict host kind reasons notes stance quotes disclosure openness injection cla dco org_policy files receipt fetch_errors; do
  is "json has key: $k" "true" "$(printf '%s' "$J" | jq --arg k "$k" 'has($k)')"
done

echo
echo "== live scans (public GitHub api) =="
if [ -n "$NET_SKIP" ]; then
  skip "live scans" "$NET_SKIP"
else
  # --no-merges keeps these deterministic: merge counts move from day to day.
  is "ghostty-org/ghostty verdict"  "GO-DECLARE" "$(verdict --no-merges ghostty-org/ghostty)"
  is "kysely-org/kysely verdict"    "STOP"       "$(verdict --no-merges kysely-org/kysely)"
  is "gradio-app/gradio verdict"    "STOP"       "$(verdict --no-merges gradio-app/gradio)"

  G=$(scan --no-merges --json ghostty-org/ghostty)
  has "ghostty quotes AI_POLICY.md" "AI_POLICY.md" "$(printf '%s' "$G" | jq -r '.quotes[].at')"
  is  "ghostty files are hashed"    "true"        "$(printf '%s' "$G" | jq '(.files|length) > 0')"
  # what a second scan within a day reads instead of asking github again
  GC="$OUT/cache/github.com/ghostty-org/ghostty"
  is "the repository metadata is cached" "true" "$([ -s "$GC/_meta.json" ] && jq -e .default_branch "$GC/_meta.json" >/dev/null && echo true)"
  is "the tree listing is cached"        "true" "$([ -s "$GC/$(jq -r .default_branch "$GC/_meta.json" | tr / _)/_tree.txt" ] && echo true)"

  # The organisation case end to end: commons-lang says nothing about AI, so the
  # verdict has to come from the ASF entry in data/orgs.json - this is the
  # apache/* blind spot (it answers unknown; the policy is on apache.org).
  A=$(scan --no-merges --json apache/commons-lang)
  is "apache/commons-lang verdict"    "GO-DECLARE" "$(printf '%s' "$A" | jq -r .verdict)"
  is "apache/commons-lang uses the ASF entry" "asf" "$(printf '%s' "$A" | jq -r '.org_policy.id')"
  is "apache/commons-lang is sourced to the org" "org" "$(printf '%s' "$A" | jq -r .stance.source)"
  has "apache/commons-lang gets the ASF trailer" "Generated-by:" "$(printf '%s' "$A" | jq -r '.disclosure // ""')"

  # A receipt for a real repository: the second run has to recognise the same
  # target and the same policy text, which is the path the offline tests cannot
  # reach (they all scan local files and have no repository name to match).
  LR="$OUT/receipt-live.json"
  rm -f "$LR"
  LR1=$(CONTRIB_POLICY_RECEIPT="$LR" scan --no-merges --receipt --json ghostty-org/ghostty)
  LR2=$(CONTRIB_POLICY_RECEIPT="$LR" scan --no-merges --receipt --json ghostty-org/ghostty)
  is "live receipt is new on the first run"       "new"       "$(printf '%s' "$LR1" | jq -r .receipt.status)"
  is "live receipt is unchanged on the second"    "unchanged" "$(printf '%s' "$LR2" | jq -r .receipt.status)"
  is "live receipt records the repository"        "ghostty-org/ghostty" "$(jq -r .repo "$LR")"
  is "live receipt hashes the files it read"      "true"      "$(jq '(.files | length) > 0' "$LR")"

  # gradio is the live case for pull_request_creation_policy, and the live case
  # for a repository that scores zero without any merge statistics being read.
  GR=$(scan --no-merges --json gradio-app/gradio)
  is "gradio pull_request_creation_policy" "collaborators_only" \
     "$(printf '%s' "$GR" | jq -r .openness.pull_request_creation_policy)"
  is "gradio openness score"  "0" "$(printf '%s' "$GR" | jq -r .openness.score)"
  has "gradio openness names the setting" "collaborators_only" \
      "$(printf '%s' "$GR" | jq -r .openness.summary)"

  # one run with the search api, to prove the 90-day statistics path works here
  O=$(scan ghostty-org/ghostty | sed -n 's/^openness: //p')
  has "openness line is filled in" "external merges 90d" "$O"
  case "$O" in
    [0-9]/10\ \(*|10/10\ \(*) ok "openness line starts with a score out of ten" ;;
    *) bad "openness line starts with a score out of ten" "N/10 (...)" "$O" ;;
  esac
  OS=$(scan ghostty-org/ghostty --json | jq -r .openness.score)
  case "$OS" in
    [1-9]|10) ok "an active project scores above zero" ;;
    *) bad "an active project scores above zero" "1-10" "$OS" ;;
  esac

fi

echo
echo "== live scans on gitlab.gnome.org =="
# These need curl and nothing else: no gh, no account, no token on either host.
if [ -n "$(host_reason gitlab.gnome.org)" ]; then
  skip "gitlab live scans" "$(host_reason gitlab.gnome.org)"
else
  # --no-dataset on purpose: this has to be the text of the project, read over
  # the GitLab API, and not data/policies.json answering for it.
  LA=$(scan --no-dataset --json gitlab.gnome.org/GNOME/libadwaita)
  is  "libadwaita verdict"        "STOP"     "$(printf '%s' "$LA" | jq -r .verdict)"
  is  "libadwaita is read as text" "text"    "$(printf '%s' "$LA" | jq -r .stance.source)"
  is  "libadwaita host"           "gitlab.gnome.org" "$(printf '%s' "$LA" | jq -r .host)"
  is  "libadwaita kind"           "gitlab"   "$(printf '%s' "$LA" | jq -r .kind)"
  has "libadwaita quotes CONTRIBUTING.md" "CONTRIBUTING.md" "$(printf '%s' "$LA" | jq -r '.quotes[].at')"
  has "libadwaita quotes the ban"  "does not allow contributions generated by large languages models" \
      "$(printf '%s' "$LA" | jq -r '.quotes[].text')"
  is  "libadwaita files are hashed" "true"   "$(printf '%s' "$LA" | jq '(.files|length) > 0')"
  # the list entry is found by url, not by a github field it does not have
  is  "the policy list is matched by url" "forbid" \
      "$(scan --json gitlab.gnome.org/GNOME/libadwaita | jq -r .stance.dataset)"
  # GitLab has no pull_request_creation_policy and no author_association, so both
  # are left unread rather than invented.
  is  "no pull request policy field off github" "null" "$(printf '%s' "$LA" | jq -r '.openness.pull_request_creation_policy // "null"')"
  is  "the 90-day statistics are not scored" "null" "$(printf '%s' "$LA" | jq -r '.openness.score // "null"')"
  has "the openness line says why" "not scored" "$(printf '%s' "$LA" | jq -r .openness.summary)"

  # The merge request template, which is where GIMP keeps its only AI rule and
  # which lives at a path that exists on no other host.
  GI=$(scan --no-dataset --json gitlab.gnome.org/GNOME/gimp)
  is  "gimp verdict" "STOP" "$(printf '%s' "$GI" | jq -r .verdict)"
  has "gimp quotes the merge request template" ".gitlab/merge_request_templates/default.md" \
      "$(printf '%s' "$GI" | jq -r '.quotes[].at')"

  # The nested group path from the checklist. gedit's LLM guideline is no longer
  # in this repository (the policy list still links to docs/guidelines/no-llm-tools.md
  # on a branch that is gone), so what is asserted here is that a three-segment
  # GitLab path resolves and its files are read.
  GE=$(scan --no-dataset --json gitlab.gnome.org/World/gedit/gedit)
  is  "gedit path resolves"     "World/gedit/gedit" "$(printf '%s' "$GE" | jq -r .repo)"
  has "gedit CONTRIBUTING.md is read" "CONTRIBUTING.md" "$(printf '%s' "$GE" | jq -r '.files | keys | join(" ")')"
  # data/orgs.json keys on github.com owner names, so a GitLab group is not
  # looked up in it: "World" here is not a github.com owner, and a self-hosted
  # group called "apache" is not the ASF. --owner is how you ask for one.
  is  "no organisation rule is inherited from a gitlab group" "null" \
      "$(printf '%s' "$GE" | jq -r '.org_policy // "null"')"
  is  "--owner still applies a foundation rule off github" "asf" \
      "$(scan --no-dataset --json --owner apache gitlab.gnome.org/World/gedit/gedit | jq -r '.org_policy.id')"

  is "a project that is not there exits unknown" "3" "$(code gitlab.gnome.org/GNOME/no-such-project-here)"
fi

echo
echo "== live scans on codeberg.org =="
if [ -n "$(host_reason codeberg.org)" ]; then
  skip "codeberg live scans" "$(host_reason codeberg.org)"
else
  EK=$(scan --no-dataset --json codeberg.org/EtchedPixels/EmulatorKit)
  is  "EmulatorKit verdict"  "STOP"   "$(printf '%s' "$EK" | jq -r .verdict)"
  # the http code of the metadata call has to reach the message (it is read
  # inside a command substitution)
  has "a missing repository is named as such" "repository not found" \
      "$(scan codeberg.org/EtchedPixels/no-such-repository-xyz 2>&1)"
  is  "a missing repository is UNKNOWN" "3" "$(code codeberg.org/EtchedPixels/no-such-repository-xyz)"
  is  "EmulatorKit kind"     "gitea"  "$(printf '%s' "$EK" | jq -r .kind)"
  # ContributionRules has no extension and is in no fixed list: the gitea tree
  # listing is what finds it.
  has "the tree listing finds ContributionRules" "ContributionRules" \
      "$(printf '%s' "$EK" | jq -r '.files | keys | join(" ")')"
  has "EmulatorKit quotes its ban" "co-pilot laundered code is not accepted" \
      "$(printf '%s' "$EK" | jq -r '.quotes[].text')"
  is "a repository that is not there exits unknown" "3" "$(code codeberg.org/EtchedPixels/no-such-repo-here)"
fi
}

# ------------------------------------------------------------------ accuracy
# A case table is: repo <TAB> expected verdict <TAB> where the expectation comes
# from. --no-merges keeps a verdict from moving with merge activity.
# STOP-CHECK counts as STOP: both stop the pull request and both exit 2.
#
# tests/cases.tsv runs with --no-dataset, so data/policies.json is the answer key
# and not an input, and the run grades the pattern set. tests/cases-dataset.tsv
# runs with the dataset, because those projects keep their policy outside the
# repository and no pattern set can read what is not there.
#
# Gate (plan 01): at least 90 per cent agreement, and not one case where a repo
# that bans AI work comes back as something other than STOP. Both tables are
# pooled for the gate, so moving a case between them cannot buy accuracy.
GATE_PERCENT=90
TOTAL=0; RIGHT=0; WRONG=0; UNKNOWNS=0; UNSAFE=0

run_table() { # run_table FILE OUTNAME [extra scan options...]
  local file="$1" outname="$2"; shift 2
  local repo want src got norm res
  printf 'repo\texpected\tactual\tresult\tsource\n' > "$OUT/$outname"
  while IFS=$'\t' read -r repo want src; do
    case "${repo:-}" in ''|'#'*) continue ;; esac
    got=$(verdict --no-merges "$@" "$repo")
    [ -n "$got" ] || got=ERROR
    norm=$got; [ "$norm" = STOP-CHECK ] && norm=STOP
    TOTAL=$((TOTAL + 1))
    if [ "$norm" = "$want" ]; then
      RIGHT=$((RIGHT + 1)); res=ok
    elif [ "$norm" = UNKNOWN ] || [ "$norm" = ERROR ]; then
      UNKNOWNS=$((UNKNOWNS + 1)); res=unknown
    else
      WRONG=$((WRONG + 1)); res=wrong
      # the expensive mistake: a repository that says no comes back as a green light
      [ "$want" = STOP ] && { UNSAFE=$((UNSAFE + 1)); res=UNSAFE; }
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$want" "$got" "$res" "$src" >> "$OUT/$outname"
    printf '  %-34s want %-11s got %-11s %s\n' "$repo" "$want" "$got" "$res"
  done < "$file"
}

case_tests() {
if [ -n "$NET_SKIP" ]; then echo "== accuracy =="; skip "case tables" "$NET_SKIP"; return; fi

echo "== accuracy over tests/cases.tsv (repository text only) =="
run_table "$HERE/cases.tsv" cases.tsv --no-dataset
echo
echo "== accuracy over tests/cases-dataset.tsv (policy published off the repository) =="
run_table "$HERE/cases-dataset.tsv" cases-dataset.tsv

[ "$TOTAL" -gt 0 ] || { bad "case tables" "at least one case" "no cases found"; return; }
local pct=$(( RIGHT * 100 / TOTAL ))
echo
printf '  %s cases: %s correct (%s%%), %s wrong, %s unknown, %s unsafe\n' \
  "$TOTAL" "$RIGHT" "$pct" "$WRONG" "$UNKNOWNS" "$UNSAFE"
echo "  tables: tests/out/cases.tsv, tests/out/cases-dataset.tsv"
if [ "$pct" -ge "$GATE_PERCENT" ]; then ok "accuracy gate (>= $GATE_PERCENT%)"
else bad "accuracy gate (>= $GATE_PERCENT%)" "$GATE_PERCENT% of $TOTAL" "$pct% ($RIGHT/$TOTAL)"; fi
if [ "$UNSAFE" -eq 0 ]; then ok "no STOP repository reported as safe to contribute to"
else bad "no STOP repository reported as safe to contribute to" "0" "$UNSAFE"; fi
}

[ "$CASES_ONLY" = 1 ] || unit_tests
echo
case_tests

echo
echo "== summary =="
printf 'pass %s  fail %s  skip %s\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
  echo "failed:"
  printf '%s' "$FAILED" | sed 's/^/  - /'
  exit 1
fi
exit 0
