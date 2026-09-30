#!/usr/bin/env bash
# The one owner of the GitHub check-conclusion reads, shared by the merge guard
# (bin/fm-pr-merge.sh) and the open-pull-request CI watch (bin/fm-pr-ci.sh).
#
# A check conclusion is a fact about one pull request at one head commit, and
# two callers need it for two different questions: a merge has to refuse, and a
# watch has to notice. They read the same forge, through the same field set, and
# they must never disagree about which lane is current, so that machinery lives
# here once and both callers share it. Nothing here merges, waives, or grants
# authority; these functions only read and classify.
#
#   fm_pr_github_read_check_rollup  one live pull-request view plus its rollup
#   github_checks_not_green         the names a merge cannot proceed on
#   github_read_required_contexts   the base branch's effective required set
#   github_read_required_producers  the check-run apps reporting at one head
#   github_required_checks_missing  required names the rollup has not reported
#   fm_pr_github_check_states       each named lane's current state for a watch
#
# github_read_required_contexts reads the required set from classic branch
# protection and active rulesets because a required check that never reported is
# absent from the rollup rather than red. A check-run requirement keeps its
# producer app binding, so github_required_checks_missing also needs the
# github_read_required_producers answer; an unreadable producer read leaves the
# requirement unsatisfied rather than assumed satisfied. Callers set PR_OWNER and
# PR_REPO for the repository being read, and PR_BASE selects the base branch.
# Every read here returns nonzero rather than a partial answer, so a malformed
# or unavailable answer is always a failed read and never a green or empty one.

FM_PR_CI_VIEW=
FM_PR_CI_STATE=
FM_PR_CI_MERGEABLE=
FM_PR_CI_MERGE_STATE=
FM_PR_CI_HEAD=
FM_PR_CI_BASE=
# Read one live GitHub pull request view carrying its check rollup. One owner
# for the field set, the per-field parse, and the arity check, so the merge
# guard and the fleet CI watch cannot drift onto different fields or accept a
# differently shaped answer. Returns nonzero and prints nothing when the view
# cannot be read or does not carry exactly the expected fields; the caller keeps
# its own refusal message, because a merge refusal and a watch diagnostic are
# not the same sentence.
# shellcheck disable=SC2034 # Every FM_PR_CI_* field below is read by the caller.
fm_pr_github_read_check_rollup() { # url
  local url=$1 json fields line named=0 total=0
  FM_PR_CI_VIEW='' FM_PR_CI_STATE='' FM_PR_CI_MERGEABLE='' FM_PR_CI_MERGE_STATE=''
  FM_PR_CI_HEAD='' FM_PR_CI_BASE=''
  json=$(gh pr view "$url" \
    --json state,isDraft,mergeable,mergeStateStatus,headRefOid,baseRefName,statusCheckRollup 2>/dev/null) \
    || return 1
  [ -n "$json" ] || return 1
  fields=$(printf '%s' "$json" | jq -r '
      if type == "object" then
        "state=" + ((.state // "") | tostring),
        "mergeable=" + ((.mergeable // "") | tostring),
        "merge_state=" + ((.mergeStateStatus // "") | tostring),
        "head=" + ((.headRefOid // "") | tostring),
        "base=" + ((.baseRefName // "") | tostring)
      else
        error("pull request payload is not an object")
      end' 2>/dev/null) || return 1
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) FM_PR_CI_STATE=${line#state=} ;;
      mergeable=*) FM_PR_CI_MERGEABLE=${line#mergeable=} ;;
      merge_state=*) FM_PR_CI_MERGE_STATE=${line#merge_state=} ;;
      head=*) FM_PR_CI_HEAD=${line#head=} ;;
      base=*) FM_PR_CI_BASE=${line#base=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  [ "$named" -eq 5 ] && [ "$total" -eq 5 ] && [ -n "$FM_PR_CI_BASE" ] || return 1
  FM_PR_CI_VIEW=$json
}
# Every GitHub check that is not green in the given live pull-request JSON, one
# name per line. An entry is green when it is a status context whose state is
# SUCCESS, or a check run that completed with SUCCESS, NEUTRAL, or SKIPPED (so
# a pending check is not green either). Exits nonzero when the rollup cannot be
# read, so a malformed answer is a failed read and never an empty red set.
#
# The rollup can hold several runs of one check name at the same head, because
# GitHub cancels a pull request's in-flight run when the base branch advances
# and re-triggers it; the cancelled run stays in the rollup beside the passing
# re-run. A check is therefore judged by its current run rather than by any run
# that a later one superseded, which is what makes this agree with GitHub's own
# CLEAN mergeStateStatus instead of refusing a pull request GitHub considers
# mergeable.
#
# Supersession applies only among check runs with the same reported name. A
# name is dropped from the red set only when every non-green run is COMPLETED,
# has a whole-second UTC startedAt, and started strictly before a green run.
# Status contexts are never grouped or superseded, and every non-green one is
# reported independently. A still-running, queued, undated, or tied check run
# stays red. A name whose runs are all green needs no timestamp, while a name
# with no green run stays red.
#
# The reported name is also what --allow-red matches. An unnamed check run is
# grouped alone and can neither supersede nor be superseded, because unrelated
# unnamed checks must not be treated as one.
github_checks_not_green() {
  local json=$1
  printf '%s' "$json" | jq -r '
    def settled_at:
      if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
      then . else null end;
    if (.statusCheckRollup | type) != "array" then error("no check rollup") else . end
    | [ .statusCheckRollup
        | to_entries[]
        | .key as $i
        | .value
        | if .__typename == "CheckRun" then
            {
              kind: "check_run",
              name: (.name // ""),
              completed: (.status == "COMPLETED"),
              ok: (.status == "COMPLETED" and (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED")),
              at: (.startedAt | settled_at)
            }
            | . + {group: (if .name == "" then ["", $i] else [.name, -1] end)}
          else
            {kind: "status_context", name: (.context // ""), ok: (.state == "SUCCESS")}
          end
      ]
    | . as $entries
    | (
        ($entries[]
          | select(.kind == "status_context" and (.ok | not))
          | .name
        ),
        ($entries
          | [.[] | select(.kind == "check_run")]
          | group_by(.group)[]
          | {
              name: .[0].name,
              reds: [.[] | select(.ok | not)],
              newest_green: ([.[] | select(.ok) | .at | select(. != null)] | max)
            }
          | select(
              (.reds | length) > 0
              and (
                .newest_green == null
                or any(.reds[]; (.completed | not) or .at == null)
                or ([.reds[] | .at] | max) >= .newest_green
              )
            )
          | .name
        )
      )
    | if . == "" then "(unnamed check)" else . end
  ' 2>/dev/null || return 1
}

FM_PR_GITHUB_REQUIRED=
FM_PR_GITHUB_REQUIRED_ERROR=
github_read_required_contexts() {
  local base=$1 branch_path branch_json rules_json classic='' ruleset='' api_err api_err_text
  FM_PR_GITHUB_REQUIRED='[]'
  FM_PR_GITHUB_REQUIRED_ERROR=
  branch_path=$(github_urlencode_path_segment "$base")

  if ! branch_json=$(gh api "repos/$PR_OWNER/$PR_REPO/branches/$branch_path" 2>/dev/null) \
    || [ -z "$branch_json" ] \
    || ! classic=$(printf '%s' "$branch_json" | jq -c '
      if type != "object" or (.protected | type) != "boolean" then
        error("branch payload is unreadable")
      elif .protected == false then
        empty
      elif (.protection.required_status_checks | type) != "object" then
        error("branch protection summary is unreadable")
      else
        .protection.required_status_checks
        | ((.checks // []) | if type == "array" then .[] else error("invalid checks") end
           | {context, app_id}),
          ((.contexts // []) | if type == "array" then .[] else error("invalid contexts") end
           | {context: ., app_id: null})
        | if (.context | type) == "string" and (.context | length) > 0
             and (.app_id == null or (.app_id | type) == "number")
          then . else error("invalid required check") end
        | if .app_id == -1 then .app_id = null else . end
      end' 2>/dev/null); then
    classic=''
    FM_PR_GITHUB_REQUIRED_ERROR="the branch protection summary for base branch $base could not be read"
  fi

  if ! api_err=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-required-rules.XXXXXX"); then
    FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
  else
    if ! rules_json=$(gh api --paginate "repos/$PR_OWNER/$PR_REPO/rules/branches/$branch_path" 2>"$api_err"); then
      api_err_text=$(cat "$api_err" 2>/dev/null)
      if ! github_branch_rules_unavailable_on_plan "$api_err_text"; then
        FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
      fi
    elif [ -z "$rules_json" ] || ! ruleset=$(printf '%s' "$rules_json" | jq -c '
        if type != "array" then error("rules payload is unreadable") else .[] end
        | select(type != "object" or .type == "required_status_checks")
        | if type == "object" and (.parameters.required_status_checks | type) == "array"
          then .parameters.required_status_checks[] else error("invalid required check rule") end
        | if type == "object" and (.context | type) == "string" and (.context | length) > 0
             and (.integration_id == null or (.integration_id | type) == "number")
          then {context, app_id: .integration_id} else error("invalid required check rule") end
        | if .app_id == -1 then .app_id = null else . end' 2>/dev/null); then
      ruleset=''
      FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
    fi
    rm -f "$api_err"
  fi

  FM_PR_GITHUB_REQUIRED=$(printf '%s\n%s\n' "$classic" "$ruleset" | jq -sc '
    unique_by([.context, .app_id]) | group_by(.context)
    | map(if any(.[]; .app_id != null) then map(select(.app_id != null)) else . end) | add // []')
  [ -z "$FM_PR_GITHUB_REQUIRED_ERROR" ]
}

github_required_checks_missing() {
  local json=$1 required=$2 producers=$3
  printf '%s' "$json" | jq -r --argjson required "$required" --argjson producers "$producers" '
    if (.statusCheckRollup | type) != "array" then error("no check rollup") else . end
    | .statusCheckRollup as $reported
    | $required
    | map(. as $requirement
      | select(any($reported[];
          if $requirement.app_id == null then
            (if .__typename == "CheckRun" then .name else .context end) == $requirement.context
          elif .__typename == "CheckRun" then
            .name == $requirement.context
            and any($producers[]; .name == $requirement.context and .app.id == $requirement.app_id)
          else
            .context == $requirement.context
          end) | not)
      | .context) | unique[]
  ' 2>/dev/null || return 1
}

github_urlencode_path_segment() {
  local LC_ALL=C input=$1 encoded='' char octet hex
  while [ -n "$input" ]; do
    char=${input%"${input#?}"}
    input=${input#?}
    case "$char" in
      [-._~a-zA-Z0-9]) encoded=$encoded$char ;;
      *)
        printf -v octet '%d' "'$char"
        [ "$octet" -ge 0 ] || octet=$((octet + 256))
        printf -v hex '%02X' "$octet"
        encoded=$encoded%$hex
        ;;
    esac
  done
  printf '%s' "$encoded"
}

# Whether a failed branch-rules read (the gh stderr given) is GitHub's
# plan-gated 403 ("Upgrade to GitHub Pro or make this repository public"),
# which means the repository's plan cannot expose branch rules at all, on
# GitHub or GitHub Enterprise Server - not that this script failed to read
# them, and not that the token lacks a permission. Such a repository has no
# active ruleset rule of any kind. Any other failure (auth, rate limit,
# network, a 404, an unrelated 403) is not this and stays unreadable.
github_branch_rules_unavailable_on_plan() {
  case "$1" in
    *"Upgrade to GitHub Pro or make this repository public"*) return 0 ;;
  esac
  return 1
}

# The check-run apps reporting at one head, for the requirements that keep a
# producer app binding. Returns 0 with FM_PR_GITHUB_REQUIRED_PRODUCERS set to a
# JSON array, which is "[]" both when no requirement is app-bound and when the
# read failed; FM_PR_GITHUB_REQUIRED_PRODUCERS_ERROR separates those two, so a
# caller can still refuse or report an unreadable read instead of quietly
# treating an app-bound requirement as unmet.
FM_PR_GITHUB_REQUIRED_PRODUCERS='[]'
FM_PR_GITHUB_REQUIRED_PRODUCERS_ERROR=
# shellcheck disable=SC2034 # Both fields this sets are read by the caller.
github_read_required_producers() { # head
  local head=$1 runs
  FM_PR_GITHUB_REQUIRED_PRODUCERS='[]'
  FM_PR_GITHUB_REQUIRED_PRODUCERS_ERROR=''
  printf '%s' "$FM_PR_GITHUB_REQUIRED" | jq -e 'any(.[]; .app_id != null)' >/dev/null || return 0
  if ! runs=$(gh api --paginate "repos/$PR_OWNER/$PR_REPO/commits/$head/check-runs" 2>/dev/null) \
    || [ -z "$runs" ] \
    || ! FM_PR_GITHUB_REQUIRED_PRODUCERS=$(printf '%s' "$runs" | jq -sc --arg head "$head" '
      [ .[] | if (.check_runs | type) == "array" then .check_runs[] else error("invalid check runs") end
        | if (.name | type) == "string" and (.app.id | type) == "number" and .head_sha == $head
          then . else error("invalid check producer") end ]' 2>/dev/null); then
    FM_PR_GITHUB_REQUIRED_PRODUCERS='[]'
    FM_PR_GITHUB_REQUIRED_PRODUCERS_ERROR="required check producers at head $head could not be read"
    return 1
  fi
}

# Each distinct check name the rollup reports, one "name<TAB>state" line, where
# state is passing, failing, or running. This is the watch's question - what is
# each lane doing now - and it is deliberately not the merge refusal above. A
# merge cannot proceed on an unfinished check, so github_checks_not_green
# reports a still-running lane as not green; a watch that called that a failure
# would alarm on every push. The current-run verdict is therefore not
# reimplemented here: this reads github_checks_not_green's answer for which lane
# is current, and only splits that answer into a settled failure versus a lane
# with nothing settled yet.
#
# A name the rollup does not report is never emitted. A required check that has
# not reported at all is github_required_checks_missing's answer, never invented
# here as a pass. Unnamed lanes are omitted: the merge refusal already names them
# "(unnamed check)", and a wake carrying a nameless check is not relayable.
fm_pr_github_check_states() { # json
  local json=$1 not_green
  not_green=$(github_checks_not_green "$json") || return 1
  printf '%s' "$json" | jq -r --arg not_green "$not_green" '
    def name_of: if .__typename == "CheckRun" then (.name // "") else (.context // "") end;
    def settled_red:
      if .__typename == "CheckRun" then
        (.status == "COMPLETED" and ((.conclusion // "") | IN("SUCCESS","NEUTRAL","SKIPPED") | not))
      else ((.state // "") != "SUCCESS") end;
    if (.statusCheckRollup | type) != "array" then error("no check rollup") else . end
    | .statusCheckRollup as $rollup
    | ($not_green | split("\n")
        | map(select(length > 0 and . != "(unnamed check)"))) as $red
    | [ $rollup[] | name_of | select(length > 0) ] | unique[]
    | . as $name
    | ([ $rollup[] | select(name_of == $name) | settled_red ] | any) as $failed
    | ( $red | index($name) ) as $is_red
    | [ $name,
        (if $is_red == null then "passing"
         elif $failed then "failing"
         else "running" end) ]
    | @tsv' 2>/dev/null || return 1
}
