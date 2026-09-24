# contrib-policy vs aipr on the ten known projects

Measured 2026-09-18. Regenerate with:

```
bash scripts/compare_aipr.sh --md
```

The repository list is `data/known10.tsv`: ten projects whose policy is
known from a primary source. Each row is one live run of each tool
against github.com; nothing in the table is copied from documentation.

## What was run

| | |
|---|---|
| contrib-policy | `scripts/policy_scan.sh --quiet --no-merges REPO`, this working tree, version 0.1.0 |
| aipr | 0.2.2, commit `65a0f790a8c0c635034ebb2f8cc95332329ab56d`, `aipr --json REPO` |

aipr is not installed on this host: there is no `pip` and no `ensurepip`, and
this session does not install packages. aipr declares no dependencies outside
the Python standard library, so `scripts/compare_aipr.sh` downloads its four
source modules at the pinned commit into `tests/out/aipr-src/` and runs them
with `python3 -c 'from aipr.cli import main'`. Before running them the modules
were read for side effects: no `subprocess`, no `eval`/`exec`, network only
through `urllib` to `api.github.com`, writes only under `AIPR_CACHE_DIR` (and,
for the unused `aipr init` subcommand, into the current directory). The run
used `AIPR_CACHE_DIR=tests/out/aipr-cache` and the token from `gh auth token`,
because aipr rate-limits within a few repositories when anonymous.

If `aipr` is on PATH, or installed as `gh aipr`, the script uses that instead
and the vendored copy is never fetched.

## Results

| project | repo | expected | contrib-policy (exit) | aipr (exit) | aipr autonomous_safe | ground truth |
|---|---|---|---|---|---|---|
| curl | curl/curl | GO-DECLARE | GO-DECLARE (1) | unknown (2) | false | curl.se/dev/contribute.html#on-ai-use-in-curl (disclosure=Yes); in the repository docs/CONTRIBUTE.md:356 only asks for human understanding |
| Ghostty | ghostty-org/ghostty | GO-DECLARE | GO-DECLARE (1) | human_only (1) | false | AI_POLICY.md:5 "All AI usage in any form must be disclosed" |
| Gentoo Linux | gentoo/gentoo | STOP | STOP (2) | unknown (2) | false | .github/pull_request_template.md:9 attestation "has not been created with the assistance of Natural Language Processing artificial intelligence tools" |
| gedit | gitlab.gnome.org:World/gedit/gedit | STOP | n/a | n/a | - | off github.com (contrib-policy answers STOP off the harness, see Host below) |
| Asahi Linux | AsahiLinux/linux | STOP | STOP (2) | unknown (2) | false | asahilinux.org/docs/project/policies/slop/ (allowed=No); the repository is a kernel fork and carries no AI text of its own |
| CPython | python/cpython | GO | GO (0) | unknown (2) | false | devguide: disclosure is thanked, not required; no AI rule in the repository tree |
| Django | django/django | GO-DECLARE | GO-DECLARE (1) | unknown (2) | false | melissawm/Django (allowed=Yes disclosure=Yes oversight=Yes) |
| FastAPI | fastapi/fastapi | GO | GO (0) | unknown (2) | false | melissawm/FastAPI (allowed=Yes disclosure=No oversight=Yes) |
| attrs | python-attrs/attrs | GO-DECLARE | GO-DECLARE (1) | unknown (2) | false | .github/AI_POLICY.md:62 no LLM co-author trailer, .github/PULL_REQUEST_TEMPLATE.md:18 tick box acknowledging the AI policy |
| Apache Arrow | apache/arrow | GO-DECLARE | GO-DECLARE (1) | unknown (2) | false | .github/pull_request_template.md:24 "please disclose below whether and how AI was used in this PR" |

Raw counts over the nine github.com rows:

| | correct | wrong | no answer | wrong in the unsafe direction |
|---|---|---|---|---|
| contrib-policy | 9 | 0 | 0 | 0 |
| contrib-policy, `--no-dataset` (repository text only) | 7 | 2 | 0 | 1 |
| aipr | 0 | 1 | 8 | 0 |

The vocabularies do not line up one to one, so "correct" is read as: does the
tool's answer tell a contributor the right thing to do?

- `unknown` is scored as "no answer", not as a wrong answer. aipr says so itself
  ("treat UNKNOWN as read it yourself") and exits 2 rather than 0.
- `human_only` on Ghostty is scored wrong: Ghostty accepts AI-assisted work and
  asks for disclosure. A contributor following aipr here does not send a pull
  request that would have been merged.
- No aipr answer was wrong in the unsafe direction, which matches its stated
  design ("weak mixed signals lean restrictive on purpose").

## Why the answers differ

**Which files are read.** aipr probes thirteen fixed paths, all of them
`AI_POLICY` / `CONTRIBUTING` / `AGENTS` / `CLAUDE` / `README` variants. Three of
the misses are that list, not the classifier:

- `gentoo/gentoo` has none of those files. Its root holds six files and none is
  a README; the AI ban is an attestation tick box in
  `.github/pull_request_template.md`. aipr reported `files: []`.
- `apache/arrow`: aipr read `CONTRIBUTING.md`, `.github/CONTRIBUTING.md` and
  `README.md` and scored 0. The disclosure requirement is in
  `.github/pull_request_template.md:24`, which aipr does not fetch; what it did
  read only points at the guidance ("Please review our AI-generated code
  guidance before submitting AI-assisted contributions", `CONTRIBUTING.md:70`).
- `python/cpython`: aipr found `AGENTS.md` and nothing else, and scored 0.
  contrib-policy also finds no AI rule in the tree; the difference is the
  default, GO against `unknown`. This row is agreement dressed as a difference.
- `python-attrs/attrs`: aipr did fetch `.github/AI_POLICY.md` and still scored
  0. That file says "Pull requests that have an LLM product listed as co-author
  can't be merged" (line 62) and "Absolutely no unsupervised agentic tools"
  (line 8). This one is the phrase set, not the file list.

Pull request templates carry the rule in a large share of the corpus, because a
tick box is how a project makes a contributor read it. A policy reader that
skips them will keep answering `unknown`.

**Which signals exist at all.** aipr reads policy text only. Two rows here are
not answerable from repository text:

- `curl/curl` publishes the rule on curl.se; the repository text alone reads as
  GO. contrib-policy gets GO-DECLARE from `data/policies.json` (the melissawm
  list, CC0-1.0).
- `AsahiLinux/linux` is a kernel fork with no AI text of its own; the ban is on
  asahilinux.org. Same path.

That is the `--no-dataset` row in the counts above: on repository text alone,
contrib-policy is 7/9 with one miss in the unsafe direction (Asahi), and the
list is what closes the gap. This is worth stating plainly, because it is the
part of the result that does not come from better patterns.

**Host.** gedit is the control row: its canonical repository is
gitlab.gnome.org/World/gedit/gedit and there is no github.com mirror. aipr reads
github.com only, so the row stays `n/a` on its side and the harness leaves both
columns at `n/a` - it exists to compare the two tools, and there is nothing to
compare here.

contrib-policy itself now answers this row. Since 2026-09-18 it reads GitLab
(`/api/v4`) and Codeberg/Gitea (`/api/v1`) through the same pipeline:

```
scripts/policy_scan.sh gitlab.gnome.org/World/gedit/gedit    -> STOP (2), source: policy list
scripts/policy_scan.sh gitlab.gnome.org/GNOME/libadwaita     -> STOP (2), source: CONTRIBUTING.md:8
scripts/policy_scan.sh codeberg.org/EtchedPixels/EmulatorKit -> STOP (2), source: ContributionRules:3
```

Two of those three come from the text of the project and need no list. gedit
needs the list: the LLM guideline the list links to
(`docs/guidelines/no-llm-tools.md`) is no longer in the repository, so the
repository text alone answers GO. The list entry is matched by its url, because
off github.com there is no `github` field to match on.

## Not measured here

Verdict accuracy is one axis. The signals contrib-policy adds and aipr does not
have - `pull_request_creation_policy`, external merge rate, CLA/DCO detection,
the injection screen, the generated disclosure line - have no aipr column to
compare against, so they are absent from this table rather than scored as wins.
The `gradio-app/gradio` case in `tests/cases.tsv` is the clearest example: its
policy text is silent, and the STOP comes from
`pull_request_creation_policy=collaborators_only`, a field aipr never reads.

## Reproducing

```
bash scripts/compare_aipr.sh --md            # markdown, as above
bash scripts/compare_aipr.sh --tsv           # tab separated
bash scripts/compare_aipr.sh --no-fetch      # only use an already-installed aipr
bash scripts/compare_aipr.sh --repos FILE    # a different repository table
```

Counts move when a project edits its policy. The date at the top of this file
is the date of the run.
