#!/usr/bin/env bash
# fm-crew-liveness.sh - is a crew's executor process alive, dead, or not observable?
#
# Why this exists: fm-crew-state.sh answers "what is the crew's WORK state" and
# deliberately folds every death-class verdict into `unknown` (a stale status log
# must never read as current). A supervisor deciding whether to relaunch needs the
# other question - is the process there - with the three outcomes kept apart:
#
#   liveness: alive        positive evidence the executor is running
#   liveness: dead         positive evidence it is gone (window missing, or the
#                          pane's foreground holds nothing but shells)
#   liveness: unobservable the probe could not decide; NEVER evidence of death
#
# One line, `liveness: <verdict> · evidence: <why>`. Exit 0 on any read, 2 on usage.
#
# Wrapped launches (fm-spawn --adapter): a raw launch through sudo / unshare /
# setpriv runs the agent under another identity, so the pane's foreground process
# group is the wrapper (`sudo`), not the harness, and the tmux classifier answers
# `ambiguous`. The task's meta records launch_basename=<wrapper>. A foreground
# process whose argv0 basename is that recorded wrapper is the launch itself, and it
# exits when the wrapped agent does (verified 2026-10-04 with One Jarvis's
# sudo + unshare --kill-child wrapper: foreground `sudo` while running, shells only
# after exit), so it is positive evidence of life. A wrapper still running a hung
# agent is a wedge, which fm-watch reports; liveness does not claim progress.
#
# Read-only and side-effect free.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-liveness.sh <id>" >&2; exit 2; }
META=${FM_CREW_LIVENESS_META_OVERRIDE:-"$STATE/$ID.meta"}

say() {  # <verdict> <evidence>
  printf 'liveness: %s · evidence: %s\n' "$1" "$2"
  exit 0
}

[ -f "$META" ] || say unobservable "no metadata for $ID"
[ -z "$(fm_meta_get "$META" remote_host)" ] || say unobservable "remote endpoint (ask fm-crew-state.sh)"

BACKEND=$(fm_backend_of_meta "$META")
TARGET=$(fm_backend_target_of_meta "$META")
WRAPPER=$(fm_meta_get "$META" launch_basename)
[ -n "$TARGET" ] || say unobservable "no backend target recorded"

AGENT=$(fm_backend_agent_state "$BACKEND" "$TARGET")
case "$AGENT" in
  alive) say alive "$BACKEND agent running in $TARGET" ;;
  missing) say dead "$BACKEND endpoint gone: $TARGET" ;;
  dead) say dead "no agent in $TARGET (only shells in the foreground)" ;;
esac

# The classifier could not name a harness. For a wrapped launch on tmux, the
# recorded wrapper in the foreground process group is the launch itself.
if [ -n "$WRAPPER" ] && [ "$BACKEND" = tmux ] && fm_backend_source tmux; then
  while IFS= read -r argv0; do
    [ -n "$argv0" ] || continue
    if [ "${argv0##*/}" = "$WRAPPER" ]; then
      say alive "wrapped launch running in $TARGET (foreground $WRAPPER)"
    fi
  done <<EOF
$(fm_backend_tmux_foreground_argv0s "$TARGET")
EOF
fi

say unobservable "$BACKEND endpoint state: $AGENT"
