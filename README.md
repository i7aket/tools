# codex-check

A [Claude Code](https://code.claude.com) plugin that hands your implementation plan to the
local **[Codex CLI](https://developers.openai.com/codex)** for an independent, high-reasoning
review — against the current git branch, its tracker ticket, and its PR — and writes the
verdict next to your plan.

Use it after you've written a plan (and before you implement it) to get a fresh second opinion
that checks feasibility, finds gaps and risks, looks up best practices on the web, and proposes
better approaches.

## How it works

`/codex-check` runs a deterministic script that:

1. Auto-detects your plan (or takes a path argument).
2. Detects the branch (detached-worktree-safe) and any `ABC-123`-style ticket key.
3. Auto-detects the base ref (`origin/HEAD` → `main`/`master`) and fetches it **outside** the worktree.
4. Creates an **isolated, detached `git worktree`** so Codex can't touch your working tree.
5. Runs `codex exec -s workspace-write` with web search and `xhigh` reasoning; Codex reads the
   plan, the ticket (via an issue-tracker MCP if you have one), the PR (`gh`), and the branch diff.
6. Captures the report via `-o`, copies it to `<plan>.codex-review.md`, and **always removes the
   worktree** (`trap EXIT`).

Nothing is project-specific — it works in any git repo.

## Requirements

- A Unix-like shell with **Bash** and standard POSIX tools (`git`, `find`, `grep`, `mktemp`, `cp`, …).
  On Windows use WSL or Git Bash.
- [Codex CLI](https://developers.openai.com/codex) installed and authenticated (`codex login`).
- *(Optional)* `gh` authenticated — for PR context.
- *(Optional)* an issue-tracker MCP (Jira / Linear / YouTrack / …) configured **for Codex** — for ticket context.

## Install

### Identity reference

| Thing             | Value                          |
|-------------------|--------------------------------|
| GitHub repo       | `i7aket/tools`                 |
| Marketplace name  | `tools`                        |
| Plugin name       | `i7aket`                       |
| Command           | `/i7aket:codex-check`          |
| Install path      | `~/.claude/plugins/cache/tools/i7aket/<version>` |

Install:
```text
/plugin marketplace add i7aket/tools
/plugin install i7aket@tools
```
Update (run BOTH):
```text
/plugin marketplace update tools
/plugin update i7aket@tools
```

> **If an update doesn't take:** re-run **both** commands above (the marketplace
> cache must refresh before the plugin sees a new version). Use only these
> supported commands.

## Usage

```text
/i7aket:codex-check path/to/plan.md --ref <sha-or-rev>      # review against any commit-ish (preferred)
/i7aket:codex-check path/to/plan.md --branch feat/ABC-123   # review against an explicit branch
/i7aket:codex-check path/to/plan.md --pre-implementation    # review against the base ref, on purpose
/i7aket:codex-check path/to/plan.md --model gpt-5.6-sol     # pin the Codex model (else ~/.codex config)
/i7aket:codex-check path/to/plan.md                         # target from the plan's Ticket: line
```

Plugin commands are namespaced as `/<plugin>:<command>`, so the command is `/i7aket:codex-check`.

The review takes ~10–13 minutes (high reasoning + web search), so it runs in the background;
you'll be notified when it's done. The verdict appears in chat and the full report is saved to
`<plan>.codex-review.md` next to the plan. Before the long run, a `REVIEWING …` banner prints the
resolved target (ref, OID, ahead/behind vs base) so you can catch a wrong target in seconds.

### What it reviews against

The target is always **explicit or uniquely resolved** — never whatever branch your shell happens
to be sitting in (it may be a stale or unrelated worktree). Priority:

1. `--ref <rev>` (or `CODEX_CHECK_REF`) — any commit-ish: a SHA, tag, branch, `origin/pr/*`, or
   detached PR head. The safest choice in a many-worktree repo.
2. `--branch <name>` (or `CODEX_CHECK_BRANCH`) — that exact branch.
3. Otherwise the plan's own ticket: add a `Ticket: ABC-123` line near the top, and codex-check
   finds the **unique** branch carrying that key and reviews against it.
4. `--pre-implementation` (or `Ticket: none`) — reviews the plan against the base ref with no
   target branch.

It **fails closed** rather than guessing: no `Ticket:` line and no `--ref`/`--branch` → it aborts
and asks for one; a ticket that maps to no branch → it aborts unless you pass `--pre-implementation`;
two branches carry the key → it aborts and asks you to choose. So a stray checkout can't silently
produce a wrong (or empty) verdict.

## Updating

Claude Code does **not** auto-notify or auto-update plugins — a marketplace is a cached git repo,
and nothing polls GitHub. To pull a new version, run **both**:

```text
/plugin marketplace update tools
/plugin update i7aket@tools
```

Without `marketplace update` first, the local cache never learns a new version exists. codex-check
also prints a one-line notice at the start of a run when a newer version is published (best-effort,
silent if offline; opt out with `CODEX_CHECK_NO_UPDATE_CHECK=1`).

### Where it looks for a plan

In order: `docs/plans/`, `docs/specs/`, `plans/`, `specs/`, `docs/` — the newest `*.md` (generated
`*.codex-review.md` files are ignored). Override the search list with the `CODEX_CHECK_PLAN_DIRS`
env var (colon-separated), or just pass an explicit path.

## Notes

- Web search in `codex exec` is enabled via the `web_search` config key (there is no `--search` flag).
- Runs Codex in `workspace-write` (not full bypass): writes are confined to the temporary worktree.
- The base ref is auto-detected — whatever `origin/HEAD` points to, else `main`/`master`, else the
  parent commit, else none (the plan is reviewed "pre-implementation").
- Generated reviews record the **repo-relative** plan path, not your absolute local path.

## License

MIT — see [LICENSE](LICENSE).
