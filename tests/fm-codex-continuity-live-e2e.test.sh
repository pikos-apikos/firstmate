#!/usr/bin/env bash
# Opt-in credentialed Codex checkpoint verification inside a named Herdr lab.
# The real harness runs the foreground path and detects itself through nested
# helpers. A synthetic status event after expiry is recovered by the next call;
# this never claims that expiry itself provides an unattended callback.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CODEX_LIVE_E2E codex herdr jq
HELPER=${FM_HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
LAB_HOME_HELPER=${FM_LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
SESSION=$("$HELPER" name fm-retro-supervision-recovery)
LAB=$(fm_test_tmproot fm-codex-continuity)
HOME_DIR="$LAB/home"
TRANSCRIPT="$LAB/codex.jsonl"
CODEX_VERSION=$(codex --version)
cleanup() {
  local rc=$?
  if [ -f "$HOME_DIR/.fm-lab-home" ]; then
    "$LAB_HOME_HELPER" teardown "$HOME_DIR" || rc=1
  fi
  "$HELPER" teardown "$SESSION" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$LAB_HOME_HELPER" create "$HOME_DIR" >/dev/null
"$HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
lab() { "$HELPER" run "$SESSION" "$@"; }
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
cat > "$LAB/deep.sh" <<'DEEP'
#!/usr/bin/env bash
if [ "$1" -gt 0 ]; then
  result=$(bash "$0" "$(( $1 - 1 ))" "$2")
else
  result=$(bash "$2")
fi
printf '%s\n' "$result"
DEEP
# shellcheck disable=SC2016 # These are literal instructions for the lab agent.
PROMPT='You are a worker in an isolated verification lab. Do only these five shell calls in order, all foreground: (1) bash bin/fm-watch-checkpoint.sh --seconds 1; exit 124 is expected. (2) printf "needs-decision: synthetic lab gate\n" > "$FM_HOME/state/demo.status". (3) bash bin/fm-watch-checkpoint.sh --seconds 8. (4) bash bin/fm-wake-drain.sh. (5) bash "$FM_HOME/../deep.sh" 12 "$PWD/bin/fm-harness.sh". Then reply briefly. Do not start supervision, run session-start, edit project files, delegate, or use background tasks.'
ws=$(lab workspace create --cwd "$ROOT" --label codex-checkpoint --no-focus)
pane=$(printf '%s' "$ws" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$pane" ] || fail "lab did not return a pane"
command="env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u NO_MISTAKES_GATE FM_HOME=$(quote "$HOME_DIR") codex exec --disable hooks --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -c 'model_reasoning_effort=\"low\"' --json $(quote "$PROMPT") >$(quote "$TRANSCRIPT") 2>&1; printf '%s' \$? >$(quote "$LAB/exit")"
lab pane run "$pane" "$command" >/dev/null
for _ in $(seq 1 1800); do
  [ ! -f "$LAB/exit" ] || break
  sleep 0.1
done
[ -f "$LAB/exit" ] || fail "$CODEX_VERSION: live checkpoint turn did not finish; $(tail -10 "$TRANSCRIPT")"
[ "$(cat "$LAB/exit")" = 0 ] || fail "$CODEX_VERSION: live checkpoint turn failed; $(tail -20 "$TRANSCRIPT")"
# Inspect actual command results, never the agent's plan or final prose.
python3 - "$TRANSCRIPT" <<'PY'
import json
import sys
results = []
for line in open(sys.argv[1], encoding="utf-8"):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    item = event.get("item", {})
    if event.get("type") == "item.completed" and item.get("type") == "command_execution":
        results.append(item.get("aggregated_output", ""))
assert any("checkpoint: no actionable wake within 1s" in r and "continuation-required:" in r for r in results), results
assert any("check: rearm-resurface" in r or "signal:" in r for r in results), results
assert any("needs-decision: synthetic lab gate" in r for r in results), results
assert any(r.strip() == "codex" for r in results), results
assert not any("watcher: started pid=" in r for r in results), results
PY
[ -s "$HOME_DIR/state/demo.status" ] || fail "live checkpoint lost the synthetic status event"
printf 'ok - %s: foreground expiry, later synthetic gate delivery, and deep structural ancestry verified\n' "$CODEX_VERSION"
