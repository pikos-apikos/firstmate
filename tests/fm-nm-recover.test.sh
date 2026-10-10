#!/usr/bin/env bash
# Supported custody recovery over real Git histories and a captured-CLI-shaped
# double. The double is not evidence that no-mistakes repairs a lost checkout.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity
TMP_ROOT=$(fm_test_tmproot fm-nm-recover)
RECOVER="$ROOT/bin/fm-nm-recover.sh"

make_case() {
  local d="$TMP_ROOT/$1" head
  mkdir -p "$d/fakebin"
  fm_git_init_commit "$d/wt"
  git -C "$d/wt" checkout -qb fm/recovery
  head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m candidate
  git -C "$d/wt" branch candidate
  git -C "$d/wt" checkout -q -b caller "$head"
  # The invoking branch and candidate are deliberately different refs.
  cat > "$d/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NM_CASE/calls"
head=$(git rev-parse candidate)
case "$*" in
  'axi status')
    state=${NM_STATE:-terminal_unpublished}
    next=recover_custody
    [ ! -f "$NM_CASE/recovered" ] || { state=custody_returned; next=run_pipeline; }
    printf 'run:\n  id: RUN1\n  branch: caller\n  status: failed\n  head_sha: %s\noutcome: failed\nbranch_sync:\n  state: %s\n  pipeline:\n    current_head: %s\n    worktree: %s/missing-checkout\n  next_action:\n    code: %s\n    command: no-mistakes axi sync --recover\n' "$head" "$state" "$head" "$NM_CASE" "$next"
    ;;
  'axi sync --check')
    printf 'branch_sync:\n  state: %s\n' "${NM_STATE:-terminal_unpublished}"
    ;;
  'axi sync --recover')
    [ "${NM_REFUSE:-0}" != 1 ] || { printf 'branch_sync:\n  state: blocked_missing_worktree\n'; exit 1; }
    git merge --ff-only candidate >/dev/null
    touch "$NM_CASE/recovered"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$d/fakebin/no-mistakes"
  printf '%s\n' "$d"
}

recover() { NM_CASE="$1" PATH="$1/fakebin:$PATH" "$RECOVER" "$1/wt" RUN1 "${@:2}"; }

d=$(make_case clean)
before=$(git -C "$d/wt" rev-parse HEAD)
recover "$d" > "$d/check"
[ "$(git -C "$d/wt" rev-parse HEAD)" = "$before" ] || fail "read-only recovery moved HEAD"
recover "$d" --apply > "$d/applied"
assert_contains "$(cat "$d/applied")" 'custody_returned' "CLI must confirm custody return"
[ "$(git -C "$d/wt" rev-parse HEAD)" = "$(git -C "$d/wt" rev-parse candidate)" ] || fail "recovery did not use the candidate"
recover "$d" --apply > "$d/repeated"
[ "$(grep -c '^axi sync --recover$' "$d/calls")" = 1 ] || fail "repeated recovery reapplied mutation"
pass "read-only plan and repeated supported fast-forward custody return"

for kind in dirty divergent missing blocked; do
  d=$(make_case "$kind")
  case "$kind" in
    dirty) printf 'caller bytes\n' > "$d/wt/untracked" ;;
    divergent) git -C "$d/wt" commit -q --allow-empty -m caller ;;
    missing) export NM_REFUSE=1 ;;
    blocked) export NM_STATE=blocked_diverged ;;
  esac
  before=$(git -C "$d/wt" rev-parse HEAD)
  refs=$(git -C "$d/wt" show-ref)
  rc=0
  recover "$d" --apply > "$d/handoff" 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "$kind recovery must refuse"
  assert_contains "$(cat "$d/handoff")" 'handoff:' "$kind refusal lost its concrete handoff"
  assert_contains "$(cat "$d/handoff")" "$before" "caller head missing from evidence"
  assert_contains "$(cat "$d/handoff")" "$(git -C "$d/wt" rev-parse candidate)" "candidate missing from evidence"
  [ "$(git -C "$d/wt" rev-parse HEAD)" = "$before" ] || fail "$kind refusal moved caller HEAD"
  [ "$(git -C "$d/wt" show-ref)" = "$refs" ] || fail "$kind refusal changed preserved refs"
  if [ "$kind" = dirty ]; then
    [ "$(cat "$d/wt/untracked")" = 'caller bytes' ] || fail "dirty recovery changed caller bytes"
  fi
  unset NM_REFUSE NM_STATE
done
pass "missing checkout, divergence, CLI refusal and caller dirt preserve both histories"
