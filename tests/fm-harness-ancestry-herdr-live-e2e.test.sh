#!/usr/bin/env bash
# Token-free ancestry drift guard for supported primaries in a named Herdr lab.
# Real vendor process identities are inspected without submitting model prompts.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_HARNESS_ANCESTRY_HERDR_LIVE herdr jq
HELPER=${FM_HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$HELPER" name fm-retro-supervision-recovery)
SCRATCH=$(fm_test_tmproot fm-ancestry-live)
cleanup() {
  local rc=$?
  "$HELPER" teardown "$SESSION" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
lab() { "$HELPER" run "$SESSION" "$@"; }
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
checked=0
for harness in claude codex opencode pi pi-signed grok cursor omp; do
  binary=$(command -v "$harness" 2>/dev/null || true)
  if [ "$harness" = cursor ]; then
    # shellcheck source=bin/fm-cursor-lib.sh
    . "$ROOT/bin/fm-cursor-lib.sh"
    binary=$(fm_cursor_resolve_binary 2>/dev/null || true)
  fi
  if [ -z "$binary" ]; then
    printf '# absent: %s; not verified on this host\n' "$harness"
    continue
  fi
  version=$("$binary" --version 2>/dev/null | head -1) || version=unknown
  ws=$(lab workspace create --cwd "$SCRATCH" --label "ancestry-$harness" --no-focus)
  pane=$(printf '%s' "$ws" | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$pane" ] || fail "$harness ($version): lab did not return a pane"
  options=''
  [ "$harness" != codex ] || options=' --disable hooks'
  [ "$harness" != cursor ] || options=' --trust'
  lab pane run "$pane" "env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u NO_MISTAKES_GATE $(quote "$binary")$options" >/dev/null
  family=$harness
  [ "$harness" != pi-signed ] || family=pi
  verdicts=''
  for _ in $(seq 1 100); do
    info=$(lab pane process-info --pane "$pane")
    pids=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_processes[]?.pid')
    verdicts=''
    for pid in $pids; do
      verdict=$("$ROOT/bin/fm-harness.sh" ancestry "$pid")
      verdicts="$verdicts$verdict;"
    done
    case "$verdicts" in *"comm $family;"*) break ;; esac
    sleep 0.1
  done
  case "$verdicts" in
    *"comm $family;"*) pass "real $harness ($version): structural ancestry=$family" ;;
    *) fail "$harness ($version): no structural ancestry verdict; observed $verdicts; process-info=$info" ;;
  esac
  checked=$((checked + 1))
done
[ "$checked" -gt 0 ] || fail "no installed primary harness was checked"
printf '# checked %s installed primary harnesses; teardown verifies the unchanged default-session tripwire\n' "$checked"
