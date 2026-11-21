# Clearpath engineering guide

Clearpath is a proof of concept for a local-first macOS filter that blocks adult domains and forces search-engine SafeSearch at the DNS level. This file is how coding agents (Claude Code and Codex) work in this repo; `CLAUDE.md` points here. The rules are strict; the process is light.

## Read first

| Doc | For |
|---|---|
| `README.md` | What Clearpath is, the layout, how to run it |
| `docs/BRIEF.md` | What Clearpath is today, what it doesn't do, and the milestones (approved at onboarding) |
| `docs/ARCHITECTURE.md` | The technical foundation assessment: options considered, the proposed data path, policy and SafeSearch semantics, limits and the next decision gate |
| `docs/TESTING.md` | Which tests are safe on this machine, and the disposable-VM procedure for anything that touches a Mac's DNS or browsers |
| `docs/RESULTS.md` | Observed results of the experiment |
| `docs/UPSTREAM_AUDIT.md` | The audit of the upstream project distraction-free and why it isn't forked |

Read only what the task needs. If a doc and the code disagree, the code is the truth: fix the doc in the same PR, or raise it if it changes what something means.

## How work flows

1. Work starts from a goal or a GitHub issue. The issue is the brief.
2. Carry it to a PR with the `victor-kit:vk-ship` skill: branch, smallest complete change, proof, a PR from `.github/pull_request_template.md`.
3. **Review required for:** anything that writes or deletes files outside the repo, talks to the network or an account, handles money or prices, or changes a stored file or data format, and any change to this file, `.claude/settings.json`, `.githooks/` or the PR template. These need a PASS from the `victor-kit:reviewer` agent before the PR is ready. For anything else review is optional; the PR says "Not required". When unsure, review.
4. **Who merges:** The agent squash-merges with `gh pr merge N --squash --delete-branch --match-head-commit <reviewed sha>` once CI (if any), proof and review pass on the head commit. A PR that touches a Hard stop, `AGENTS.md`, `.claude/`, `.githooks/` or the PR template waits for Victor.
5. A milestone is a set of GitHub issues under a GitHub milestone, written by the `victor-kit:vk-plan` skill. Each issue names a model tier (top, mid or cheap) and a suggested effort, and gets its own session, which ends when its PR merges. If a goal has to stop partway, hand it over with a `/vk-handoff` brief pasted into a new session. Never a handoff file in the repo.
6. When real work shows a skill or this file is wrong, missing a step or slower than it needs to be, fix it as `victor-kit:vk-ship` → *Build* → *Improve the skills* says.

The PR is the record. Don't create planning documents, status files or progress reports. Put out-of-scope problems in a new issue instead of widening the change.

**Decisions.** Make engineering calls yourself (architecture, approach, sequencing) and say what you chose in the PR. Stop and ask Victor only for product behavior, scope, money, security or a Hard stop: say the decision in plain English, your recommendation and its consequence. His chat answer is the approval. The PR is the record: quote his decision in its Decisions section, add the `decision` label, and write the resulting rule into the doc that governs it. A decision that changes no file gets a closed issue labelled `decision`. To see why something was decided: `gh pr list --state merged --label decision --search "<words>"`.

## Hard stops: ask Victor in chat, every time

An approval covers only the action it names.
- Merging a PR that touches a Hard stop, `AGENTS.md`, `.claude/`, `.githooks/` or the PR template, and pushing to `main` directly.
- Creating a GitHub repo, changing its visibility, or adding a remote.
- Destructive steps: deleting data, deleting a branch with unmerged work, force-pushing, rewriting shared history, discarding changes you didn't make.
- Reading, using or changing credentials; logging in to or changing any account.
- Sending anything on Victor's behalf, or spending money.
- Using Victor's real data or personal records. Use synthetic data in disposable folders.
- Weakening a rule in this file, `.claude/settings.json`, `.githooks/` or the GitHub ruleset on `main`, even temporarily. That includes `--no-verify` and changing `core.hooksPath`.
- Changing this Mac's DNS or network settings (including any port-53 listener or relay).
- Installing a configuration profile, system extension, certificate or browser policy.
- Running anything with `sudo`.
- Sending DNS queries to a public DNS server, including `scripts/live_smoke.py`.

## Engineering standards

- Make the smallest complete change. No speculative infrastructure; generalize at the second case.
- Simplest solution first: does it need to exist? If so, use what the codebase, the standard library or an installed dependency already has before writing new code. Never at the cost of validation, error handling or security.
- Changes that touch credentials, logins or permissions, outside network calls, outside input, file paths, shell commands, or prompts and agent instructions get a `vk-security` pass before review.
- A fix starts with a test that fails without it.
- Tests are named for behavior and use synthetic data in disposable temp folders outside the repo.
- No new third-party dependency without saying why in the PR.
- Unknown, stale or contradictory state fails closed.
- Never hide a failure by weakening or deleting an assertion, changing a contract, or replacing a real integration with a mock. Fix the cause or report it.
- Python code runs on Python 3.9+, the version `README.md` promises; dependencies are pinned in `requirements.txt`.
- Tests use loopback fixture DNS servers only and never send names to an external DNS server.

## Proof

| Command | When | Reviewer may run |
|---|---|---|
| `.venv/bin/python -m unittest discover -s tests -v` | every change | yes |
| `.venv/bin/python -m clearpath.policy policy.example.json` | every change | yes |
| `swiftc -typecheck -module-cache-path artifacts/swift-module-cache scripts/check_networkextension.swift` | every change | yes |
| run `clearpath.dns` or `clearpath.policy` on a synthetic policy in a temp folder, with a loopback fixture upstream | any behavior change | yes |

Set up once with `python3 -m venv .venv` and `.venv/bin/python -m pip install -r requirements.txt`.

Prove behavior at the boundary it crosses: real files in temp folders, loopback fixture DNS servers for upstream DNS, the real command line for the tool's interface. If something can't be run, say so in the PR; don't claim it's proven. There is no CI. The PR's Proof section is the record of what ran.

## Agents and skills

This repo uses the `victor-kit` plugin.
- `victor-kit:vk-ship` skill: carry a goal or issue to a ready PR.
- `victor-kit:reviewer` agent: independent read-only review against this file, the docs it lists, and Victor's decisions in the PR.
- The guards enforce this file; they don't redefine it. `.githooks/pre-push` refuses force-pushes, pushes straight to `main` and deleting `main`, from any tool. `.claude/settings.json` makes Claude Code ask before pushing to `main`, deleting a remote branch, or running the host-changing commands in Hard stops (`sudo`, `networksetup`, `scutil`, `profiles`, `systemextensionsctl`, `security add-trusted-cert`, `scripts/live_smoke.py`), and refuses force-pushes, skipping the hook, and deleting repos, releases or anything through `gh api`; it catches the common command forms, not every one. A public repo also has a GitHub ruleset on `main`.
