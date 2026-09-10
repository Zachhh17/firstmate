#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh --adapter: a RAW launch command that wraps a
# verified adapter's CLI (sudo, unshare, setpriv, a container entrypoint) records
# that adapter as the task's harness instead of the wrapper's basename, so the
# control plane keeps its verified mechanics for the wrapped process.
#
# The fake tmux captures the literal launch command sent with `tmux send-keys
# -l`, so assertions pin both the command actually run (unchanged) and the meta
# the spawn records.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-adapter)

make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  CLAUDE_CONFIG_DIR="" FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

WRAPPED='sudo -n /opt/pilot/ns-launch.sh --user worker -- JARVIS=1 claude --permission-mode dontAsk "$(cat brief.md)"'

test_adapter_records_wrapped_adapter_not_wrapper_basename() {
  local rec id out status meta
  id=adapter-claude-z1
  rec=$(make_case adapter-claude "$id")
  read_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "$WRAPPED" --scout --adapter claude)
  status=$?
  expect_code 0 "$status" "raw launch with --adapter claude should spawn"
  assert_contains "$out" "spawned $id harness=claude" "spawn should report the wrapped adapter, not sudo"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "harness=claude" "$meta" "meta must record harness=claude for fm-control's mechanics"
  assert_grep "launch_basename=sudo" "$meta" "meta must keep the wrapper basename for provenance"
  assert_grep "sudo -n /opt/pilot/ns-launch.sh --user worker -- JARVIS=1 claude" "$LAUNCH_LOG" \
    "the raw command itself must run unchanged"
  # The wrapped process runs under another identity: none of claude's in-spawn
  # wiring (the busy-state hook settings) may be threaded onto the wrapper.
  assert_no_grep "__BUSY" "$LAUNCH_LOG" "no unrendered placeholder may leak into a raw launch"
  pass "raw launch with --adapter records the wrapped adapter and runs the wrapper unchanged"
}

test_raw_launch_without_adapter_still_records_basename() {
  local rec id out status meta
  id=adapter-none-z2
  rec=$(make_case adapter-none "$id")
  read_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "$WRAPPED" --scout)
  status=$?
  expect_code 0 "$status" "raw launch without --adapter should still spawn"
  assert_contains "$out" "spawned $id harness=sudo" "without --adapter the basename rule is unchanged"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "harness=sudo" "$meta" "meta keeps the basename rule without --adapter"
  assert_no_grep "launch_basename=" "$meta" "launch_basename is written only when an adapter is recorded"
  pass "raw launch without --adapter keeps the existing basename record"
}

test_adapter_refuses_unverified_name() {
  local rec id out status
  id=adapter-bogus-z3
  rec=$(make_case adapter-bogus "$id")
  read_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "$WRAPPED" --scout --adapter sudo)
  status=$?
  [ "$status" -ne 0 ] || fail "--adapter sudo must be refused (no verified control mechanics)"
  assert_contains "$out" "--adapter must name a verified adapter" "refusal should name the rule"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must leave no task record"
  pass "--adapter refuses a name without verified control mechanics"
}

test_adapter_refuses_named_adapter_launch() {
  local rec id out status
  id=adapter-named-z4
  rec=$(make_case adapter-named "$id")
  read_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" codex --scout --adapter claude)
  status=$?
  [ "$status" -ne 0 ] || fail "--adapter with a named adapter must be refused"
  assert_contains "$out" "--adapter applies only to a raw launch command" "refusal should explain the raw-launch rule"
  pass "--adapter is refused alongside a named adapter"
}

test_adapter_requires_value() {
  local rec id out status
  id=adapter-empty-z5
  rec=$(make_case adapter-empty "$id")
  read_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "$WRAPPED" --scout --adapter)
  status=$?
  [ "$status" -ne 0 ] || fail "--adapter without a value must be refused"
  assert_contains "$out" "--adapter requires a value" "refusal should name the missing value"
  pass "--adapter requires a value"
}

test_adapter_records_wrapped_adapter_not_wrapper_basename
test_raw_launch_without_adapter_still_records_basename
test_adapter_refuses_unverified_name
test_adapter_refuses_named_adapter_launch
test_adapter_requires_value

fm_test_cleanup
