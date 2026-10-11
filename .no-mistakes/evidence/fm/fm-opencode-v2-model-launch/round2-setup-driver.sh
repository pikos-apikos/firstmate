#!/usr/bin/env bash
set -eu
. "$PWD/.l/env.sh"
mkdir -p "$LAB/bin" "$LAB/project" "$LAB/wt" "$LAB/tmp" "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"
bin/fm-lab-home.sh create "$FM_HOME"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf 'opencode\n' > "$FM_HOME/config/crew-harness"
touch "$FM_HOME/state/.last-watcher-beat"
TMUX_BIN=$(command -v tmux)
OPENCODE_BIN=$(command -v opencode)
printf '#!/usr/bin/env bash\nexec %q -L fm-lab "$@"\n' "$TMUX_BIN" > "$LAB/bin/tmux"
printf '#!/usr/bin/env bash\nexec %q --standalone "$@"\n' "$OPENCODE_BIN" > "$LAB/bin/opencode"
chmod +x "$LAB/bin/tmux" "$LAB/bin/opencode"
for repo in project wt; do
  git -C "$LAB/$repo" init -q -b main
  git -C "$LAB/$repo" -c user.name=live-test -c user.email=live@example.invalid commit --allow-empty -qm init
done
mkdir -p "$LAB/wt/.opencode" "$FM_HOME/data/oc-live"
cat > "$FM_HOME/data/oc-live/brief.md" <<'BRIEF'
# Task
## Captain's intent
Verify the selected model by replying with exactly LIVE_MODEL_OK.

## Firstmate spec
This is a disposable live model selection check. Reply with exactly LIVE_MODEL_OK and stop. Do not use tools or create files. Completion requires only that reply.
BRIEF
cat > "$FM_HOME/state/oc-live.meta" <<META
window=firstmate:fm-oc-live
endpoint_task_id=oc-live
worktree=$LAB/wt
project=$LAB/project
harness=opencode
kind=ship
mode=local-only
yolo=off
model=default
effort=default
META
tmux -f /dev/null new-session -d -s firstmate -n fm-oc-live -x 180 -y 50 -c "$LAB/wt" 'bash --noprofile --norc'
tmux set-window-option -t firstmate:fm-oc-live automatic-rename off
printf '%s\n' '{"model":"opencode/big-pickle","permission":{"read":"ask"},"agent":{"build":{"temperature":0.4}}}' > "$LAB/wt/.opencode/opencode.json"
cp "$LAB/wt/.opencode/opencode.json" "$EVIDENCE/round2-config-before.json"
bin/fm-spawn.sh oc-live --relaunch --model opencode/space-bunny-free
cp "$LAB/wt/.opencode/opencode.json" "$EVIDENCE/round2-config-selected.json"
