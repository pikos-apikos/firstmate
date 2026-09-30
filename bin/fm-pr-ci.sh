#!/usr/bin/env bash
# Watch the check conclusions on this fleet's open pull requests and wake
# firstmate when one of them changes in a way worth acting on.
#
# Usage:
#   fm-pr-ci.sh poll
#   fm-pr-ci.sh arm
#
# This is a fleet check, not a task's check: it is registered as
# state/pr-ci.check.sh, whose id is not a task id, so bin/fm-teardown.sh - which
# retires "<task-id>.check.sh" for a task id - never retires it. Retire it
# deliberately with bin/fm-check-unregister.sh pr-ci.
#
# poll prints exactly one line when firstmate should wake and nothing otherwise,
# so a healthy cycle is genuinely silent. It prints nothing for a check that is
# simply still running, because a lane that has not finished is not a failure and
# alarming on every push is how a watch gets switched off.
#
# ## What is swept
#
# The sweep is the intersection of two independent limits, and it is narrow by
# construction rather than by hope:
#
#   1. Ownership. Only URLs this home already owns: a task's pr= or a structured
#      backlog row's explicit link, as bin/fm-contributions.jq's known() defines
#      them. Repository-wide pull-request discovery is never used, so a pull
#      request nobody here owns is never read even when it is red. Previously
#      observed URLs are deliberately not carried forward from saved contribution
#      records: a PR whose task is gone is no longer this fleet's business.
#
#   2. Scope. Only repositories the captain's config/forge-scope permits. The
#      scope is a preference, so it is configuration and is never inferred from a
#      clone's origin remote. That distinction is load-bearing: a firstmate clone
#      commonly has its origin on the upstream repository while the pull requests
#      this fleet owns live on the captain's own fork, so a check that trusted the
#      remote would poll the wrong repository entirely and miss every pull request
#      it exists to watch. An absent, unreadable, or unusable scope sweeps
#      nothing and reports once, rather than falling back to a wider set.
#
# ## What wakes
#
# The last conclusive conclusion per check per pull request is remembered, and a
# wake happens only when that conclusion changes:
#
#   - a check that is now failing, including one that was already failing on the
#     very first sweep - a red required check nobody has noticed is the whole
#     reason this exists, so a first observation of a failure is a change;
#   - a check that has recovered;
#   - a required check that has not reported at all, once, and then not again.
#
# A lane that is only running is not a conclusion and never replaces the stored
# one, so a failing check that is being re-run still reports as recovering when
# the re-run goes green rather than losing its history to a running state.
#
# ## What it never does
#
# It never merges, never waives a check, never grants merge authority, and never
# treats a missing report as a pass. A required check that has not reported is
# reported as unreported, which is a different fact from failing. The conclusions
# themselves are read through bin/fm-check-conclusion-lib.sh, shared with the
# merge guard, so this sweep and a merge can never disagree about which lane is
# current.
#
# ## Record and bounds
#
# The on-disk record is fm-pr-ci.v1 in state/.pr-ci-state.json: one entry per
# owned pull request holding its head, each named check's last conclusive
# conclusion, and the required names still unreported. A pull request this home no
# longer owns is dropped from it; one this sweep could not read keeps what it knew,
# so a budget refusal or a forge blip never erases a conclusion and re-alarms on
# the next cycle. Writes refuse symlinks and publish by rename, and all mutations
# serialize on state/.pr-ci.lock.
#
# Each pull request is observed in its own bounded child, so one slow repository
# cannot outlive the sweep or leave a half-read record behind. The whole sweep is
# bounded by FM_PR_CI_BUDGET seconds (default 20, 1..25) and cut down to the
# watcher's own per-check bound, and each observation reserves part of what remains
# before it starts. A child killed at that bound is budget refusal, which leaves
# the record untouched and is never a forge failure; only a genuine nonzero gh
# exit inside a child that finished is.
# jq_lib receives literal jq programs, not shell expressions.
# shellcheck disable=SC2016
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME FM_STATE_OVERRIDE="$STATE"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-conclusion-lib.sh
. "$SCRIPT_DIR/fm-check-conclusion-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

fail() { printf 'fm-pr-ci: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
command -v jq >/dev/null 2>&1 || fail 'jq is required to read check conclusions'
NOW=${FM_PR_CI_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
BUDGET=${FM_PR_CI_BUDGET:-20}
case "$BUDGET" in ''|*[!0-9]*) fail 'invalid sweep budget' ;; esac
[ "$BUDGET" -ge 1 ] && [ "$BUDGET" -le 25 ] || fail 'sweep budget must be 1..25 seconds'
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;; esac
BUDGET_CAP=$((CHECK_TIMEOUT - 3))
[ "$BUDGET_CAP" -ge 1 ] || BUDGET_CAP=1
[ "$BUDGET" -le "$BUDGET_CAP" ] || BUDGET=$BUDGET_CAP
# How many transitions one wake line may name before it counts the rest. The line
# is relayed to the captain as it stands, so an unbounded one is not a
# notification, it is a wall of text.
MAX_CLAUSES=${FM_PR_CI_MAX_CLAUSES:-8}
case "$MAX_CLAUSES" in ''|*[!0-9]*|0) MAX_CLAUSES=8 ;; esac
# Enough of the remaining budget to finish one pull request's dependent reads
# before starting it, so a sweep never abandons a half-read record.
RESERVE=$((BUDGET < 12 ? BUDGET : 12 ))
RECORD="$STATE/.pr-ci-state.json"
LOCK="$STATE/.pr-ci.lock"
SCOPE_FILE="$CONFIG/forge-scope"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-ci.XXXXXX")
LOCK_HELD=0
REQUIRED_CACHE="$TMP/required"
DEADLINE=0
cleanup() {
  [ "$LOCK_HELD" = 0 ] || fm_lock_release "$LOCK" || true
  rm -rf -- "$TMP"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

jq_lib() { # jq options/program via final argument
  local program=${!#}
  set -- "${@:1:$#-1}"
  jq -L "$SCRIPT_DIR" "$@" "include \"fm-contributions\"; $program"
}

# A stable digest of stdin, used only to name a cache file.
digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    cksum | awk '{print $1 "-" $2}'
  fi
}

# The wake library owns the lock helpers this home serializes on. It is sourced
# here rather than at the top so its source-time state initialization stays off
# the read-only paths.
acquire() {
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_acquire_wait "$LOCK" || fail 'CI watch lock unavailable'
  LOCK_HELD=1
}

# One lowercased "owner" or "owner/repo" per permitted entry. A repository the
# captain has not permitted produces no entry at all, and there is no default and
# no fallback set: an unreadable scope is not permission to sweep more.
read_scope() { # -> permitted "owner[/repo]" entries on stdout
  local line entry
  [ -d "$CONFIG" ] && [ ! -L "$CONFIG" ] || return 1
  [ -f "$SCOPE_FILE" ] && [ ! -L "$SCOPE_FILE" ] || return 1
  [ "$(wc -c < "$SCOPE_FILE")" -le 65536 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    [[ "$line" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?$ ]] || return 1
    entry=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
    printf '%s\n' "$entry"
  done < "$SCOPE_FILE"
  return 0
}

# Whether an owned pull request URL is inside the permitted scope. An owner entry
# permits every repository under it and an owner/repository entry permits exactly
# that one, compared as exact strings so a permitted `owner` can never widen into a
# different owner by prefix. Only GitHub URLs are read, because that is the forge
# whose conclusions this library classifies; another host is out of scope for this
# sweep rather than guessed at.
url_in_scope() { # url
  local url=$1 part repo owner entry entry_owner entry_repo
  case "$url" in https://github.com/*) ;; *) return 1 ;; esac
  part=${url#https://github.com/}
  case "$part" in */*/*/*) ;; *) return 1 ;; esac
  repo=${part#*/}; repo=${repo%%/*}
  part=${part%%/*}
  owner=${part%%/*}
  [ -n "$owner" ] && [ -n "$repo" ] || return 1
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    entry_owner=${entry%%/*}
    case "$entry" in
      */*) entry_repo=${entry#*/} ;;
      *) entry_repo='' ;;
    esac
    [ "$entry_owner" = "$owner" ] || continue
    [ -z "$entry_repo" ] || [ "$entry_repo" = "$repo" ] || continue
    return 0
  done < "$TMP/scope.txt"
  return 1
}

# The pull request URLs this fleet both owns and may watch. known() is
# bin/fm-contributions.jq's single owner of what this fleet owns; saved
# contribution records are deliberately not passed, so ownership comes from live
# task and backlog records only.
owned_urls() { # -> one scoped owned pull request URL per line
  "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input > "$TMP/input.json"
  jq_lib -nr --slurpfile input "$TMP/input.json" '
    known($input[0]; [])
    | map(select(.url | test("/pull/[0-9]+$")) | .url)
    | unique[]' > "$TMP/owned.txt"
  : > "$TMP/scoped.txt"
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    url_in_scope "$url" && printf '%s\n' "$url" >> "$TMP/scoped.txt"
  done < "$TMP/owned.txt"
  sort -u "$TMP/scoped.txt" -o "$TMP/scoped.txt"
}

# Observe one pull request, writing fm-pr-ci.observation.v1 to
# $FM_PR_CI_OBSERVATION. A nonzero exit means no conclusion was reached and the
# caller must leave the record alone. This never writes the record and never
# prints a wake line, so a partially observed pull request cannot report
# anything.
observe() { # url
  local url=$1 part key required missing unreported cache
  # The parent sweep shares one required-contexts cache across sibling
  # observations; a direct invocation makes its own.
  cache=${FM_PR_CI_REQUIRED_CACHE:-$REQUIRED_CACHE}
  mkdir -p "$cache"
  # owner/repository, taken from the same shape url_in_scope accepts, so a read
  # can never be aimed at a repository the URL does not name.
  part=${url#https://github.com/}
  PR_REPO=${part#*/}
  PR_REPO=${PR_REPO%%/*}
  part=${part%%/*}
  PR_OWNER=${part%%/*}
  [ -n "$PR_OWNER" ] && [ -n "$PR_REPO" ] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  fm_pr_github_read_check_rollup "$url" || return 1
  fm_pr_head_valid "$FM_PR_CI_HEAD" || return 1
  [ "${FM_PR_CI_STATE,,}" = open ] || return 1
  fm_pr_github_check_states "$FM_PR_CI_VIEW" > "$TMP/states.tsv" || return 1
  # Required contexts belong to the repository's base branch, not to one pull
  # request, so they are read once per repository and base and shared with the
  # sibling observations in the same sweep. The cache file is named by a digest
  # because a base branch may contain a slash and a colliding name would read one
  # repository's requirements for another's.
  key="$(printf '%s' "$PR_OWNER/$PR_REPO/$FM_PR_CI_BASE" | digest)"
  if [ ! -e "$cache/$key.json" ] && [ ! -e "$cache/$key.err" ]; then
    if github_read_required_contexts "$FM_PR_CI_BASE"; then
      printf '%s' "$FM_PR_GITHUB_REQUIRED" > "$cache/$key.json.tmp"
      mv -f -- "$cache/$key.json.tmp" "$cache/$key.json"
    else
      printf '%s' "$FM_PR_GITHUB_REQUIRED_ERROR" > "$cache/$key.err.tmp"
      mv -f -- "$cache/$key.err.tmp" "$cache/$key.err"
    fi
  fi
  # A required check that has not reported can only be decided when the required
  # set was readable AND, for an app-bound requirement, the producer read
  # succeeded. An unmeasured answer stays silent rather than guessing, because a
  # wrong "unreported" notice is exactly the noise this check exists to avoid.
  unreported='[]'
  if [ -e "$cache/$key.json" ]; then
    required=$(cat "$cache/$key.json")
    if github_read_required_producers "$FM_PR_CI_HEAD" \
      && missing=$(github_required_checks_missing "$FM_PR_CI_VIEW" "$required" \
        "$FM_PR_GITHUB_REQUIRED_PRODUCERS"); then
      unreported=$(printf '%s' "$missing" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')
    fi
  fi
  jq -n --arg head "$FM_PR_CI_HEAD" --argjson unreported "$unreported" \
    --rawfile states "$TMP/states.tsv" '
    {schema:"fm-pr-ci.observation.v1",head:$head,
     checks:([ $states | split("\n") | map(select(length > 0))[]
               | split("\t") | select(length == 2) | {key:.[0],value:.[1]} ] | from_entries),
     unreported:$unreported}' > "$FM_PR_CI_OBSERVATION"
}

# Fold one observation into the record and report every change worth waking on.
# A lane that is merely running keeps the conclusion it already had; a lane the
# rollup no longer reports is dropped. An absent stored conclusion counts as
# passing, so a first observation of a failure is a change and a red check nobody
# has noticed still surfaces exactly once.
apply_observation() { # url observation-json
  local url=$1 c_check c_what
  jq -n --arg url "$url" --slurpfile prev "$TMP/next.json" --slurpfile seen "$2" '
    ($prev[0].urls[$url] // {head:null,checks:{},unreported:[]}) as $before
    | ($seen[0].checks // {}) as $observed
    | ($observed | keys) as $lanes
    | ($before.checks + ($observed | with_entries(select(.value | IN("passing","failing")))))
      | with_entries(select(.key as $name | $lanes | index($name))) as $checks
    | ($before.unreported // []) as $was
    | ($seen[0].unreported // []) as $now
    | {entry:{head:$seen[0].head, checks:$checks, unreported:$now},
       transitions:
         ([ $checks | to_entries[]
             | .key as $name | .value as $state
             | ($before.checks[$name] // "passing") as $previous
             | select(($state == "failing" and $previous != "failing")
                   or ($state == "passing" and $previous == "failing"))
             | [$name, (if $state == "failing" then "failing" else "recovered" end)] ]
          + [ ($now - $was)[] | [., "unreported"] ])}' > "$TMP/applied.json" \
    || fail "could not fold the observation of $url"
  jq --arg url "$url" --slurpfile applied "$TMP/applied.json" \
    '.urls[$url] = $applied[0].entry' "$TMP/next.json" > "$TMP/next2.json" \
    || fail "could not record the observation of $url"
  mv "$TMP/next2.json" "$TMP/next.json"
  while IFS=$'\t' read -r c_check c_what; do
    [ -n "$c_check" ] || continue
    printf '%s|%s|%s\n' "$url" "$c_check" "$c_what" >> "$TMP/clauses.txt"
  done < <(jq -r '.transitions[] | @tsv' "$TMP/applied.json" 2>/dev/null)
}

# The sentence a clause becomes inside the single wake line. It always carries the
# pull request's full URL and the check's name, so the captain can be told what is
# wrong without a second lookup.
render_clause() { # "url|check|what"
  case "$3" in
    unreported) printf 'required check %s on %s has not reported' "$2" "$1" ;;
    recovered) printf '%s on %s recovered' "$2" "$1" ;;
    *) printf '%s on %s is failing' "$2" "$1" ;;
  esac
}

# Load the previous record into $TMP/next.json and the untouched copy into
# $TMP/previous.json, and set STATUS_EPISODE when a record that exists cannot be
# read. A record that is simply absent is a first sweep, not a measurement gap. An
# unreadable record is disclosed on the transition only, so it cannot become the
# endless alarm this check is built to avoid.
read_record() {
  local usable=1
  if [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ]; then
    usable=0
    STATUS_EPISODE=0
  elif [ -L "$RECORD" ] || [ ! -f "$RECORD" ] \
    || [ "$(wc -c < "$RECORD")" -gt 4194304 ] \
    || ! jq -e '(.schema == "fm-pr-ci.v1") and ((.urls // {}) | type == "object")
      and all((.urls // {})[]; ((.checks // {}) | type == "object")
        and ((.unreported // []) | type == "array"))' "$RECORD" >/dev/null 2>&1; then
    STATUS_EPISODE=1
  else
    STATUS_EPISODE=0
  fi
  if [ "$usable" -eq 1 ] && [ "$STATUS_EPISODE" -eq 0 ]; then
    cat "$RECORD" > "$TMP/next.json"
  else
    printf '{"schema":"fm-pr-ci.v1","scope":"unknown","record":"readable","urls":{}}' > "$TMP/next.json"
  fi
  cp "$TMP/next.json" "$TMP/previous.json"
}

write_record() {
  local staged
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail 'state directory is unavailable'
  staged=$(umask 077; mktemp "$STATE/.pr-ci-state.XXXXXX")
  jq -e --arg now "$NOW" '.schema = "fm-pr-ci.v1" | .observed_at = $now' "$TMP/next.json" > "$staged" \
    || fail 'could not stage the CI watch record'
  chmod 600 "$staged"
  mv -f -- "$staged" "$RECORD"
}

# Each pull request is observed in its own bounded child, so one slow repository
# cannot outlive the sweep or leave a half-read record behind.
poll_urls() {
  local url rc remaining
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    remaining=$((DEADLINE - $(date +%s)))
    [ "$remaining" -ge "$RESERVE" ] || break
    rm -f -- "$TMP/observation.json"
    rc=0
    FM_PR_CI_REQUIRED_CACHE="$REQUIRED_CACHE" FM_PR_CI_OBSERVATION="$TMP/observation.json" \
      fm_run_timed "$remaining" "$SCRIPT_DIR/fm-pr-ci.sh" _observe "$url" >/dev/null 2>&1 || rc=$?
    # 124 is budget refusal and any other nonzero is a read that reached no
    # conclusion. Neither is a change, so neither may touch the record.
    [ "$rc" -eq 0 ] || continue
    [ -s "$TMP/observation.json" ] || continue
    apply_observation "$url" "$TMP/observation.json"
  done < "$TMP/scoped.txt"
}

poll() {
  local total shown rest
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail 'state directory is unavailable'
  acquire
  read_record
  : > "$TMP/clauses.txt"
  if read_scope > "$TMP/scope.txt"; then
    if [ "$(jq -r '.scope // "unknown"' "$TMP/next.json")" = unreadable ]; then
      printf 'pr-ci: %s is readable again; the CI watch is sweeping this scope\n' "$SCOPE_FILE"
    fi
    jq '.scope = "readable"' "$TMP/next.json" > "$TMP/scoped.json"
    mv "$TMP/scoped.json" "$TMP/next.json"
    owned_urls
    mkdir -p "$REQUIRED_CACHE"
    DEADLINE=$(( $(date +%s) + BUDGET ))
    poll_urls
    # A pull request this home no longer owns is not this fleet's business and is
    # dropped; one this sweep could not read keeps exactly what it knew, so a
    # budget refusal never erases a conclusion and re-alarms on the next cycle.
    jq -n --slurpfile fresh "$TMP/next.json" --slurpfile previous "$TMP/previous.json" \
      --rawfile scoped "$TMP/scoped.txt" --arg now "$NOW" '
      ($fresh[0]) as $record
      | ($scoped | split("\n") | map(select(length > 0))) as $owned
      | ($record.urls // {}) as $observed
      | ($previous[0].urls // {}) as $before
      | $owned
      | map({key:., value:($before[.] // null)})
      | map(select(.value != null))
      | from_entries as $kept
      | {schema:"fm-pr-ci.v1", observed_at:$now, scope:"readable", record:"readable",
         urls:($kept + ($observed | with_entries(select(.key as $k | $owned | index($k)))))}' \
      > "$TMP/final.json" || fail 'could not reconcile the CI watch record'
    cp "$TMP/final.json" "$TMP/next.json"
  else
    if [ "$(jq -r '.scope // "unknown"' "$TMP/next.json")" != unreadable ]; then
      printf 'pr-ci: %s is absent or unreadable, so no pull request is being watched\n' "$SCOPE_FILE"
    fi
    # Nothing is swept, so nothing is claimed. The remembered conclusions stay
    # exactly as they were, so the fleet's open pull requests are disclosed as
    # unmeasured rather than proven green, and restoring the scope resumes the
    # deduplication instead of re-alarming about everything at once.
    jq '.scope = "unreadable"' "$TMP/next.json" > "$TMP/scoped.json"
    mv "$TMP/scoped.json" "$TMP/next.json"
  fi
  write_record
  [ "$STATUS_EPISODE" -eq 0 ] \
    || printf 'pr-ci: the remembered conclusions could not be read, so this sweep cannot tell a change from a repeat\n'
  if [ -s "$TMP/clauses.txt" ]; then
    total=$(wc -l < "$TMP/clauses.txt")
    shown=0
    : > "$TMP/rendered.txt"
    while IFS='|' read -r c_url c_check c_what; do
      [ "$shown" -lt "$MAX_CLAUSES" ] || break
      render_clause "$c_url" "$c_check" "$c_what" >> "$TMP/rendered.txt"
      shown=$((shown + 1))
    done < "$TMP/clauses.txt"
    rest=$((total - shown))
    printf 'pr-ci: '
    awk 'NR > 1 { printf "; " } { printf "%s", $0 } END { printf "\n" }' "$TMP/rendered.txt"
    [ "$rest" -le 0 ] || printf '; and %s more\n' "$rest"
  fi
  return 0
}

arm() {
  local device staged
  local -a shim
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail 'state directory is unavailable'
  acquire
  device=$(fm_pr_file_device "$STATE")
  fm_pr_regular_destination_on_device_or_absent "$STATE/pr-ci.check.sh" "$device" \
    || fail 'unsafe check destination'
  staged=$(umask 077; mktemp "$STATE/.pr-ci-check.XXXXXX")
  shim=('#!/usr/bin/env bash'
    "export FM_HOME=$(printf '%q' "$FM_HOME")"
    "export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")"
    "export FM_DATA_OVERRIDE=$(printf '%q' "$DATA")"
    "export FM_CONFIG_OVERRIDE=$(printf '%q' "$CONFIG")")
  if [ -n "${FM_PR_CI_BUDGET:-}" ]; then
    shim+=("export FM_PR_CI_BUDGET=$(printf '%q' "$FM_PR_CI_BUDGET")")
  fi
  shim+=("exec $(printf '%q' "$SCRIPT_DIR/fm-pr-ci.sh") poll")
  printf '%s\n' "${shim[@]}" > "$staged"
  chmod 700 "$staged"
  mv -f -- "$staged" "$STATE/pr-ci.check.sh"
  "$SCRIPT_DIR/fm-check-register.sh" pr-ci >/dev/null \
    || fail 'the CI watch could not be registered'
  printf 'armed: state/pr-ci.check.sh\n'
}

case "${1:-}" in
  poll) poll ;;
  arm) arm ;;
  _observe) observe "${2:?}" ;;
  *) usage >&2; exit 2 ;;
esac
