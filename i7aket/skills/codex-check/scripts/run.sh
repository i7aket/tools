#!/usr/bin/env bash
# codex-check: send an implementation plan to the local Codex CLI for an
# independent high-reasoning review against the branch the PLAN targets, its
# tracker ticket (if an issue-tracker MCP is configured for Codex) and its PR.
#
# Codex runs in an isolated, detached git worktree (sandbox: workspace-write).
# The report is captured via `codex exec -o`. The worktree is always removed
# (trap EXIT). Works in any git repo; nothing here is project-specific.
#
# Usage: run.sh [PLAN_PATH] [--ref <rev> | --branch <name>] [--model <name>] [--pre-implementation]
#   PLAN_PATH optional. If omitted, the newest candidate is auto-detected from
#   common plan/spec locations (see locate step). Override search dirs with
#   CODEX_CHECK_PLAN_DIRS (colon-separated).
#   --ref <rev> (or env CODEX_CHECK_REF) reviews against any commit-ish — a SHA,
#   tag, detached PR head, origin/pr/*, or branch — resolved to an OID. Highest
#   priority; the safest choice in a many-worktree repo.
#   --branch <name> (or env CODEX_CHECK_BRANCH) reviews against that exact branch.
#   --model <name> (or env CODEX_CHECK_MODEL) pins the Codex model (passed as
#   `codex exec -m`). Unset -> whatever the user's ~/.codex/config.toml selects.
#   --pre-implementation explicitly reviews the plan against the base ref with no
#   target branch (otherwise "no branch for the ticket" is a hard error, not a
#   silent base review).
#
# What it reviews against (TARGET), highest priority first:
#   A) --ref / CODEX_CHECK_REF        -> that commit-ish (resolved to an OID)
#   B) --branch / CODEX_CHECK_BRANCH  -> that branch (validated, resolved to an OID)
#   C) the plan's own ticket          -> the unique branch carrying that ticket key;
#                                        if none, ABORT (unless --pre-implementation)
#   D) --pre-implementation / Ticket: none -> the base ref, no target branch
# The plan is the source of truth for the ticket (a `Ticket:` metadata line), NOT
# whatever branch happens to be checked out. Target identity must be explicit or
# uniquely resolved — the script fails closed rather than guessing.
#
# Output: writes <plan>.codex-review.md next to the plan, and prints that path
# as the LAST stdout line. Progress goes to stderr as "[codex-check] ...".

set -euo pipefail

log() { printf '[codex-check] %s\n' "$*" >&2; }
die() { printf '[codex-check] ERROR: %s\n' "$*" >&2; exit 1; }

# Ticket key (Jira/Linear/YouTrack style, e.g. ABC-123) out of an arbitrary string.
ticket_of() { printf '%s' "${1:-}" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -n1 || true; }
# Resolve a ref to a commit OID, safely (rejects flags via --end-of-options, forces a commit).
resolve_oid() { git rev-parse --verify --quiet --end-of-options "$1^{commit}" 2>/dev/null || true; }

# --- 0. Preflight -----------------------------------------------------------
command -v codex >/dev/null 2>&1 || die "codex CLI not found in PATH (https://developers.openai.com/codex)"
command -v git   >/dev/null 2>&1 || die "git not found in PATH"
# Inherited Git env selectors override repo/worktree discovery (git docs), so a
# stale GIT_DIR/GIT_WORK_TREE leaked from a parent process would silently point
# git at the wrong repo regardless of CWD. Clear them before the first git call.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_NAMESPACE 2>/dev/null || true
ORIG_PWD="$PWD"   # capture BEFORE the cd, so a relative plan path resolves where the caller meant it
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$REPO_ROOT"

# --- 0a. Argument parsing: PLAN_PATH, target selector, pre-implementation ----
PLAN_PATH=""; PLAN_SET=0
REQ_REF="${CODEX_CHECK_REF:-}"         # env default; --ref overrides. Highest priority.
REQ_BRANCH="${CODEX_CHECK_BRANCH:-}"   # env default; --branch overrides
REQ_MODEL="${CODEX_CHECK_MODEL:-}"     # env default; --model overrides. Unset -> Codex config default.
PRE_IMPL=0
set_plan() { [[ "$PLAN_SET" -eq 0 ]] && { PLAN_PATH="$1"; PLAN_SET=1; } || die "unexpected extra argument: $1"; }
END_OPTS=0
while [[ $# -gt 0 ]]; do
  if [[ "$END_OPTS" -eq 1 ]]; then set_plan "$1"; shift; continue; fi
  case "$1" in
    --ref)               shift; [[ $# -gt 0 ]] || die "--ref requires a value"; REQ_REF="$1" ;;
    --ref=*)             REQ_REF="${1#--ref=}" ;;
    --branch)            shift; [[ $# -gt 0 ]] || die "--branch requires a value"; REQ_BRANCH="$1" ;;
    --branch=*)          REQ_BRANCH="${1#--branch=}" ;;
    --model)             shift; [[ $# -gt 0 ]] || die "--model requires a value"; REQ_MODEL="$1" ;;
    --model=*)           REQ_MODEL="${1#--model=}" ;;
    --pre-implementation) PRE_IMPL=1 ;;
    --)         END_OPTS=1 ;;                                 # everything after is positional
    -*)         die "unknown option: $1" ;;
    *)          set_plan "$1" ;;
  esac
  shift
done

# --- 0b. Best-effort, non-blocking newer-version check ----------------------
# Never fails the run; opt out with CODEX_CHECK_NO_UPDATE_CHECK=1.
version_check() {
  [[ -n "${CODEX_CHECK_NO_UPDATE_CHECK:-}" ]] && return 0
  command -v curl >/dev/null 2>&1 || return 0
  local manifest local_v remote_v
  manifest="${CLAUDE_PLUGIN_ROOT:-}/.claude-plugin/plugin.json"
  [[ -f "$manifest" ]] || manifest="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd)/.claude-plugin/plugin.json"
  [[ -f "$manifest" ]] || return 0
  local_v="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9.]+"' "$manifest" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  [[ -n "$local_v" ]] || return 0
  remote_v="$(curl -fsS --max-time 3 \
    https://raw.githubusercontent.com/i7aket/tools/master/i7aket/.claude-plugin/plugin.json 2>/dev/null \
    | grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9.]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  [[ -n "$remote_v" ]] || return 0
  # numeric semver compare: remote strictly greater than local?
  local IFS=.; local -a L=($local_v) R=($remote_v); local i
  for i in 0 1 2; do
    local l="${L[$i]:-0}" r="${R[$i]:-0}"
    if   (( r > l )); then
      log "a newer version ($remote_v) is available — run: /plugin marketplace update tools && /plugin update i7aket@tools"
      return 0
    elif (( r < l )); then return 0
    fi
  done
}
version_check || true

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  GH_OK=1
else
  GH_OK=0; log "note: gh missing or not authenticated — PR context will be skipped"
fi

# --- 1. Locate the plan -----------------------------------------------------
if [[ -n "$PLAN_PATH" ]]; then
  # A relative plan path was meant relative to the CALLER's CWD, not REPO_ROOT.
  # Resolve it against ORIG_PWD (captured before the cd) before checking.
  [[ "$PLAN_PATH" != /* && -f "$ORIG_PWD/$PLAN_PATH" ]] && PLAN_PATH="$ORIG_PWD/$PLAN_PATH"
  [[ -f "$PLAN_PATH" ]] || die "given plan path does not exist: $PLAN_PATH"
else
  # Default search locations; override with CODEX_CHECK_PLAN_DIRS (colon-separated).
  IFS=':' read -r -a SEARCH_DIRS <<< "${CODEX_CHECK_PLAN_DIRS:-docs/plans:docs/specs:plans:specs:docs}"
  for dir in "${SEARCH_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
      # newest regular *.md file, excluding previously generated reviews
      cand="$(find "$dir" -maxdepth 1 -type f -name '*.md' ! -name '*.codex-review.md' -print0 2>/dev/null \
        | xargs -0 ls -t 2>/dev/null | head -n1 || true)"
      [[ -n "$cand" ]] && { PLAN_PATH="$cand"; break; }
    fi
  done
  [[ -n "$PLAN_PATH" ]] || die "no plan found (searched: ${SEARCH_DIRS[*]}) — pass a plan path explicitly: /codex-check:codex-check path/to/plan.md"
fi
PLAN_PATH="$(cd "$(dirname "$PLAN_PATH")" && pwd)/$(basename "$PLAN_PATH")"  # absolute (for cp/read)
PLAN_REL="${PLAN_PATH#"$REPO_ROOT"/}"   # repo-relative for logs/report — never leak absolute local paths
log "plan: $PLAN_REL"

# --- 2. Resolve the base branch (don't assume 'main') -----------------------
BASE_REF=""
if git symbolic-ref --quiet refs/remotes/origin/HEAD >/dev/null 2>&1; then
  BASE_REF="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"  # e.g. origin/main
fi
if [[ -z "$BASE_REF" ]]; then
  for c in origin/main origin/master main master; do
    if git rev-parse --verify --quiet "$c" >/dev/null 2>&1; then BASE_REF="$c"; break; fi
  done
fi
log "base ref: ${BASE_REF:-<none>}"

# --- 2a. Freshen ALL remote-tracking refs BEFORE picking a target ----------
# (workspace-write can't write .git inside a linked worktree, so fetch out here.)
# A plain `git fetch origin <branch>` only updates that one ref — it would NOT
# discover a remote-only ticket branch (origin/fix/ABC-123) during Mode B
# enumeration. Fetch the whole remote so origin/* is current, which also
# freshens the base ref.
FETCH_OK=1; HAS_ORIGIN=0
if git remote get-url origin >/dev/null 2>&1; then
  HAS_ORIGIN=1
  if git fetch origin --prune >/dev/null 2>&1; then
    log "fetched origin/* (prune)"
  else
    FETCH_OK=0
    log "note: git fetch origin --prune failed — remote-tracking refs may be stale"
  fi
fi

# --- 3. Current branch (for the mismatch guard) and the plan's own ticket ----
CURRENT_BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null \
  || git for-each-ref --format='%(refname:short)' --points-at HEAD refs/heads 2>/dev/null | head -n1 \
  || true)"
CURRENT_TICKET="$(ticket_of "$CURRENT_BRANCH")"

# The plan is the source of truth. Look for a `Ticket:` line only in the METADATA
# REGION — the head of the file, up to the first Markdown section heading (`## `)
# or a YAML front-matter terminator. This stops a `Ticket:` inside body prose or a
# fenced code block from hijacking the target (which would recreate the very
# wrong-target bug we're fixing).
#
# Body-wide ticket guessing is deliberately NOT used to choose the target: a stray
# key in prose could mis-target a wrong (or empty) review that still looks valid.
# If there is no metadata `Ticket:` line, the target must come from --ref/--branch
# or --pre-implementation; otherwise the script fails closed below (Mode C).
PLAN_TICKET=""; PLAN_TICKET_EXPLICIT=0
# Metadata region = the file head up to the first Markdown heading (any level),
# bounded to 40 lines. A leading YAML front-matter block (delimited by --- on
# line 1 and a closing ---) is kept as metadata. We do NOT exempt line 1 from
# the heading fence: a line-1 `## ` is a section, not metadata (else a body
# Ticket: could leak in and hijack the target).
META_REGION="$(awk '
  NR==1 && $0=="---" { infm=1; print; next }
  infm && $0=="---" { infm=0; print; next }
  infm { print; next }
  /^#+[[:space:]]/ { exit }
  { print }
  NR>=40 { exit }
' "$PLAN_PATH" 2>/dev/null || true)"
META_LINE="$(printf '%s\n' "$META_REGION" | grep -iE '^[[:space:]]*Ticket:[[:space:]]*' | head -n1 || true)"
if [[ -n "$META_LINE" ]]; then
  PLAN_TICKET_EXPLICIT=1
  # Match "none" as a whole token (Ticket: none), not as a prefix of e.g. "noneABC".
  if printf '%s' "$META_LINE" | grep -qiE 'Ticket:[[:space:]]*none([[:space:]]|$)'; then
    PLAN_TICKET=""   # explicit "none" → no ticket-based branch lookup
  else
    PLAN_TICKET="$(ticket_of "$META_LINE")"
  fi
fi

# --- 3a. Resolve TARGET (what we review against) ----------------------------
# Priority: A) --ref  B) --branch  C) the plan's ticket → unique branch
#           D) --pre-implementation / Ticket:none → base ref.
# When target identity is weak (no explicit ref/branch and the ticket maps to no
# unique branch), the script FAILS CLOSED with a candidate list instead of
# silently reviewing the base ref or an ambient HEAD.
TARGET_REF="" ; TARGET_OID="" ; TARGET_DESC=""
# Reusable candidate list for fail-closed messages: worktrees + ticket-matching refs.
candidates() {
  printf 'worktrees:\n'; git worktree list 2>/dev/null | sed 's/^/  /'
  if [[ -n "$PLAN_TICKET" ]]; then
    printf 'refs carrying %s:\n' "$PLAN_TICKET"
    { git for-each-ref --format='%(refname:short)' refs/remotes/origin refs/heads 2>/dev/null \
        | grep -E "(^|[^A-Z0-9])$PLAN_TICKET([^0-9]|$)" | sed 's/^/  /'; } || true
  fi
}
if [[ -n "$REQ_REF" ]]; then
  # Mode A — explicit commit-ish: SHA, tag, branch, origin/pr/* head, detached OID.
  TARGET_OID="$(resolve_oid "$REQ_REF")"
  [[ -n "$TARGET_OID" ]] || die "requested --ref '$REQ_REF' does not resolve to a commit in $REPO_ROOT"
  # Best-effort human-friendly name; falls back to the short OID.
  TARGET_REF="$REQ_REF"
  TARGET_DESC="explicit --ref $REQ_REF"
elif [[ -n "$REQ_BRANCH" ]]; then
  # Mode A — explicit branch. Accept both a bare head name (feat/ABC-123) and an
  # origin-prefixed name (origin/feat/ABC-123), since users copy the latter from
  # `git` output and from this script's own ambiguity error.
  _bare="${REQ_BRANCH#origin/}"
  git check-ref-format --branch "$_bare" >/dev/null 2>&1 || die "invalid branch name: $REQ_BRANCH"
  if [[ "$REQ_BRANCH" == origin/* ]]; then
    _cands=("refs/remotes/origin/$_bare" "refs/heads/$_bare")   # explicit origin/ → prefer remote
  else
    _cands=("refs/heads/$_bare" "refs/remotes/origin/$_bare")
  fi
  for cand in "${_cands[@]}"; do
    TARGET_OID="$(resolve_oid "$cand")"
    [[ -n "$TARGET_OID" ]] && { TARGET_REF="${cand#refs/heads/}"; TARGET_REF="${TARGET_REF#refs/remotes/}"; break; }
  done
  [[ -n "$TARGET_OID" ]] || die "requested branch '$REQ_BRANCH' not found locally or on origin"
  TARGET_DESC="explicit --branch $TARGET_REF"
elif [[ "$PRE_IMPL" -eq 1 ]]; then
  # Explicit user intent: review against the base ref regardless of any ticket
  # branch. (Outranks ticket resolution, but not an explicit --ref/--branch.)
  TARGET_REF="$BASE_REF"; TARGET_OID="$(resolve_oid "$BASE_REF")"
  TARGET_DESC="--pre-implementation → base ref ${BASE_REF:-<none>}"
elif [[ -n "$PLAN_TICKET" ]]; then
  # Mode B — the unique branch carrying the plan's ticket key (exact equality).
  # bash 3.2-safe (macOS stock): no mapfile, no associative arrays.
  # Enumerate origin/* FIRST so that when a local branch and its origin mirror
  # share a name we keep the remote (PR-backed review should track origin), and
  # warn if the two have diverged so a stale local checkout can't change the
  # target silently.
  _uniq=() ; _seen_keys=" "
  while IFS= read -r r; do
    [[ -z "$r" ]] && continue
    [[ "$(ticket_of "$r")" == "$PLAN_TICKET" ]] || continue
    key="${r#origin/}"
    case "$_seen_keys" in
      *" $key "*)
        # already kept the origin/ side; flag divergence if the local OID differs
        if [[ "$r" != origin/* ]]; then
          lo="$(resolve_oid "$r")"; ro="$(resolve_oid "origin/$key")"
          [[ -n "$lo" && -n "$ro" && "$lo" != "$ro" ]] && \
            log "note: local '$key' and 'origin/$key' differ — reviewing origin/$key (pass --branch '$key' to force local)"
        fi
        continue ;;
    esac
    _seen_keys="$_seen_keys$key "
    _uniq+=("$r")
    # NB: two separate for-each-ref passes (remote THEN heads) — a single call
    # sorts by full refname and would not honor argument order, letting a local
    # branch win over its origin mirror.
  done < <({ git for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null; \
             git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null; })
  # Mode B depends on freshly-fetched remote-tracking refs. A failed fetch could
  # hide a just-pushed branch or leave a stale OID — fail closed unless opted out.
  if [[ "$HAS_ORIGIN" -eq 1 && "$FETCH_OK" -eq 0 && -z "${CODEX_CHECK_ALLOW_STALE:-}" ]]; then
    die "git fetch failed and the target is resolved from the plan's ticket ($PLAN_TICKET) — refs may be stale. Pass --ref/--branch, or set CODEX_CHECK_ALLOW_STALE=1 to accept stale refs."
  fi
  if   [[ "${#_uniq[@]}" -eq 1 ]]; then
    TARGET_REF="${_uniq[0]}"; TARGET_OID="$(resolve_oid "$TARGET_REF")"
    TARGET_DESC="branch for $PLAN_TICKET: $TARGET_REF"
  elif [[ "${#_uniq[@]}" -gt 1 ]]; then
    die "ambiguous: multiple branches carry $PLAN_TICKET (${_uniq[*]}) — pass --ref or --branch to choose"
  else
    die "no branch carries the plan's ticket $PLAN_TICKET, and no --ref/--branch was given.
Refusing to silently review the base ref. Choose one:
  - pass --ref <rev> or --branch <name> for the branch to review, or
  - pass --pre-implementation to review the plan against ${BASE_REF:-<base>} on purpose.
$(candidates)"
  fi
elif [[ "$PLAN_TICKET_EXPLICIT" -eq 1 ]]; then
  # Mode D — plan explicitly declares 'Ticket: none' → pre-implementation base.
  TARGET_REF="$BASE_REF"; TARGET_OID="$(resolve_oid "$BASE_REF")"
  TARGET_DESC="plan has 'Ticket: none' → pre-implementation against ${BASE_REF:-<none>}"
else
  die "the plan has no 'Ticket:' line and no --ref/--branch was given, so the review target is undefined.
Refusing to guess. Choose one:
  - add a 'Ticket: ABC-123' (or 'Ticket: none') line near the top of the plan, or
  - pass --ref <rev> / --branch <name> for the branch to review, or
  - pass --pre-implementation to review the plan against ${BASE_REF:-<base>} on purpose.
$(candidates)"
fi
# Safety net: if a chosen mode still produced no OID (e.g. base ref missing in an
# empty repo) we cannot proceed — do NOT silently fall back to ambient HEAD.
[[ -n "$TARGET_OID" ]] || die "could not resolve a commit to review against (target: ${TARGET_DESC:-none}) — pass --ref explicitly"
log "target: $TARGET_DESC"
log "plan ticket: ${PLAN_TICKET:-<none>} | current branch: ${CURRENT_BRANCH:-<detached>}"

# --- 3b. Mismatch guard -----------------------------------------------------
if [[ -z "$REQ_BRANCH" && -n "$PLAN_TICKET" && -n "$CURRENT_TICKET" && "$PLAN_TICKET" != "$CURRENT_TICKET" ]]; then
  log "WARNING: plan targets $PLAN_TICKET but the working tree is on $CURRENT_TICKET."
  log "Reviewing against $PLAN_TICKET. Pass --branch to override."
fi

# --- 5. Isolated worktree (mktemp, outside the project) + trap cleanup -------
SAFE_REF="$(printf '%s' "${TARGET_REF:-detached}" | tr -cs 'A-Za-z0-9._-' '-')"
WT="$(mktemp -d "${TMPDIR:-/tmp}/codex-check-${SAFE_REF}.XXXXXX")"
cleanup() {
  if [[ -n "${WT:-}" && -d "$WT" ]]; then
    git worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
    git worktree prune >/dev/null 2>&1 || true
    log "worktree removed"
  fi
}
trap cleanup EXIT
# A signal trap that only runs cleanup does NOT stop the script — bash resumes
# after the handler, so a SIGTERM'd run would continue and exit 0 (verified).
# These handlers clean up and exit with 128+signal so the run actually aborts.
trap 'cleanup; trap - INT TERM HUP EXIT; exit 130' INT
trap 'cleanup; trap - INT TERM HUP EXIT; exit 143' TERM
trap 'cleanup; trap - INT TERM HUP EXIT; exit 129' HUP
_wt_err="$(git worktree add --detach "$WT" "$TARGET_OID" 2>&1 >/dev/null)" \
  || die "git worktree add failed: ${_wt_err}"
mkdir -p "$WT/.codex-check"
cp "$PLAN_PATH" "$WT/.codex-check/PLAN.md"
REVIEW_IN_WT="$WT/CODEX_REVIEW.md"
log "worktree: $WT"

# --- 5a. Verify banner: surface the TARGET before the long Codex run --------
# Codex takes >10 min; a wrong target must be catchable in seconds, not after.
TARGET_SHORT="$(git rev-parse --short "$TARGET_OID" 2>/dev/null || echo "$TARGET_OID")"
AHEAD_BEHIND="n/a"
if [[ -n "$BASE_REF" ]]; then
  ab="$(git rev-list --left-right --count "$BASE_REF...$TARGET_OID" 2>/dev/null || true)"
  if [[ -n "$ab" ]]; then
    # rev-list --left-right --count BASE...TARGET prints "<behind>\t<ahead>"
    # (left = base-only = behind; right = target-only = ahead).
    read -r _behind _ahead <<<"$ab"
    AHEAD_BEHIND="ahead $_ahead / behind $_behind vs $BASE_REF"
  fi
fi
SRC_DIRTY="clean"; [[ -n "$(git status --porcelain 2>/dev/null)" ]] && SRC_DIRTY="DIRTY (uncommitted changes in $REPO_ROOT are NOT reviewed — only the committed target)"

# --- F7: plan/commit skew disclosure (diagnostic only) ----------------------
# Order matters: a symlink, an out-of-repo path, or a path untracked AT THE
# TARGET COMMIT must NOT be byte-compared (git show / cmp would mislead).
# "tracked" means tracked AT TARGET_OID, not merely in the working tree.
if [[ -L "$PLAN_PATH" ]]; then
  PLAN_STATUS="symlink (skew not checked)"
elif [[ "$PLAN_REL" == /* ]]; then
  # PLAN_REL still absolute => not under REPO_ROOT (e.g. a different worktree).
  PLAN_STATUS="out-of-repo"
elif ! git cat-file -e "${TARGET_OID}:${PLAN_REL}" 2>/dev/null; then
  PLAN_STATUS="untracked"   # not present at the target commit
elif cmp -s <(git show "${TARGET_OID}:${PLAN_REL}" 2>/dev/null) "$PLAN_PATH"; then
  PLAN_STATUS="matches"
else
  PLAN_STATUS="DIFFERS"
fi

log "──────────────────────────────────────────────"
log "REVIEWING  target : ${TARGET_DESC}"
log "REVIEWING  ref/oid: ${TARGET_REF:-<detached>} @ ${TARGET_SHORT}"
log "REVIEWING  vs base: ${AHEAD_BEHIND}"
log "REVIEWING  plan   : ${PLAN_REL} (ticket: ${PLAN_TICKET:-<none>})"
log "REVIEWING  plan st: PLAN STATUS: ${PLAN_STATUS}"
log "REVIEWING  source : ${REPO_ROOT} on ${CURRENT_BRANCH:-<detached>} — ${SRC_DIRTY}"
log "──────────────────────────────────────────────"

# --- 6. Build the review prompt --------------------------------------------
# Diff base: the resolved base ref; else the parent of the target commit; else
# none (initial-commit repo / no base) → review the plan "pre-implementation".
if [[ -n "$BASE_REF" ]]; then
  DIFF_BASE="$BASE_REF"
elif git rev-parse --verify --quiet "${TARGET_OID}~1" >/dev/null 2>&1; then
  DIFF_BASE="${TARGET_OID}~1"
else
  DIFF_BASE=""
fi
if [[ -n "$DIFF_BASE" ]]; then
  DIFF_LINE="3. What's already done: run \`git diff $DIFF_BASE...HEAD --stat\` (and inspect interesting hunks). Do NOT run \`git fetch\` (no write access to .git inside this worktree; the base ref was already refreshed outside). If there is no diff, treat the plan as \"pre-implementation\"."
else
  DIFF_LINE="3. What's already done: no base ref or parent commit is available, so there is no diff to inspect — treat the plan as \"pre-implementation\"."
fi
if [[ "$GH_OK" -eq 1 && -n "$TARGET_REF" ]]; then
  PR_LINE="2. PR: run \`gh pr list --state all --head \"${TARGET_REF#origin/}\" --json number,title,url,state,mergedAt\` (NOT open-only, or merged/closed PRs are missed). If none, say 'PR: none' and continue."
else
  PR_LINE="2. PR: gh is unavailable or there is no target branch — say 'PR: skipped' and continue."
fi
if [[ -n "$PLAN_TICKET" ]]; then
  TICKET_LINE="1. Ticket: the plan targets ticket key '$PLAN_TICKET'. If you have an issue-tracker MCP (Jira/Linear/YouTrack/etc.) configured, read that ticket and use it as the requirements source. If not, say 'Ticket: $PLAN_TICKET (no tracker MCP)' and continue."
else
  TICKET_LINE="1. Ticket: the plan declares no ticket. Say 'Ticket: none' and continue."
fi

read -r -d '' PROMPT <<EOF || true
You are an independent reviewer of an implementation plan. The plan is at ./.codex-check/PLAN.md — read it first.

Reviewing against: ${TARGET_DESC} (you are in a detached worktree at that commit — this is expected).
NOTE: PLAN STATUS = ${PLAN_STATUS}. If "DIFFERS" or "untracked", the plan file in
this worktree may not match the reviewed commit — call that out.
Gather context yourself:
$TICKET_LINE
$PR_LINE
$DIFF_LINE

Then review the plan itself:
- Verify it: is it implementable, does it agree with the ticket (if any) and the existing code. NB: the plan may legitimately be out of the ticket's scope if the plan is not itself a change to this branch (the branch may just be a test carrier) — that is not an error.
- Augment it: what is missing (steps, files, checks, edge cases).
- Find defects and blind spots (risks, hidden dependencies, backward compatibility, tests).
- Search the web for best practices on the plan's topic and cite sources.
- If you see a better approach than the plan proposes, suggest it with rationale.

Return your final report as your LAST answer (it is saved via -o), in English, with this structure:
VERDICT: ready / revise / rework.
CONTEXT: branch, ticket, PR (what you found).
NOTES: numbered list (if none, say so).
BEST PRACTICES: with links.
BETTER APPROACHES: if any.
SUMMARY: 2-3 sentences.

As the LAST line of your answer, with nothing after it, output verbatim exactly one of:
GATE=READY
GATE=REVISE
GATE=REWORK
(ASCII only, regardless of the language of the review above.)
EOF

# --- 7. Run Codex -----------------------------------------------------------
# Model: pinned via --model/CODEX_CHECK_MODEL, else Codex's own config default.
MODEL_ARGS=()
if [[ -n "$REQ_MODEL" ]]; then MODEL_ARGS=(-m "$REQ_MODEL"); fi
log "running codex exec (model ${REQ_MODEL:-from ~/.codex config}, xhigh, web_search, workspace-write) ..."
set +e
codex exec \
  -C "$WT" \
  ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
  -s workspace-write \
  -c model_reasoning_effort='"xhigh"' \
  -c web_search='"live"' \
  -o "$REVIEW_IN_WT" \
  "$PROMPT" >"$WT/codex-stdout.log" 2>"$WT/codex-stderr.log"
CODEX_RC=$?
set -e

# Success is decided by the REPORT, not by the exit code or by grepping logs.
# `-o` may write a complete report and then Codex exits non-zero on an unrelated
# post-run/MCP error — that report is still a valid review and must be kept.
# Likewise a successful run that merely *quotes* "401 Unauthorized" must never be
# read as our auth failing. So: a non-empty report wins; only an empty/missing
# report is a failure, and only then do we attribute a cause.
if [[ ! -s "$REVIEW_IN_WT" ]]; then
  # Genuinely no report. Decide whether it looks like an auth problem, and only
  # from Codex's own error lines (a leading ERROR/error: mentioning token/auth/401),
  # not from any occurrence anywhere in the transcript.
  log "codex stderr tail:"; tail -n 15 "$WT/codex-stderr.log" >&2 || true
  if grep -qiE '^[[:space:]]*(error[: ]).*(token_revoked|refresh_token_invalidated|unauthorized|401|re-?authenticate|codex login)' "$WT/codex-stderr.log" 2>/dev/null; then
    die "Codex auth failed — run: codex login, then retry"
  fi
  die "codex exec failed (rc=$CODEX_RC) and wrote no report"
fi
# Report exists. Note a non-zero exit but proceed — the review is usable.
[[ $CODEX_RC -ne 0 ]] && log "note: codex exited non-zero (rc=$CODEX_RC) but a report was written — keeping it"

# --- 8. Copy the report next to the plan -----------------------------------
# Strip only a real markdown extension from the basename (so e.g. ".features/plan"
# does NOT become "/repo/.codex-review.md" by treating ".features" as the extension).
PLAN_DIR="$(dirname "$PLAN_PATH")"
PLAN_BASE="$(basename "$PLAN_PATH")"
case "$PLAN_BASE" in
  *.md)       REVIEW_BASE="${PLAN_BASE%.md}.codex-review.md" ;;
  *.markdown) REVIEW_BASE="${PLAN_BASE%.markdown}.codex-review.md" ;;
  *)          REVIEW_BASE="${PLAN_BASE}.codex-review.md" ;;
esac
REVIEW_PATH="$PLAN_DIR/$REVIEW_BASE"
REVIEW_REL="${REVIEW_PATH#"$REPO_ROOT"/}"
{
  echo "# Codex review — $PLAN_BASE"
  echo
  echo "- Target: ${TARGET_DESC}"
  echo "- Target ref: ${TARGET_REF:-<detached>} (${TARGET_OID})"
  echo "- Target vs base: ${AHEAD_BEHIND}"
  echo "- Plan ticket: ${PLAN_TICKET:-<none>}"
  echo "- Source: ${REPO_ROOT} on ${CURRENT_BRANCH:-<detached>} — ${SRC_DIRTY}"
  echo "- Diff base: ${DIFF_BASE:-<none>}"
  echo "- Plan: $PLAN_REL"
  echo "- PLAN STATUS: ${PLAN_STATUS}"
  echo "- Model: Codex (xhigh, web_search), sandbox=workspace-write"
  echo
  echo "---"
  echo
  cat "$REVIEW_IN_WT"
} > "$REVIEW_PATH"
log "review written: $REVIEW_REL"
printf '%s\n' "$REVIEW_PATH"   # LAST line = the absolute review path (the command parses this to read the file)

# --- F8: opt-in severity gating (fail-closed) -------------------------------
# Only active when CODEX_CHECK_GATE is set. Parse a stable ASCII token from the
# report (NOT the free-text VERDICT, which may be non-English). Report path was
# already printed above, preserving the "last stdout line = report path" contract.
if [[ -n "${CODEX_CHECK_GATE:-}" ]]; then
  # `|| true`: under `set -euo pipefail` a no-match grep (rc 1) would otherwise
  # abort the script before the fail-closed `*)` case below could run.
  _gate="$(grep -E '^GATE=(READY|REVISE|REWORK)$' "$REVIEW_PATH" 2>/dev/null | tail -n1 || true)"
  case "$_gate" in
    GATE=READY)  exit 0 ;;
    GATE=REVISE) exit 2 ;;
    GATE=REWORK) exit 3 ;;
    *) log "gate: no GATE= token found in report — failing closed"; exit 2 ;;
  esac
fi
