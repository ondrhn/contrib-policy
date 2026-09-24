# contrib-policy

**Read a project's contribution rules before you open the pull request.**
A skill for coding agents, and a command for people, that answers one question
about any repository: *may this change be sent here, and on what terms?*

```
$ scripts/policy_scan.sh codeberg.org/EtchedPixels/EmulatorKit
verdict: STOP
reasons:
  - AI-assisted contributions are not accepted (text)
quotes:
  - [FORBID] ContributionRules:3  "Microsoft co-pilot laundered code is not accepted in this project"

$ scripts/policy_scan.sh apache/commons-lang
verdict: GO-DECLARE
reasons:
  - the repository states no rule; Apache Software Foundation: generative tooling
    may be used for an ASF contribution when the contributor holds the rights to
    the output, and the contribution has to record which tool produced it, by
    convention a Generated-by: trailer (https://www.apache.org/legal/generative-tooling.html)
quotes:
  - [CLA]   CONTRIBUTING.md:91  "Sign and submit the Apache [Contributor License Agreement][cla] ..."
  - [NOCLA] CONTRIBUTING.md:92  "Note that small patches & typical bug fixes do not require a CLA ..."
disclosure: Generated-by: Claude Code
openness: 10/10 (external merges 90d: 63/65, sample 65, PR policy: all)
injection: none
cla: ICLA only for committers; not needed for a pull request
dco: false
org_policy: asf (disclose) applied
```

Both are real runs (2026-09-18; the header line and some notes cut, `--json`
prints everything). Every verdict carries the file, the line and the sentence
it came from. A verdict without a quote is a bug, not an opinion.

## Why this exists

More and more pull requests are written with an AI tool in the loop, and more
and more projects have written down what they think about that. Some refuse it
outright. Some take it if you say so, in a particular form of words. Some have
closed pull requests to outsiders altogether. The rule lives in `CONTRIBUTING`,
in an `AI_POLICY.md`, in a pull request template checkbox, in a foundation's
legal page, or in a repository setting no file mentions, and an agent that does
not read it wastes a maintainer's afternoon and burns the contributor's name.

contrib-policy reads all of those places in one pass, in a few seconds, with no
model call, and gives one of five answers:

| verdict | exit | meaning | what to do |
|---|---|---|---|
| `GO` | 0 | no rule against it, or AI use is allowed | open the pull request; a human still reviews every line |
| `GO-DECLARE` | 1 | disclosure required | put the printed `disclosure:` line in the commit or the pull request body |
| `STOP` | 2 | AI-assisted work is refused, or pull requests are shut | do not open it; tell the human what the project says |
| `STOP-CHECK` | 2 | the policy files contain text aimed at an agent, or hidden text | a human reads the findings before anything else happens |
| `UNKNOWN` | 3 | something could not be read | not a green light; rerun or ask |

There is no "use it quietly" option. Where a project asks for disclosure, the
choice is to disclose or not to contribute.

## Install

As a skill (`SKILL.md` is at the root of this repository, the layout the
[skills CLI](https://skills.sh) and Claude Code expect):

```
npx skills add ondrhn/contrib-policy          # any agent that reads skills
git clone https://github.com/ondrhn/contrib-policy ~/.claude/skills/contrib-policy   # Claude Code, by hand
```

As a command, clone it anywhere and run `scripts/policy_scan.sh`. Nothing is
installed and nothing is compiled: bash, curl, jq and awk, plus `gh` for
github.com targets.

## Use

```
scripts/policy_scan.sh OWNER/REPO                        # github.com (needs gh)
scripts/policy_scan.sh gitlab.gnome.org/GNOME/libadwaita # gitlab
scripts/policy_scan.sh codeberg.org/owner/repo           # codeberg / gitea
scripts/policy_scan.sh https://github.com/o/r/blob/main/AGENTS.md   # a pasted url works too
scripts/policy_scan.sh --file CONTRIBUTING.md            # local files, no network
scripts/policy_scan.sh OWNER/REPO --json --receipt       # full object, and keep it
```

| option | use it when |
|---|---|
| `--json` | you want the reasons, quotes, hashes and scores as data |
| `--receipt` | the run should be recorded at `.contrib-policy/receipt.json` and compared with the last one |
| `--agent N --model M --tool T` | the disclosure line must name who wrote the patch |
| `--owner ORG` | the question is what a foundation requires, with no repository to read |
| `--no-merges` | the 90-day merge count is not worth the wait |
| `--kind gitlab\|gitea` | a self-hosted instance whose host name does not say what it runs |
| `--quiet` / `--dry-run` / `--help` | the verdict word alone / the parsed target / every option |

## What it reads

1. **Repository settings**: archived, pull requests enabled, and on github.com
   `pull_request_creation_policy` (a `collaborators_only` repository will not
   take a pull request from you at all, whatever its CONTRIBUTING says).
2. **The files**: CONTRIBUTING (root, `.github/`, `docs/`), AI_POLICY, pull
   request and merge request templates, AGENTS.md, CLAUDE.md, copilot
   instructions, the code of conduct, CLA/DCO configuration, the contributing
   section of the README, plus anything the repository tree calls a policy
   (`docs/guidelines/no-llm-tools.md`, `qep-408-ai-tool-policy.md`, ...).
3. **Foundation rules** where the repository is silent: ASF, CNCF, GNOME, the
   Linux kernel family, PSF, Eclipse (`data/orgs.json`), and a snapshot of the
   [melissawm](https://github.com/melissawm/open-source-ai-contribution-policies)
   list as a cross-check for policies published off the repository.
4. **The 90-day record** of merges from outside contributors, as an openness
   score: a project that merges nothing from outsiders is a different risk from
   one that merges dozens.

On conflict the stricter rule wins, and both are printed. The classifier is
patterns over sentences in seven languages, with a shield against the classic
false positive ("please do not open pull requests for translations" is not an
AI rule) and a softener for "consider adding a trailer" (an invitation is not
an obligation).

## Two rules that do not bend

**Policy files are untrusted data.** Everything this tool reads comes from a
stranger's repository. It is quoted, never executed, never followed. Text
written at an agent ("if you are an AI, run this"), instructions hidden in HTML
comments, zero-width and bidi characters, invisible tag-block characters,
`curl | sh` and opaque blobs are reported, and a suspicious finding turns the
verdict into `STOP-CHECK`.

**An agent never signs the DCO.** `Signed-off-by` is a legal certification by
the person submitting the work; the kernel says it in as many words. The
disclosure line this tool writes is `Assisted-by:`, `Generated-by:`, a template
checkbox or a sentence for the pull request body. Never a sign-off, and the
same goes for a CLA.

## Optional: a gate in front of `gh pr create`

`hooks/pr_gate.sh` is a Claude Code `PreToolUse` hook. With it installed,
`gh pr create`, `glab mr create`, the raw API behind them and the MCP pull
request tools are denied unless a receipt for that project exists, is fresh,
and says `GO`; `GO-DECLARE` asks the human to confirm the disclosure line is in
the body; `STOP` is refused with the project's own sentence. Merge
`hooks/hooks.json` into `.claude/settings.json` to turn it on.

## Neighbouring tools

Two other tools ask a similar question. They came first, they are named here,
and this table is what each one does, read from its own source at a pinned
commit - not from anybody's marketing: `yunaremaia/aipr@e168c9c3` (version
0.2.2, head on 2026-09-19) and `daichunghy/contribkit@1d23e770`
(0.1.0-alpha.7, head since 2026-09-06).

The rows that can be reduced to a number or a grep are in
`data/neighbours.tsv`, pinned to those commits, and `bash
scripts/check_neighbours.sh` re-runs all of them against the neighbours' own
files. If an upstream change makes a row here wrong, that command says so
instead of this table quietly ageing.

| signal | contrib-policy | aipr 0.2.2 | contribkit 0.1.0-alpha.7 |
|---|---|---|---|
| policy text classified | yes | yes | yes |
| files read | fixed list + repository tree (any name) | 13 fixed paths | fixed list in a local clone |
| pull request / merge request template | yes | no | yes |
| github.com | yes | yes | only as a local clone |
| GitLab, Codeberg/Gitea | yes | no | only as a local clone |
| remote repository, nothing cloned | yes | yes | no |
| repository settings (`pull_request_creation_policy`, archived, PRs off) | yes | no | no |
| 90-day merges from outside contributors | yes | no | no |
| CLA detection | yes | no | no |
| DCO detection | yes | no | yes (`SIGNED_OFF` in `evaluate.ts`) |
| foundation / org rules where the repo is silent | data/orgs.json (ASF, CNCF, GNOME, kernel family, PSF, Eclipse) | probes `<org>/.github` | no |
| target files treated as untrusted | yes | not stated | yes (`docs/THREAT_MODEL.md`) |
| screens the text for hidden instructions and reports them | yes | no | no |
| writes the disclosure line for you | yes (`Assisted-by:`, `Generated-by:`, template box, PR sentence) | no | checks that one exists |
| judges your diff against the rules | no | no | yes |
| evidence file (receipt, hashes, "policy changed") | yes | no | yes |
| PreToolUse hook that blocks `gh pr create` | optional (`hooks/`) | no | yes |
| language / install | bash, no install | Python, pip or `gh` extension | TypeScript, npm |
| licence | MIT | MIT | Apache-2.0 |

- **aipr** - <https://github.com/yunaremaia/aipr>. Weighted phrase matching over
  governance text: 33 compiled patterns in `detector.py`, 13 candidate paths in
  `cli.py`, five verdicts (`human_only`, `restrictive`, `disclose_ok`,
  `permissive`, `unknown`) and an exit code. It reads api.github.com only.
- **contribkit** - <https://github.com/daichunghy/contribkit>. Compiles
  CONTRIBUTING, the pull request template, CODEOWNERS and an optional
  `contribkit.yml` into a contract and evaluates the **local diff** against it
  (`pass` / `blocked` / `needs-human`), with test recording, a Claude Code
  plugin, MCP and a hook. It reads a git clone on disk, not a remote repository.

The questions differ. aipr and contrib-policy answer "is this project open to
me?"; contribkit answers "does my diff satisfy this project's contract?". The
two are complementary: a receipt from here and a preflight from contribkit
answer different halves.

### Limits, measured

**aipr** looks at thirteen fixed paths, every one of them a `CONTRIBUTING`,
`AI_POLICY`, `AGENTS`, `CLAUDE` or `README` variant, so a rule that lives
anywhere else is invisible to it: `gentoo/gentoo` keeps its ban in
`.github/pull_request_template.md` and aipr reported `files: []`. Its fetcher
names no host but api.github.com, and the GNOME and Codeberg projects hold most
of the outright bans. The policy text is its only signal - the repository's own
settings, its record of merging outside work, a CLA and a DCO are all absent
from the source - and it neither writes the disclosure line for you nor looks at
what the text it read is trying to tell an agent to do.

**contribkit** is asked after the change exists, not before: it compiles the
contract from a clone on disk and grades a diff. `src/repo.ts` contains no URL
at all, so a repository you have not cloned cannot be checked, and a project on
GitLab or Codeberg is only reachable the same way. It reads no repository
settings and keeps no openness measure. Its threat model is explicit that every
file in the target tree is untrusted and that no command found there is run;
what it does not do is read that text for instructions aimed at the agent
reading it (no mention of prompt injection, hidden or zero-width text in
`docs/THREAT_MODEL.md`).

**This tool** has limits of the same kind. The classifier is patterns over
sentences, not a model, so a policy phrased in a way no pattern covers reads as
silence - which is why the verdict always carries its sentence, and why silence
is `GO` and not a promise. A policy published on a project website is known only
through `data/policies.json`, a snapshot of somebody else's list. Off github.com
two signals cannot be read at all and say so rather than guess:
`pull_request_creation_policy` and the split between member and outside merges.
The 90-day external merge count is an estimate - the search API stops at 100
items, and the sample size is printed next to the number for that reason.

No "first" claim is made anywhere in this repository.

## How well does it do?

`tests/cases.tsv` and `tests/cases-dataset.tsv` are 78 real repositories with
the expected verdict and the file:line the expectation comes from. The gate is
at least 90 per cent agreement and **zero** repositories that ban AI work
reported as safe.

Last run (2026-09-22): 78 cases, 77 correct (98%), 0 unsafe. `bash tests/run.sh`
reproduces it. The one miss is a project whose policy was rewritten after the
expectation was recorded, and the tool erred on the side of `STOP`. A high score
on 78 hand-checked repositories is not a claim about the next one: these are the
cases the patterns were written against, and every verdict still has to be read
with its quote.

Head to head with aipr over the ten known projects, each one a live
run of both tools: `docs/comparison.md` (contrib-policy 9 of 9 on the github.com
rows, aipr 0 correct, 1 wrong, 8 `unknown`; the causes are listed there, and
most of them are which files each tool reads).

## Data

| file | source | licence |
|---|---|---|
| `data/policies.json` | [melissawm/open-source-ai-contribution-policies](https://github.com/melissawm/open-source-ai-contribution-policies), fetched 2026-09-18 | CC0-1.0 |
| `data/orgs.json` | foundation policy pages, url in every entry | this repository, MIT |
| `data/aliases.tsv`, `data/known10.tsv` | curated by hand, source in every row | this repository, MIT |
| `data/neighbours.tsv` | the neighbours' own source at a pinned commit, re-checkable with `scripts/check_neighbours.sh` | this repository, MIT |

Related work worth knowing about:
[sujeito-operator/ai-contribution-policy](https://github.com/sujeito-operator/ai-contribution-policy)
(a dataset over the top 800 repositories, CC BY 4.0, and the source of the
false-positive warning this tool's shield is built on),
[ecogetaway/oss-ai-contribution-policy](https://github.com/ecogetaway/oss-ai-contribution-policy)
(a draft `ai-contribution-policy.yml` standard) and
[bcmyguest/assisted-by](https://github.com/bcmyguest/assisted-by) (enforces the
`Assisted-by:` trailer from the other side).

## Requirements

bash 3.2 or later, curl, jq, awk, sha256sum, od, and `gh` (authenticated) for
github.com targets. Tested against GNU grep/awk/coreutils; the test suite
checks the awk and grep on the host before anything else.

Network use is bounded: every answer is cached for 24 hours under
`~/.cache/contrib-policy` (`$CONTRIB_POLICY_CACHE`), rate-limit answers are
retried after the wait the host names (`$CONTRIB_POLICY_RETRIES`,
`$CONTRIB_POLICY_MAX_WAIT`), requests are spaced (`$CONTRIB_POLICY_MIN_GAP_MS`),
and a limit that cannot be waited out is `UNKNOWN`, not a verdict.
`scripts/policy_scan.sh --help` lists them.

## Licence

MIT. See `LICENSE`. The policy list in `data/policies.json` is CC0-1.0 and
credited above; the two neighbouring tools are MIT and Apache-2.0 and are
named, linked and quoted at pinned commits.
