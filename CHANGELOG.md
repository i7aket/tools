# Changelog

All notable changes to this plugin are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.0] — 2026-07-18

### Added
- `--model <name>` / env `CODEX_CHECK_MODEL` — pin the Codex model for the
  review (passed through as `codex exec -m`; flag overrides env). Unset keeps
  the previous behavior: whatever `~/.codex/config.toml` selects. The
  "running codex exec" progress line now names the effective model source.
  Covered by `test/model_selection.bats` (default/flag/env/override/fail-closed).

## [1.3.0] — 2026-06-27

### Added
- `--ref <rev>` is now exercised by tests; opt-in **severity gating** via a stable
  `GATE=READY|REVISE|REWORK` token (`CODEX_CHECK_GATE`): exit 0/2/3, fail-closed
  (missing token → 2). The report path is still the last stdout line.
- A `PLAN STATUS` line (banner + report + prompt) disclosing whether the plan
  file matches / differs from / is untracked at the reviewed commit.
- A bats + shellcheck CI gate (GitHub Actions) pinning the fail-closed
  target-resolution contract; shellcheck is blocking.

### Changed / Fixed
- Cancelled (`SIGTERM`/`SIGHUP`/`INT`) background runs now **abort** (exit
  128+signal) and no longer leak a worktree — a naive shared `EXIT` trap would
  have resumed and exited 0.
- `git worktree add` failures now surface git's real error message.
- Simplified the ahead/behind banner (one `read`, no `awk` subshells) and
  deleted a dead `BASE_BRANCH` variable.
- README gains an identity table + supported-paths-only update recovery note.

## [1.2.0] — 2026-06-27

Hardening of the v1.1.0 target resolution after two independent audits (a
multi-agent adversarial review and a Codex `xhigh` review) found that v1.1.0
could still *silently* review a wrong or empty target when target identity was
weak. The script now **fails closed** instead of guessing.

### Added
- `--ref <rev>` / `CODEX_CHECK_REF`: review against any commit-ish — a SHA, tag,
  branch, `origin/pr/*`, or detached PR head — resolved to an OID. Highest
  priority; the safest selector in a many-worktree repo.
- `--pre-implementation`: explicitly review the plan against the base ref with no
  target branch (previously this happened silently).
- A `REVIEWING …` banner (first stderr lines + report header): target ref/OID,
  ahead/behind vs the base ref, and the source worktree + its dirty state — so a
  wrong target is catchable in seconds, not after a 10-minute Codex run.
- `CODEX_CHECK_ALLOW_STALE=1` to proceed with ticket-based resolution when
  `git fetch` failed (otherwise that is now fatal — a stale ref could mis-target).

### Changed
- **Fail-closed targeting.** No `Ticket:` line and no `--ref`/`--branch` → abort
  with a candidate list (was: guess the ticket from body prose). A ticket that
  maps to no branch → abort unless `--pre-implementation` (was: silently review
  the base ref). The script never silently falls back to the ambient HEAD.
- Body-wide ticket guessing is no longer used to choose the target (a stray key
  in prose could mis-target). Only a metadata `Ticket:` line selects the target.
- Inherited `GIT_DIR` / `GIT_WORK_TREE` / `GIT_COMMON_DIR` / `GIT_INDEX_FILE` /
  `GIT_NAMESPACE` are unset before the first git call, so a leaked env can't
  redirect repository discovery.
- A relative plan path is resolved against the caller's original CWD (before the
  internal `cd` to the repo root), not against the repo root.
- `command.md` now instructs the assistant to resolve the target explicitly
  (plan ticket + `git worktree list`) and pass `--ref`/`--branch`, stopping on
  ambiguity; a bare no-target invocation is no longer presented as a normal path.

## [1.1.0] — 2026-06-27

### Changed
- The review target now comes from the **plan**, not from whatever branch is checked out.
  Resolution priority: explicit `--branch <name>` (or `CODEX_CHECK_BRANCH`) → the unique
  branch carrying the plan's `Ticket:` key → pre-implementation against the base ref. The
  worktree is created from a resolved commit OID, so remote-only branches work too.
- Repository renamed `i7aket/codex-check` → `i7aket/tools`; install is now
  `/plugin marketplace add i7aket/tools`. (The old URL still redirects.)

### Added
- `--branch <name>` / `CODEX_CHECK_BRANCH` to review against an explicit branch.
- A loud warning when the plan's ticket differs from the checked-out branch's ticket.
- An ambiguity guard: if two branches carry the plan's ticket key, the run stops and asks
  for `--branch`.
- A best-effort newer-version notice at startup (numeric semver compare; silent if offline;
  opt out with `CODEX_CHECK_NO_UPDATE_CHECK=1`).

### Fixed
- False "token revoked" abort. The auth check used to grep the whole Codex stderr for
  `401 Unauthorized` / `token_revoked`, which matched when Codex merely *quoted* such a
  string (e.g. reviewing this very script) or when an unrelated MCP server logged a 401 —
  killing a successful run. Success is now decided by the report: a non-empty review from
  `-o` is kept even if Codex then exits non-zero; only a missing/empty report is a failure,
  and auth is blamed only when Codex's own error output looks like an auth problem.
- `bash` 3.2 portability (stock macOS): removed `mapfile` / associative arrays.

## [1.0.1]

- Initial published release: independent Codex review of an implementation plan in an
  isolated, auto-cleaned git worktree.
