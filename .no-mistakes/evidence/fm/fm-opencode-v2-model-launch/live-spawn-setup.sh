#!/usr/bin/env bash
set -eu
. "$(dirname "$0")/env.sh"
mkdir -p "$LAB/bin" "$LAB/project" "$LAB/wt"
bash "$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf 'opencode\n' > "$FM_HOME/config/crew-harness"
touch "$FM_HOME/state/.last-watcher-beat"
cat > "$LAB/bin/tmux" <<EOF
#!/usr/bin/env bash
exec /usr/bin/tmux -S '$ROOT/.oc-socket' "\$@"
EOF
cat > "$LAB/bin/opencode" <<'EOF'
#!/usr/bin/env bash
exec /home/pikos/.opencode/bin/opencode --standalone "$@"
EOF
chmod +x "$LAB/bin/tmux" "$LAB/bin/opencode"
for repo in project wt; do
  git -C "$LAB/$repo" init -q -b main
  git -C "$LAB/$repo" -c user.name=live-test -c user.email=live@example.invalid commit --allow-empty -qm init
done
mkdir -p "$LAB/wt/.opencode" "$FM_HOME/data/oc-live"
cat > "$FM_HOME/data/oc-live/brief.md" <<'EOF'
# Task
## Captain's intent
Verify the selected model by replying with exactly LIVE_MODEL_OK.

## Firstmate spec
This is a disposable live model selection check. Reply with exactly LIVE_MODEL_OK and stop. Do not use tools or create files. Completion requires only that reply.
EOF
cat > "$FM_HOME/state/oc-live.meta" <<EOF
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
EOF
tmux -f /dev/null new-session -d -s firstmate -n fm-oc-live -x 180 -y 50 -c "$LAB/wt" 'bash --noprofile --norc'
tmux set-window-option -t firstmate:fm-oc-live automatic-rename off
printf '%s\n' '{"model":"opencode/big-pickle","permission":{"read":"ask"},"agent":{"build":{"temperature":0.4}}}' > "$LAB/wt/.opencode/opencode.json"
cp "$LAB/wt/.opencode/opencode.json" "$LAB/config-before.json"
bash "$ROOT/bin/fm-spawn.sh" oc-live --relaunch --model opencode/space-bunny-free
