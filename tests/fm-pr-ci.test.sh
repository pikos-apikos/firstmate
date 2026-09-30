#!/usr/bin/env bash
# Open-pull-request CI watch behavior: which pull requests it is allowed to read,
# what it wakes on, and what it stays silent about.
#
# The check's whole value depends on two things a test must pin hard: it reads only
# this fleet's own pull requests inside the captain's configured scope, and it
# reports a change once rather than on every cycle. Both are asserted here through
# the poll's real behavior, including the forge calls it actually makes, so a
# widening of either limit fails a test instead of quietly becoming noise.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-pr-ci)
NOW=2026-09-30T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
# The repositories this fleet's own pull requests live on, and the one it must
# never touch even though the local clone's origin points at it.
OURS=https://github.com/pikos-apikos/icms/pull/7
FORK=https://github.com/pikos-apikos/firstmate/pull/8
UPSTREAM=https://github.com/kunchenguid/firstmate/pull/9
STRANGER=https://github.com/someone-else/firstmate/pull/10

# A home with the captain's scope, a gh that logs every call, and no forge state
# yet. Echoes the home.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin" "$home/forge"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf 'pikos-apikos\n' > "$home/config/forge-scope"
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
# Every call is logged, so a test can prove a repository was never read at all
# rather than inferring it from silence.
set -eu
printf '%s\n' "$*" >> "$FORGE/calls.log"
case "$*" in
  *statusCheckRollup*) cat "$FORGE/view.json" ;;
  *'/branches/'*'/rules/'*|*'/rules/branches/'*) cat "$FORGE/rules.json" 2>/dev/null || printf '[]\n' ;;
  *'/branches/'*) cat "$FORGE/protection.json" 2>/dev/null || printf '{"protected":false}\n' ;;
  *'/check-runs'*) cat "$FORGE/producers.json" 2>/dev/null || printf '[]\n' ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
  chmod +x "$home/fakebin/gh"
  printf '%s\n' "$home"
}

# A structured backlog row linking a pull request, which is how this fleet claims
# ownership of one.
own_pull_request() { # home id url
  printf -- '- [ ] %s - Watched delivery %s %s (repo: sample) (kind: ship)\n' \
    "$2" "$2" "$3" >> "$1/data/backlog.md"
}

poll() { # home
  with_home "$1" "$ROOT/bin/fm-pr-ci.sh" poll
}

# Every script in this suite runs against the fixture home with the fixture gh on
# PATH, so a test drives the real binaries rather than a reimplementation.
with_home() { # home command...
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PR_CI_NOW="$NOW" "$@"
}

# The live GitHub view for one head, with the given rollup entries verbatim, so a
# test can drive several runs of one check name the way GitHub does after it
# cancels an in-flight run and re-triggers it.
set_view() { # home <rollup-entry-json>...
  local home=$1 entry rollup=''
  shift
  for entry in "$@"; do
    rollup="${rollup:+$rollup,}$entry"
  done
  jq -n --arg head "$HEAD_A" --argjson rollup "[$rollup]" '{
    state:"OPEN", isDraft:false, mergeable:"MERGEABLE", mergeStateStatus:"CLEAN",
    headRefOid:$head, baseRefName:"main", statusCheckRollup:$rollup}' \
    > "$home/forge/view.json"
}

check_run() { # name status conclusion [startedAt]
  local name=$1 status=$2 conclusion=${3:--} started=${4:--}
  printf '{"__typename":"CheckRun","name":"%s","status":"%s","conclusion":%s,"startedAt":%s}' \
    "$name" "$status" \
    "$(if [ "$conclusion" = - ]; then printf null; else printf '"%s"' "$conclusion"; fi)" \
    "$(if [ "$started" = - ]; then printf null; else printf '"%s"' "$started"; fi)"
}

green() { check_run "$1" COMPLETED SUCCESS 2026-09-30T07:00:00Z; }
red() { check_run "$1" COMPLETED FAILURE 2026-09-30T07:00:00Z; }
running() { check_run "$1" IN_PROGRESS - 2026-09-30T07:00:00Z; }

calls() { cat "$1/forge/calls.log" 2>/dev/null || true; }
read_url() { jq -r --arg url "$2" '.urls[$url] // empty | .checks | to_entries | map(.key + "=" + .value) | join(" ")' "$1/state/.pr-ci-state.json"; }

# The reason a supervisor is woken for a pull request going red, exactly once.
test_green_to_red_wakes_exactly_once() {
  local home out first
  home=$(new_home green-to-red)
  own_pull_request "$home" watched "$OURS"
  set_view "$home" "$(green java)" "$(green lint)"
  out=$(poll "$home")
  [ -z "$out" ] || fail "a fully green pull request must be silent, got: $out"
  # Nothing was red, so nothing is remembered as a conclusion to change from.
  set_view "$home" "$(red java)" "$(green lint)"
  out=$(poll "$home")
  case "$out" in
    *"$OURS"*) ;;
    *) fail "a newly failing check must name the pull request's full URL, got: $out" ;;
  esac
  case "$out" in
    *java*) ;;
    *) fail "a newly failing check must name the failing check, got: $out" ;;
  esac
  case "$out" in
    *lint*) fail "a check that stayed green is not part of a failure report: $out" ;;
  esac
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] || fail "a sweep must report on one line, got: $out"
  # A repeat sweep with nothing changed is the whole reason this check is not a
  # nuisance: it must say nothing at all.
  first=$(poll "$home")
  [ -z "$first" ] || fail "an unchanged repeat sweep must be silent, got: $first"
  first=$(poll "$home")
  [ -z "$first" ] || fail "a second unchanged sweep must be silent, got: $first"
  grep -q "$OURS" "$home/forge/calls.log" || fail 'the owned pull request was never read'
  pass 'a check going green to red wakes exactly once and repeats stay silent'
}

# A recovery is the other half of a conclusion changing, and it must be reported
# without a red check being invented.
test_recovery_wakes_once() {
  local home out
  home=$(new_home recovery)
  own_pull_request "$home" watched "$OURS"
  set_view "$home" "$(red java)"
  out=$(poll "$home")
  case "$out" in
    *java*is\ failing*) ;;
    *) fail "the first observation of a failure must be reported, got: $out" ;;
  esac
  set_view "$home" "$(green java)"
  out=$(poll "$home")
  case "$out" in
    *"java on $OURS recovered"*) ;;
    *) fail "a recovered check must be reported with its URL and name, got: $out" ;;
  esac
  out=$(poll "$home")
  [ -z "$out" ] || fail "a recovery must not repeat, got: $out"
  pass 'a recovered check wakes once and a repeat sweep is silent'
}

# A lane that has not finished is not a failure, and it must not erase the
# conclusion the lane already had.
test_running_check_is_never_a_failure() {
  local home out
  home=$(new_home running)
  own_pull_request "$home" watched "$OURS"
  set_view "$home" "$(red java)" "$(green lint)"
  out=$(poll "$home")
  case "$out" in *"java on $OURS is failing"*) ;; *) fail "fixture did not record the failure: $out" ;; esac
  set_view "$home" "$(running java)" "$(green lint)"
  out=$(poll "$home")
  [ -z "$out" ] || fail "a merely running lane must not be reported as failing, got: $out"
  # The failure is still the stored conclusion, so the re-run going green reads as
  # a recovery rather than as a lane that was never broken.
  [ "$(read_url "$home" "$OURS")" = 'java=failing lint=passing' ] \
    || fail "a running lane replaced the stored conclusion: $(read_url "$home" "$OURS")"
  set_view "$home" "$(green java)" "$(green lint)"
  out=$(poll "$home")
  case "$out" in
    *"java on $OURS recovered"*) ;;
    *) fail "the re-run going green must recover the original failure, got: $out" ;;
  esac
  pass 'a running lane is not a failure and keeps the conclusion it already had'
}

# A required check that has not reported is a different fact from a failure, and
# it is reported once rather than on every cycle.
test_unreported_required_check_wakes_once() {
  local home out
  home=$(new_home unreported)
  own_pull_request "$home" watched "$OURS"
  printf '{"protected":true,"protection":{"required_status_checks":{"checks":[{"context":"qodana","app_id":null}],"contexts":[]}}}\n' \
    > "$home/forge/protection.json"
  set_view "$home" "$(green java)"
  out=$(poll "$home")
  case "$out" in
    *required\ check\ qodana*) ;;
    *) fail "a required check that never reported must be disclosed once, got: $out" ;;
  esac
  case "$out" in
    *"is failing"*) fail "an unreported required check must not be reported as failing: $out" ;;
  esac
  out=$(poll "$home")
  [ -z "$out" ] || fail "an unchanged unreported required check must not repeat, got: $out"
  set_view "$home" "$(green java)" "$(green qodana)"
  out=$(poll "$home")
  [ -z "$out" ] || fail "a required check that finally reported is not a conclusion change, got: $out"
  pass 'a required check that never reported is disclosed once and never called a failure'
}

# A required set that cannot be read is unmeasured, and guessing would be exactly
# the wrong "unreported" notice this check exists to avoid.
test_unreadable_required_set_stays_silent() {
  local home out
  home=$(new_home unreadable-required)
  own_pull_request "$home" watched "$OURS"
  printf 'not json\n' > "$home/forge/protection.json"
  set_view "$home" "$(green java)"
  out=$(poll "$home")
  [ -z "$out" ] || fail "an unreadable required set must not be turned into a notice, got: $out"
  pass 'an unreadable required set stays silent rather than guessing'
}

# A pull request nobody in this fleet owns is never read, however red it is.
test_unowned_pull_request_is_never_swept() {
  local home out
  home=$(new_home unowned)
  set_view "$home" "$(red java)"
  out=$(poll "$home")
  [ -z "$out" ] || fail "a pull request this fleet does not own must be silent, got: $out"
  [ ! -s "$home/forge/calls.log" ] \
    || fail "a pull request nobody owns was read: $(calls "$home")"
  pass 'a red pull request belonging to nobody in this fleet is never swept'
}

# The captain's scope is a preference, not something a clone's remote decides. The
# firstmate clone in a home points at the upstream while the pull requests this
# fleet owns live on the captain's fork, so a check that trusted the remote would
# poll the wrong repository and miss all of them.
test_scope_beats_the_clone_remote() {
  local home out
  home=$(new_home scope)
  own_pull_request "$home" forkwatched "$FORK"
  own_pull_request "$home" upstreamwatched "$UPSTREAM"
  own_pull_request "$home" strangerwatched "$STRANGER"
  set_view "$home" "$(green java)"
  out=$(poll "$home")
  [ -z "$out" ] || fail "a green in-scope pull request must be silent, got: $out"
  grep -q "$FORK" "$home/forge/calls.log" \
    || fail "the captain's own fork must be swept: $(calls "$home")"
  case "$(calls "$home")" in
    *kunchenguid*) fail "a kunchenguid repository was swept: $(calls "$home")" ;;
  esac
  case "$(calls "$home")" in
    *someone-else*) fail "an unlisted owner was swept: $(calls "$home")" ;;
  esac
  # The fork's red check is really watched, not merely permitted: an in-scope
  # failure surfaces, and nothing outside the scope is ever named.
  set_view "$home" "$(red java)"
  out=$(poll "$home")
  case "$out" in
    *"java on $FORK is failing"*) ;;
    *) fail "a red check on the captain's own fork must be reported, got: $out" ;;
  esac
  case "$out" in
    *kunchenguid*|*someone-else*) fail "an out-of-scope pull request was reported: $out" ;;
  esac
  pass "the captain's fork is swept and the upstream it was cloned from never is"
}

# Narrower than an owner: a single repository can be permitted on its own.
test_scope_can_name_one_repository() {
  local home out
  home=$(new_home narrow-scope)
  printf 'pikos-apikos/icms\n' > "$home/config/forge-scope"
  own_pull_request "$home" watched "$OURS"
  own_pull_request "$home" forkwatched "$FORK"
  set_view "$home" "$(red java)"
  poll "$home" >/dev/null
  grep -q "$OURS" "$home/forge/calls.log" || fail "the named repository must be swept: $(calls "$home")"
  case "$(calls "$home")" in
    *firstmate*) fail "a repository outside a narrow scope was swept: $(calls "$home")" ;;
  esac
  pass 'a scope naming one repository sweeps that repository and no other'
}

# An absent or unusable scope is not permission to sweep more. It reports once,
# sweeps nothing, and keeps what it knew, so restoring the scope resumes the
# deduplication instead of re-alarming about everything at once.
test_missing_scope_sweeps_nothing() {
  local home out
  home=$(new_home missing-scope)
  own_pull_request "$home" watched "$OURS"
  set_view "$home" "$(red java)"
  rm -f "$home/config/forge-scope"
  out=$(poll "$home")
  case "$out" in
    *forge-scope*) ;;
    *) fail "an absent scope must be disclosed, got: $out" ;;
  esac
  [ ! -s "$home/forge/calls.log" ] || fail "an absent scope still read the forge: $(calls "$home")"
  out=$(poll "$home")
  [ -z "$out" ] || fail "an unchanged absent scope must not repeat, got: $out"
  # An unreadable scope is the same answer, not a wider one.
  printf 'pikos apikos\n' > "$home/config/forge-scope"
  out=$(poll "$home")
  [ -z "$out" ] || fail "the same broken scope must not report again, got: $out"
  [ ! -s "$home/forge/calls.log" ] || fail "an unusable scope still read the forge: $(calls "$home")"
  # Restoring the scope resumes the deduplication instead of re-alarming about
  # everything at once, because the record kept what it knew.
  printf 'pikos-apikos\n' > "$home/config/forge-scope"
  out=$(poll "$home")
  case "$out" in
    *forge-scope*) ;;
    *) fail "a restored scope must be disclosed once, got: $out" ;;
  esac
  out=$(poll "$home")
  [ -z "$out" ] || fail "the first sweep after a restored scope reports once, got: $out"
  pass 'an absent or unusable scope sweeps nothing, reports once, and keeps the record'
}

# A red check on the very first sweep of a fleet that never watched anything is the
# case the captain reported: the failure was there for hours and nothing noticed.
test_first_sweep_reports_an_existing_failure() {
  local home out
  home=$(new_home first-sweep)
  own_pull_request "$home" watched "$OURS"
  set_view "$home" "$(red java)" "$(green lint)"
  out=$(poll "$home")
  case "$out" in
    *"java on $OURS is failing"*) ;;
    *) fail "a failure already present on the first sweep must surface, got: $out" ;;
  esac
  pass 'a failure that predates the check is reported on the first sweep'
}

# A closed or merged pull request is not an open pull request any more.
test_closed_pull_request_is_not_swept() {
  local home
  home=$(new_home closed)
  own_pull_request "$home" watched "$OURS"
  set_view "$home" "$(red java)"
  jq '.state = "MERGED"' "$home/forge/view.json" > "$home/forge/view.tmp"
  mv "$home/forge/view.tmp" "$home/forge/view.json"
  poll "$home" >/dev/null
  [ ! -s "$home/state/.pr-ci-state.json" ] \
    || jq -e '.urls | length == 0' "$home/state/.pr-ci-state.json" >/dev/null \
    || fail "a merged pull request was recorded as an open one"
  pass 'a merged pull request is not watched as an open one'
}

# The sweep is a fleet check, so registering it produces a check whose id is not a
# task id. That is the whole reason a task teardown cannot retire it.
test_arm_registers_a_fleet_check() {
  local home out snapshot
  home=$(new_home arm)
  out=$(with_home "$home" "$ROOT/bin/fm-pr-ci.sh" arm) || fail "arm failed: $out"
  [ -f "$home/state/pr-ci.check.sh" ] || fail 'arm did not register the fleet check'
  [ -f "$home/state/pr-ci.check-trust" ] || fail 'arm did not bind the check to its bytes'
  # The registration is the authenticated one the watcher requires, checked through
  # the same function the watcher calls rather than by reading its source.
  (
    # shellcheck source=bin/fm-pr-lib.sh disable=SC1091
    . "$ROOT/bin/fm-pr-lib.sh"
    # shellcheck source=bin/fm-check-lib.sh disable=SC1091
    . "$ROOT/bin/fm-check-lib.sh"
    fm_custom_check_registered "$home/state" pr-ci
  ) || fail 'the registered fleet check is not the authenticated one the watcher runs'
  # No task is named pr-ci, which is what keeps a task teardown away from it.
  snapshot=$(with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input) \
    || fail 'the fleet snapshot could not be read'
  printf '%s' "$snapshot" | jq -e '
    ([ (.tasks // [])[].id ] + [ (.backlog.records // [])[].id ]) | all(. != "pr-ci")' \
    >/dev/null || fail 'a task named pr-ci would make teardown retire the fleet check'
  pass 'arm registers the sweep as a fleet check named for no task'
}

# Task teardown retires "<task-id>.check.sh" for a task id. The fleet check is
# named for no task, so the real teardown must leave it and its trust binding
# alone while removing the task's own artifacts.
test_task_teardown_does_not_retire_the_fleet_check() {
  local home rc
  home="$TMP_ROOT/teardown"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" \
    "$home/fakebin" "$home/forge" "$home/wt"
  # A real In flight row, so the teardown has a backlog item to close itself.
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$home/data/backlog.md"
  # The title carries the pull request, so the row claims ownership of it and a
  # sweep has a reason to keep a record for it before the teardown runs.
  tasks-axi add task-x1 "teardown fixture $OURS" --kind ship \
    --file "$home/data/backlog.md" >/dev/null
  tasks-axi start task-x1 --file "$home/data/backlog.md" >/dev/null
  printf 'pikos-apikos\n' > "$home/config/forge-scope"
  for tool in treehouse tmux no-mistakes; do
    printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/$tool"
  done
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/gh-axi"
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/gh"
  chmod +x "$home/fakebin/"*
  # A real landed task: its branch is on origin, so teardown may proceed.
  git init -q --bare "$home/origin.git"
  git init -q "$home/project"
  git -C "$home/project" config user.email fmtest@example.invalid
  git -C "$home/project" config user.name fmtest
  git -C "$home/project" commit -q --allow-empty -m base
  git -C "$home/project" branch -M main
  git -C "$home/project" remote add origin "$home/origin.git"
  git -C "$home/project" push -q origin main
  git -C "$home/project" worktree add -q -b fm/task-x1 "$home/wt"
  git -C "$home/wt" commit -q --allow-empty -m "shippable work"
  git -C "$home/wt" push -q origin fm/task-x1
  git -C "$home/project" fetch -q origin
  fm_write_meta "$home/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
    "worktree=$home/wt" "project=$home/project" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=pr-ci-teardown-fixture" \
    "repo=sample" "branch=fm/task-x1" "pr=https://github.com/pikos-apikos/icms/pull/7" \
    "pr_head=$HEAD_A" "pr_provider=github"
  # The task's own per-task check artifacts, which teardown does own.
  printf '#!/bin/sh\nexit 0\n' > "$home/state/task-x1.check.sh"
  chmod 700 "$home/state/task-x1.check.sh"
  shasum -a 256 "$home/state/task-x1.check.sh" 2>/dev/null | awk '{print $1}' > "$home/hash"
  printf 'fm-custom-check-v1\n%s\n' "$(cat "$home/hash")" > "$home/state/task-x1.check-trust"
  chmod 600 "$home/state/task-x1.check-trust"
  # And the fleet check, registered beside it.
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-pr-ci.sh" arm >/dev/null || fail 'the fleet check could not be armed'
  # One real sweep first, so the fleet record exists and has something to lose.
  set_view "$home" "$(green java)"
  with_home "$home" "$ROOT/bin/fm-pr-ci.sh" poll >/dev/null || fail 'the fixture sweep failed'
  [ -f "$home/state/.pr-ci-state.json" ] || fail 'the fixture sweep wrote no fleet record'
  rc=0
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-teardown.sh" task-x1 > "$home/stdout" 2> "$home/stderr" || rc=$?
  [ "$rc" -eq 0 ] || fail "teardown of a landed task failed: $(cat "$home/stderr")"
  [ ! -e "$home/state/task-x1.check.sh" ] \
    || fail 'teardown left the task its own check script'
  [ -f "$home/state/pr-ci.check.sh" ] \
    || fail 'task teardown retired the registered fleet check'
  [ -f "$home/state/pr-ci.check-trust" ] \
    || fail 'task teardown retired the fleet check trust binding'
  [ -f "$home/state/.pr-ci-state.json" ] \
    || fail 'task teardown retired the fleet check record'
  pass 'task teardown retires the task check and leaves the registered fleet check'
}

test_green_to_red_wakes_exactly_once
test_recovery_wakes_once
test_running_check_is_never_a_failure
test_unreported_required_check_wakes_once
test_unreadable_required_set_stays_silent
test_unowned_pull_request_is_never_swept
test_scope_beats_the_clone_remote
test_scope_can_name_one_repository
test_missing_scope_sweeps_nothing
test_first_sweep_reports_an_existing_failure
test_closed_pull_request_is_not_swept
test_arm_registers_a_fleet_check
test_task_teardown_does_not_retire_the_fleet_check
