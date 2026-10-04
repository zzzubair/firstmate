#!/usr/bin/env bash
# Show which processes in a live remote-reply runner tree hold the claimed
# registration open on fd 7, across a concurrent re-arm and a capture.
# Usage: live-fd7-pin.sh <firstmate-root>
set -u
ROOT=$1
T=$(mktemp -d /tmp/fm-live-fd.XXXXXX) || exit 1
case "$T" in /tmp/fm-live-fd.*) ;; *) exit 1 ;; esac
PARENT="$T/parent" REMOTE="$T/remote" CLAIMS="$T/claims" FAKE="$T/fake"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$REMOTE/data" "$CLAIMS" "$FAKE"
chmod 700 "$T" "$PARENT" "$PARENT/state" "$PARENT/data" "$CLAIMS"
echo "- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)" > "$PARENT/data/secondmates.md"
: > "$REMOTE/state/parent-replies.status"
cat > "$FAKE/ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac; done
shift 2; exec "$FM_LIVE_ROOT/bin/fm-remote-entrypoint.sh" "$@"
SH
chmod +x "$FAKE/ssh"
renv() { env -u NO_MISTAKES_GATE FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" FM_LIVE_ROOT="$ROOT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" FM_SSH_BIN="$FAKE/ssh" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$T/remote-jobs" FM_REMOTE_REPLY_WAIT_SECONDS=55 "$@"; }
cleanup() {
  renv "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  [ -f "$T/remote-jobs/worker.pid" ] && ( . "$ROOT/bin/fm-remote-job-lib.sh"; fm_remote_job_stop_worker_tree "$(cat "$T/remote-jobs/worker.pid")" ) >/dev/null 2>&1
  rm -rf -- "$T"
}
trap cleanup EXIT
SRC="$PARENT/state/procevent/remote-reply-ios.source"
renv "$ROOT/bin/fm-procevent-remote-reply.sh" arm ios >/dev/null
renv "$ROOT/bin/fm-procevent.sh" start remote-reply-ios > "$T/runner.out" 2>&1 &
for _ in $(seq 1 200); do [ -n "$(ls "$T/remote-jobs" 2>/dev/null)" ] && break; sleep 0.05; done; sleep 1
RP=$(sed -n 2p "$CLAIMS/remote-reply-ios.claim")
desc() { echo "$1"; local c; for c in $(pgrep -P "$1"); do desc "$c"; done; }
echo "runner pid=$RP claimed registration inode=$(stat -c %i "$SRC")"
echo "-- while polling, before concurrent re-arm: fd 7 per process in the runner tree"
for p in $(desc "$RP"); do printf '  pid %s (%s): fd7 -> %s\n' "$p" "$(ps -o comm= -p "$p")" "$(readlink "/proc/$p/fd/7" 2>/dev/null || echo '<closed>')"; done
renv "$ROOT/bin/fm-procevent-remote-reply.sh" arm ios >/dev/null
echo "-- after concurrent re-arm (registration now inode $(stat -c %i "$SRC")): runner fd7 -> $(readlink "/proc/$RP/fd/7" 2>/dev/null || echo '<closed>')"
printf 'working [key=fd]: fd check note\n' >> "$REMOTE/state/parent-replies.status"
for _ in $(seq 1 200); do grep -q 'fd check note' "$PARENT/state/ios.status" 2>/dev/null && break; sleep 0.1; done; sleep 1
echo "-- after capture+autohandle: note mirrored=$(grep -c 'fd check note' "$PARENT/state/ios.status") registration inode=$(stat -c %i "$SRC" 2>/dev/null || echo MISSING) runner_alive=$(kill -0 "$RP" 2>/dev/null && echo yes || echo no) runner fd7 -> $(readlink "/proc/$RP/fd/7" 2>/dev/null || echo '<closed>')"
echo "-- runner output:"; sed 's/^/   /' "$T/runner.out"
