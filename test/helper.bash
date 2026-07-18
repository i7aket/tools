# Shared bats helpers. bash 3.2-safe (CI is bash 5; local macOS is the 3.2 gate).
REPO_ROOT_OF_PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$REPO_ROOT_OF_PLUGIN/i7aket/skills/codex-check/scripts/run.sh"
STUBS="$REPO_ROOT_OF_PLUGIN/test/stubs"

setup() {
  TESTTMP="$(mktemp -d "${TMPDIR:-/tmp}/cc-bats.XXXXXX")"
  CODEX_LOG="$TESTTMP/codex.log"; : > "$CODEX_LOG"
  export CODEX_LOG
  export PATH="$STUBS:$PATH"
  export CODEX_CHECK_NO_UPDATE_CHECK=1   # never hit the network in tests
}

teardown() {
  [[ -n "${WORKREPO:-}" ]] && git -C "$WORKREPO" worktree prune 2>/dev/null || true
  rm -rf "$TESTTMP" "${WORKREPO:-}" 2>/dev/null || true
}

# make_repo: create a throwaway repo with an origin so base-ref logic works.
# Echoes the working repo path. Sets WORKREPO for teardown.
make_repo() {
  local up="$TESTTMP/upstream.git" wr="$TESTTMP/work"
  git init -q --bare "$up"
  git init -q "$wr"
  git -C "$wr" config user.email t@t; git -C "$wr" config user.name t
  git -C "$wr" remote add origin "$up"
  git -C "$wr" commit -q --allow-empty -m "AAA-0 base"
  git -C "$wr" branch -M main
  git -C "$wr" push -q -u origin main
  git -C "$wr" remote set-head origin main 2>/dev/null || true
  WORKREPO="$wr"; echo "$wr"
}

codex_ran()    { grep -q '^codex-invoked' "$CODEX_LOG"; }
codex_oid()    { sed -n 's/^codex-invoked oid=//p' "$CODEX_LOG" | tail -n1; }
codex_args()   { sed -n 's/^codex-args://p' "$CODEX_LOG" | tail -n1; }
