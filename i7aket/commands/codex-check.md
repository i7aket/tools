---
description: Send the current implementation plan to the local Codex CLI for an independent high-reasoning review against an explicit branch/ref (+ ticket + PR), in an isolated git worktree
argument-hint: "path/to/plan.md [--ref <rev> | --branch <name>] [--pre-implementation]"
disable-model-invocation: true
---
Send the current implementation plan to the local Codex CLI for an independent review. All logic lives in a deterministic script: `${CLAUDE_PLUGIN_ROOT}/skills/codex-check/scripts/run.sh` (preflight, explicit-target resolution, base-ref auto-detect, `git fetch` outside the worktree, isolated worktree from the resolved target OID with trap cleanup, `codex exec -s workspace-write -o`, report copy). Arguments: a plan file path and a target selector — `$ARGUMENTS`.

The script picks what to review against from an **explicit target**, never the checked-out branch (the CWD can be a stale/unrelated worktree). Priority: `--ref <rev>` (any commit-ish: SHA, tag, branch, `origin/pr/*`) → `--branch <name>` → the plan's own `Ticket:` line resolved to the **unique** branch carrying that key. If the target identity is weak (no explicit ref/branch and the ticket maps to zero or several branches), the script **fails closed** with a candidate list instead of guessing.

Do this:

# 0. Resolve the target branch/ref FIRST (do not rely on the current directory)
The biggest failure mode is reviewing whatever branch the shell happens to be sitting in. Before launching, decide the target explicitly:

1. Read the plan's `Ticket:` line (near the top). If absent, ask the user for the ticket or the branch — don't guess.
2. Run `git worktree list` and/or `git branch -a` and find the branch carrying that ticket key.
3. If exactly one matches, pass it as `--branch <name>`. If several match, or you need a specific commit/PR head, pass `--ref <rev>`. **If you cannot unambiguously identify the target, STOP and ask the user** rather than launching a 10-minute review of the wrong thing.
4. Only use `--pre-implementation` when the plan is intentionally reviewed against the base ref (no implementing branch yet).

# 1. Run the script in the BACKGROUND
Codex with high reasoning + web search takes well over 10 minutes, so launch the script as a **background task** (do not block the session). Pass each argument **separately quoted** (a path may contain spaces); never interpolate `$ARGUMENTS` raw into a larger shell string:

- With an explicit ref (preferred): `"${CLAUDE_PLUGIN_ROOT}/skills/codex-check/scripts/run.sh" "<the path>" --ref "<sha-or-rev>"`
- With an explicit branch: `"${CLAUDE_PLUGIN_ROOT}/skills/codex-check/scripts/run.sh" "<the path>" --branch "<the branch>"`
- Pre-implementation (base ref, on purpose): `"${CLAUDE_PLUGIN_ROOT}/skills/codex-check/scripts/run.sh" "<the path>" --pre-implementation`

Never pass `$ARGUMENTS` raw/unquoted onto a command line — quote each token, or omit it when empty. The script accepts the plan path and the selector flags in any order and rejects unknown options.

A bare invocation (no plan, no target) is **not** a normal path: with no plan it auto-detects the newest `*.md` from `docs/plans/`, `docs/specs/`, `plans/`, `specs/`, `docs/` (override with `CODEX_CHECK_PLAN_DIRS`), but with no explicit target and no `Ticket:` line it will **abort** asking for `--ref`/`--branch`/`--pre-implementation`. Prefer passing an explicit plan path and target.

The script does everything itself: preflight (`codex`, `git`, optional `gh auth`; it also unsets any inherited `GIT_DIR`/`GIT_WORK_TREE`/… so a leaked env can't redirect repo discovery), reading the plan's `Ticket:` metadata line (the source of truth — body prose is NOT used to pick the target), resolving the review target to a commit OID (`--ref` → `--branch` → unique branch for the plan's ticket → fail-closed unless `--pre-implementation`), base-ref auto-detection (origin/HEAD → main/master → parent commit → none), `git fetch` OUTSIDE the worktree (inside `workspace-write` there is no write access to `.git`; a failed fetch is fatal for ticket-based resolution unless `CODEX_CHECK_ALLOW_STALE=1`), printing a `REVIEWING …` banner (target ref/OID, ahead-behind vs base, source worktree + dirty state) so a wrong target is catchable in seconds, creating a `mktemp` detached worktree at that OID, copying the plan into it, running `codex exec`, and ALWAYS removing the worktree via `trap EXIT`.

When `CODEX_CHECK_GATE` is set, the review ends with a `GATE=READY|REVISE|REWORK` token and the script exits 0/2/3 accordingly (missing token → exit 2, fail-closed). When it is unset (the default), the script always exits 0 on a written report — gating changes only the exit code, never the report or the stdout contract.

# 2. Wait for the background task to finish
You will be notified. Do not actively poll.

# 3. Report the result
- The script writes progress to stderr (`[codex-check] ...`) and, on its LAST stdout line, the absolute path to the review file.
- Read that review file (`<plan>.codex-review.md`, next to the plan).
- In chat, output: the VERDICT, 3-5 top notes, and the path to the review file.
- **Exit-code contract under `CODEX_CHECK_GATE`:** a non-zero exit of **2 or 3 with a report path on the last stdout line** is a *successful* REVISE/REWORK verdict — read and report it normally. It is NOT a failure. (READY → 0, REVISE → 2, REWORK → 3, missing token → 2 fail-closed.)

# Error handling
The script exits with a clear `[codex-check] ERROR: ...` message and cleans up the worktree itself (trap). Possible causes: codex/git missing, plan not found, an **undefined target** (no `Ticket:` line and no `--ref`/`--branch` — pass one, or `--pre-implementation`), an **ambiguous ticket** (several branches carry the key — pass `--ref`/`--branch`), **no branch for the ticket** (pass a target or `--pre-implementation`), a failed fetch during ticket resolution (pass `--ref`/`--branch` or `CODEX_CHECK_ALLOW_STALE=1`), an unknown/missing branch, worktree creation failed, or Codex wrote no report. These fail-closed aborts are intentional — they prevent silently reviewing the wrong or empty target. Success is decided by the report: if `-o` wrote a non-empty review it is kept even if Codex then exits non-zero (a stray post-run/MCP error must not discard a valid review). Only a missing/empty report is a failure, and only then is auth blamed (suggesting `codex login`) — and only when Codex's own error output looks like an auth problem, never because a successful review merely quoted a string like `401 Unauthorized`. Show the error message to the user verbatim. Under `CODEX_CHECK_GATE`, only a `[codex-check] ERROR: …` message with no report is a real failure; a gated 2/3 exit that still printed a report path is a successful gated verdict, not an error.

# Notes
- Web search in `codex exec` is enabled via `-c web_search='"live"'` (there is NO `--search` flag). The report is captured via `-o/--output-last-message`. These details are already in the script.
- The reviewer reasoning effort is forced to `xhigh`; the model is whatever the user's Codex config (`~/.codex/config.toml`) selects, unless pinned with `--model <name>` (or env `CODEX_CHECK_MODEL`), which is passed through as `codex exec -m`.
- Ticket reading requires an issue-tracker MCP (Jira/Linear/YouTrack/etc.) configured for Codex; PR context requires `gh`. Both are optional — without them, Codex notes what's missing and reviews the plan against the branch diff anyway.
