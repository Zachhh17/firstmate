#!/usr/bin/env bash
# tests/fm-crew-liveness.test.sh - bin/fm-crew-liveness.sh keeps alive, dead and
# unobservable apart, including a wrapped (sudo-style) launch whose foreground is the
# wrapper rather than a harness. Real tmux on a private socket; no sudo needed: the
# wrapper stand-in is a symlink named `sudo` to sleep, which is what argv0 shows.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
SLEEP_BIN=$(command -v sleep) || { echo "skip: sleep not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-crew-liveness-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-crew-liveness.XXXXXX")

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

mkdir -p "$LAB/shim" "$LAB/bin" "$LAB/state"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
ln -s "$SLEEP_BIN" "$LAB/bin/sudo"
PATH="$LAB/shim:$PATH"
export PATH

liveness() {  # <id>
  FM_STATE_OVERRIDE="$LAB/state" "$ROOT/bin/fm-crew-liveness.sh" "$1"
}
meta() {  # <id> <window> [wrapper]
  { echo "window=lab:$2"; echo "harness=claude"; [ -z "${3:-}" ] || echo "launch_basename=$3"; } \
    > "$LAB/state/$1.meta"
}

tmux new-session -d -s lab -n idle "bash --norc"
tmux new-window -d -t lab -n wrapped "$LAB/bin/sudo 60"
sleep 1

meta wrapped wrapped sudo
case "$(liveness wrapped)" in
  "liveness: alive"*) pass "a running wrapped launch reads alive" ;;
  *) fail "wrapped launch: $(liveness wrapped)" ;;
esac

meta unwrapped wrapped
case "$(liveness unwrapped)" in
  "liveness: unobservable"*) pass "the same pane without a recorded wrapper is unobservable, not dead" ;;
  *) fail "unrecorded wrapper: $(liveness unwrapped)" ;;
esac

meta other wrapped setpriv
case "$(liveness other)" in
  "liveness: unobservable"*) pass "a different recorded wrapper is not evidence" ;;
  *) fail "mismatched wrapper: $(liveness other)" ;;
esac

meta idle idle sudo
case "$(liveness idle)" in
  "liveness: dead"*) pass "a pane holding only a shell reads dead" ;;
  *) fail "idle shell: $(liveness idle)" ;;
esac

meta gone nowindow sudo
case "$(liveness gone)" in
  "liveness: dead"*) pass "a missing window reads dead" ;;
  *) fail "missing window: $(liveness gone)" ;;
esac

case "$(liveness nometa)" in
  "liveness: unobservable"*) pass "no metadata is unobservable" ;;
  *) fail "no metadata: $(liveness nometa)" ;;
esac

code=0
FM_STATE_OVERRIDE="$LAB/state" "$ROOT/bin/fm-crew-liveness.sh" >/dev/null 2>&1 || code=$?
if [ "$code" -eq 2 ]; then pass "usage error exits 2"; else fail "usage error exit code $code"; fi
