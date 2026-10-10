#!/usr/bin/env bash
# Inspect or apply the supported terminal no-mistakes custody boundary.
# Usage: fm-nm-recover.sh <invoking-worktree> <expected-run-id> [--apply]
#
# Default is read-only. --apply permits only the exact ordinary
# `no-mistakes axi sync --recover` action offered by current-branch CLI status,
# for a terminal run and an available candidate at or descending from the
# clean caller HEAD. The CLI rechecks its own custody and push-binding guards.
# Missing ephemeral checkouts are not recreated or edited here: the supported
# CLI must recover them or refuse. Already-returned custody is a verified no-op.
# No keep-local, archive binding, reset-equivalent adoption, divergent history
# integration, database write, or fabricated custody result is supported here.
#
# Every refusal prints a handoff with CLI state, caller head/dirt, candidate,
# and retained refs. Redirect the output to the task's private evidence file;
# preserve that file and both histories for supervisor/upstream resolution.
# Exit 0 means a safe read-only plan or CLI-confirmed custody; 1 means handoff;
# 2 means usage error. An interrupted apply must be inspected again, never
# treated as proof that the CLI did or did not return custody.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ] || { [ "$#" -eq 3 ] && [ "$3" != --apply ]; }; then
  echo 'usage: fm-nm-recover.sh <invoking-worktree> <expected-run-id> [--apply]' >&2
  exit 2
fi
WT=$1 RUN=$2 APPLY=${3:-}
case "$RUN" in ''|*[!a-zA-Z0-9_-]*) echo 'error: invalid run id' >&2; exit 2 ;; esac
STATUS='' PLAN='' CANDIDATE='' HEAD='' BRANCH='' DIRT=''
handoff() {
  printf 'handoff: run=%s reason=%s\ncaller: branch=%s head=%s\ncandidate: %s\n' \
    "$RUN" "$*" "$BRANCH" "$HEAD" "${CANDIDATE:-unknown}"
  printf 'caller status (porcelain):\n%s\nCLI status:\n%s\nCLI sync plan:\n%s\nretained refs:\n' "$DIRT" "$STATUS" "$PLAN"
  git -C "$WT" for-each-ref --format='%(refname) %(objectname)' 2>/dev/null || true
  printf 'current caller HEAD/status (after refused or interrupted action):\n'
  git -C "$WT" rev-parse --verify HEAD 2>/dev/null || true
  git -C "$WT" status --porcelain=v1 --untracked-files=all 2>/dev/null || true
  echo 'next: preserve caller work and candidate refs; resolve through the supported no-mistakes CLI or hand this evidence to its maintainer; do not reset, stash, discard, or integrate divergent histories automatically'
  exit 1
}
HEAD=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || handoff 'caller HEAD unavailable'
BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null) || handoff 'caller is detached'
DIRT=$(git -C "$WT" status --porcelain=v1 --untracked-files=all) || handoff 'caller dirt unreadable'
STATUS=$(fm_nm_run_bounded "$WT" 10 axi status 2>&1) || handoff 'CLI status unavailable'
[ "$(fm_nm_strip_quotes "$(fm_nm_field "$STATUS" id)")" = "$RUN" ] || handoff 'current branch selects another or unknown run'
[ "$(fm_nm_strip_quotes "$(fm_nm_field "$STATUS" branch)")" = "$BRANCH" ] || handoff 'CLI branch does not match caller'
CANDIDATE=$(fm_nm_branch_sync_nested "$STATUS" pipeline current_head)
[ -n "$CANDIDATE" ] || CANDIDATE=$(fm_nm_strip_quotes "$(fm_nm_field "$STATUS" head_sha)")
[ -z "$DIRT" ] || handoff 'dirty caller; preserve its tracked and untracked work'
if fm_nm_run_is_active "$STATUS"; then handoff 'run is active; its worker must continue driving it'; fi
SYNC_STATE=$(fm_nm_branch_sync_state "$STATUS")
case "$SYNC_STATE" in
  custody_returned|user_owned)
    [ "$HEAD" = "$CANDIDATE" ] || handoff 'returned custody does not prove caller equals candidate'
    printf 'custody: run=%s state=%s head=%s (CLI-confirmed no-op)\n' "$RUN" "$SYNC_STATE" "$HEAD"
    exit 0 ;;
  blocked*|'') handoff "unsupported CLI state: ${SYNC_STATE:-unknown}" ;;
esac
[ "$(fm_nm_branch_sync_nested "$STATUS" next_action code)" = recover_custody ] || handoff 'CLI does not offer terminal recovery'
[ "$(fm_nm_branch_sync_nested "$STATUS" next_action command)" = 'no-mistakes axi sync --recover' ] \
  || handoff 'CLI action requires separate authority or unsupported recovery semantics'
case "$CANDIDATE" in ''|*[!a-fA-F0-9]*) handoff 'candidate identity unavailable' ;; esac
[ "${#CANDIDATE}" -eq 40 ] || handoff 'candidate identity is not a full commit'
[ "$(fm_nm_resolve_commit "$WT" "$CANDIDATE")" = "$CANDIDATE" ] || handoff 'candidate object unavailable locally; do not invent a replacement'
git -C "$WT" merge-base --is-ancestor "$HEAD" "$CANDIDATE" || handoff 'caller and candidate diverged; both histories remain preserved'
PLAN=$(fm_nm_run_bounded "$WT" 10 axi sync --check 2>&1) || handoff 'CLI sync check refused'
case "$(fm_nm_branch_sync_state "$PLAN")" in blocked*|'') handoff 'CLI sync plan is blocked or unreadable' ;; esac
if [ -z "$APPLY" ]; then
  printf 'recovery-plan: run=%s caller=%s candidate=%s action=no-mistakes axi sync --recover (not applied)\n%s\n' "$RUN" "$HEAD" "$CANDIDATE" "$PLAN"
  exit 0
fi
PLAN=$(fm_nm_run_bounded "$WT" 30 axi sync --recover 2>&1) || handoff 'supported CLI recovery refused; preserve the missing-checkout/divergence evidence for upstream'
STATUS=$(fm_nm_run_bounded "$WT" 10 axi status 2>&1) || handoff 'recovery result unverified; inspect before retrying'
[ "$(fm_nm_strip_quotes "$(fm_nm_field "$STATUS" id)")" = "$RUN" ] || handoff 'recovery result belongs to another run'
[ "$(fm_nm_branch_sync_state "$STATUS")" = custody_returned ] || handoff 'CLI did not confirm custody_returned'
[ "$(git -C "$WT" rev-parse HEAD)" = "$CANDIDATE" ] || handoff 'caller does not carry the candidate after recovery'
[ -z "$(git -C "$WT" status --porcelain=v1 --untracked-files=all)" ] || handoff 'caller became dirty during recovery'
printf 'custody: run=%s state=custody_returned head=%s (CLI-confirmed)\n' "$RUN" "$CANDIDATE"
