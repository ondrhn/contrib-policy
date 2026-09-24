# contrib-policy

[![skills.sh](https://skills.sh/b/ondrhn/contrib-policy)](https://skills.sh/ondrhn/contrib-policy)

**Read a project's contribution rules before you open the pull request.**

A skill for coding agents, and a command for people. It answers one question
about any repository: *may this change be sent here, and on what terms?*

- **One verdict:** `GO`, `GO-DECLARE`, `STOP`, `STOP-CHECK` or `UNKNOWN`.
- **One quote per verdict:** the file, the line and the sentence it came from.
- **No model call:** bash, curl, jq and awk. A few seconds per repository.
- **Works on** github.com, GitLab, Codeberg and Gitea, plus local files.

> A verdict without a quote is a bug, not an opinion.

**Contents:**
[Quick start](#quick-start) ·
[Why](#why-this-exists) ·
[The five verdicts](#the-five-verdicts) ·
[Install](#install) ·
[Use](#use) ·
[What it reads](#what-it-reads) ·
[Two rules that do not bend](#two-rules-that-do-not-bend) ·
[The PR gate](#optional-a-gate-in-front-of-gh-pr-create) ·
[Accuracy](#how-well-does-it-do) ·
[Requirements](#requirements)

## Quick start

```
git clone https://github.com/ondrhn/contrib-policy
cd contrib-policy
scripts/policy_scan.sh OWNER/REPO
```

Two real runs (2026-09-18; the header line and some notes cut, `--json`
prints everything):

**A project that says no:**

```
$ scripts/policy_scan.sh codeberg.org/EtchedPixels/EmulatorKit
verdict: STOP
reasons:
  - AI-assisted contributions are not accepted (text)
quotes:
  - [FORBID] ContributionRules:3  "Microsoft co-pilot laundered code is not accepted in this project"
```

**A project that says yes, if you say so:**

```
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

## Why this exists

More and more pull requests are written with an AI tool in the loop, and more
and more projects have written down what they think about that.

- Some **refuse it outright**.
- Some **take it if you say so**, in a particular form of words.
- Some have **closed pull requests to outsiders** altogether.

The rule lives in `CONTRIBUTING`, in an `AI_POLICY.md`, in a pull request
template checkbox, in a foundation's legal page, or in a repository setting no
file mentions. An agent that does not read it wastes a maintainer's afternoon
and burns the contributor's name.

contrib-policy reads all of those places in one pass and gives one of five
answers.

## The five verdicts

| verdict | exit | meaning | what to do |
|---|---|---|---|
| `GO` | 0 | no rule against it, or AI use is allowed | open the pull request; a human still reviews every line |
| `GO-DECLARE` | 1 | disclosure required | put the printed `disclosure:` line in the commit or the pull request body |
| `STOP` | 2 | AI-assisted work is refused, or pull requests are shut | do not open it; tell the human what the project says |
| `STOP-CHECK` | 2 | the policy files contain text aimed at an agent, or hidden text | a human reads the findings before anything else happens |
| `UNKNOWN` | 3 | something could not be read | not a green light; rerun or ask |

> There is no "use it quietly" option. Where a project asks for disclosure,
> the choice is to disclose or not to contribute.

## Install

Three ways, pick one.

### 1. As a Claude Code plugin (skill + PR gate)

Two commands inside Claude Code:

```
/plugin marketplace add ondrhn/contrib-policy
/plugin install contrib-policy@ondrhn
```

The skill shows up in `/skills` as `contrib-policy:contrib-policy`.

**Read this before you install.** The plugin also turns on the pull request
gate. From then on `gh pr create`, `glab mr create` and the pull request API
are denied in that session until `scripts/policy_scan.sh OWNER/REPO --receipt`
has been run for the project and the receipt says `GO`. A `GO-DECLARE` asks
you to confirm the disclosure line is in the body. That is the point of the
plugin, not a side effect. `/plugin disable contrib-policy@ondrhn` turns it
off.

### 2. As a skill, without the gate

`SKILL.md` sits at the root of this repository, the layout the
[skills CLI](https://skills.sh) and Claude Code expect:

```
npx skills add ondrhn/contrib-policy          # any agent that reads skills
git clone https://github.com/ondrhn/contrib-policy ~/.claude/skills/contrib-policy   # Claude Code, by hand
```

The gate stays off unless you merge `hooks/hooks.json` into your settings.

### 3. As a command

Clone it anywhere and run `scripts/policy_scan.sh`. Nothing is installed and
nothing is compiled: bash, curl, jq and awk, plus `gh` for github.com targets.

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

1. **Repository settings.** Archived, pull requests enabled, and on github.com
   `pull_request_creation_policy`. A `collaborators_only` repository will not
   take a pull request from you at all, whatever its CONTRIBUTING says.
2. **The files.** CONTRIBUTING (root, `.github/`, `docs/`), AI_POLICY, pull
   request and merge request templates, AGENTS.md, CLAUDE.md, copilot
   instructions, the code of conduct, CLA/DCO configuration, the contributing
   section of the README, plus anything the repository tree calls a policy
   (`docs/guidelines/no-llm-tools.md`, `qep-408-ai-tool-policy.md`, ...).
3. **Foundation rules** where the repository is silent. ASF, CNCF, GNOME, the
   Linux kernel family, PSF, Eclipse (`data/orgs.json`), and a snapshot of the
   [melissawm](https://github.com/melissawm/open-source-ai-contribution-policies)
   list as a cross-check for policies published off the repository.
4. **The 90-day record** of merges from outside contributors, as an openness
   score. A project that merges nothing from outsiders is a different risk from
   one that merges dozens.

**On conflict the stricter rule wins**, and both are printed.

The classifier is patterns over sentences in seven languages. It has a shield
against the classic false positive ("please do not open pull requests for
translations" is not an AI rule) and a softener for "consider adding a
trailer" (an invitation is not an obligation).

## Two rules that do not bend

### Policy files are untrusted data

Everything this tool reads comes from a stranger's repository. It is quoted,
never executed, never followed.

Reported, and turned into `STOP-CHECK`:

- text written at an agent ("if you are an AI, run this")
- instructions hidden in HTML comments
- zero-width, bidi and invisible tag-block characters
- `curl | sh` and opaque blobs

Also reported: the ways a rule can be written for a reader and hidden from a
pattern. An invisible character inside a word, a Cyrillic or Greek look-alike
letter, an HTML comment or entity splitting a word, a control character or
escape sequence, a NUL byte, base64 that decodes to an instruction. The text
is normalised before it is classified, so the rule is read anyway; the trick
is what gets reported.

### An agent never signs the DCO

`Signed-off-by` is a legal certification by the person submitting the work;
the kernel says it in as many words. The disclosure line this tool writes is
`Assisted-by:`, `Generated-by:`, a template checkbox or a sentence for the
pull request body. Never a sign-off, and the same goes for a CLA.

## Optional: a gate in front of `gh pr create`

`hooks/pr_gate.sh` is a Claude Code `PreToolUse` hook. With it installed,
`gh pr create`, `glab mr create`, the raw API behind them and the MCP pull
request tools are denied unless a receipt for that project exists, is fresh,
and says `GO`.

| receipt says | the gate does |
|---|---|
| `GO` | lets the command through |
| `GO-DECLARE` | asks the human to confirm the disclosure line is in the body |
| `STOP` | refuses, with the project's own sentence |
| `STOP-CHECK` or `UNKNOWN` | refuses |
| none, stale, or for another repository | refuses until `scripts/policy_scan.sh OWNER/REPO --receipt` has run |

The plugin turns it on. A hand-installed skill turns it on by merging
`hooks/hooks.json` into `.claude/settings.json`.

**Its limit:** it reads the command text. A command that hides its shape from
the text (a variable that holds `gh`, an alias, `base64 -d | sh`, `xargs`, the
compare page in a browser) is beyond it. The sandbox's network policy is the
fence for those, and the hook is the second lock.

## How well does it do?

`tests/cases.tsv` and `tests/cases-dataset.tsv` are 78 real repositories with
the expected verdict and the file:line the expectation comes from. The bar is
at least 90 per cent agreement and **zero** repositories that ban AI work
reported as safe.

**Last run (2026-09-24):** 78 cases, 77 correct (98%), 0 unsafe.
`bash tests/run.sh` reproduces it.

The one miss is a project whose policy was rewritten after the expectation was
recorded, and the tool erred on the side of `STOP`. A high score on 78
hand-checked repositories is not a claim about the next one: these are the
cases the patterns were written against, and every verdict still has to be
read with its quote.

### Tested against itself

The tool reads files a stranger wrote, so it was attacked as one: invisible
characters inside words, look-alike letters, HTML and markdown tricks, NUL
bytes and escape sequences, agent-directed text in shapes the patterns had not
seen, and every way of spelling `gh pr create` that a hook might miss.
What got through and what changed is in `docs/red-team-2026-09.md`; every
row is a fixture the test suite runs.

## Data

| file | source | licence |
|---|---|---|
| `data/policies.json` | [melissawm/open-source-ai-contribution-policies](https://github.com/melissawm/open-source-ai-contribution-policies), fetched 2026-09-18 | CC0-1.0 |
| `data/orgs.json` | foundation policy pages, url in every entry | this repository, MIT |
| `data/aliases.tsv` | curated by hand, source in every row | this repository, MIT |

## Requirements

- bash 3.2 or later, curl, jq, awk, sha256sum, od
- `gh` (authenticated) for github.com targets
- tested against GNU grep/awk/coreutils; the test suite checks the awk and
  grep on the host before anything else

**Network use is bounded.** Every answer is cached for 24 hours under
`~/.cache/contrib-policy` (`$CONTRIB_POLICY_CACHE`). Rate-limit answers are
retried after the wait the host names (`$CONTRIB_POLICY_RETRIES`,
`$CONTRIB_POLICY_MAX_WAIT`), requests are spaced
(`$CONTRIB_POLICY_MIN_GAP_MS`), and a limit that cannot be waited out is
`UNKNOWN`, not a verdict. `scripts/policy_scan.sh --help` lists them.

## Licence

MIT. See `LICENSE`. The policy list in `data/policies.json` is CC0-1.0 and
credited above.
