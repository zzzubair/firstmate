#!/usr/bin/env bash
# While a real remote-reply runner holds its claim and polls, re-arm the source
# repeatedly through the real adapter and report whether any real
# re-registration receives the claimed registration's identity (dev:inode),
# which is the identity the runner later uses to retire "its own" registration.
# Usage: live-rearm-identity.sh <firstmate-root> <label> [rearms]
set -u
ROOT=$1 LABEL=$2 N=${3:-40}
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-ident.XXXXXX"); T=$(cd "$T" && pwd -P)
PARENT="$T/parent" REMOTE="$T/remote" CLAIMS="$T/claims" FAKE="$T/fake"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$REMOTE/data" "$CLAIMS" "$FAKE"
chmod 700 "$T" "$PARENT" "$PARENT/state" "$PARENT/data" "$CLAIMS"
echo "- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)" > "$PARENT/data/secondmates.md"
: > "$REMOTE/state/parent-replies.status"
cat > "$FAKE/ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac; done
[ "$1" = remote-mac ] && [ "$2" = fm-remote-entrypoint.sh ] || exit 91
shift 2; exec "$FM_LIVE_ROOT/bin/fm-remote-entrypoint.sh" "$@"
SH
chmod +x "$FAKE/ssh"
renv() {
  env -u NO_MISTAKES_GATE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" FM_LIVE_ROOT="$ROOT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    FM_SSH_BIN="$FAKE/ssh" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$T/remote-jobs" \
    FM_REMOTE_REPLY_WAIT_SECONDS=55 "$@"
}
cleanup() {
  renv "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  [ -f "$T/remote-jobs/worker.pid" ] && ( . "$ROOT/bin/fm-remote-job-lib.sh"; fm_remote_job_stop_worker_tree "$(cat "$T/remote-jobs/worker.pid")" ) >/dev/null 2>&1
  rm -rf -- "$T"
}
trap cleanup EXIT
ident() { stat -c %d:%i "$1" 2>/dev/null; }
SRC="$PARENT/state/procevent/remote-reply-ios.source"
renv "$ROOT/bin/fm-procevent-remote-reply.sh" arm ios >/dev/null
renv "$ROOT/bin/fm-procevent.sh" start remote-reply-ios > "$T/runner.out" 2>&1 &
for _ in $(seq 1 200); do [ -n "$(ls "$T/remote-jobs" 2>/dev/null)" ] && break; sleep 0.05; done; sleep 0.5
claimed=$(ident "$SRC")
hits=0
for i in $(seq 1 "$N"); do
  renv "$ROOT/bin/fm-procevent-remote-reply.sh" arm ios >/dev/null
  now=$(ident "$SRC")
  [ "$now" = "$claimed" ] && { hits=$((hits + 1)); echo "  re-arm $i: registration identity $now == claimed identity"; }
done
alive=no; kill -0 %1 2>/dev/null && alive=yes
echo "== [$LABEL] claimed=$claimed rearms=$N rearms_landing_on_claimed_identity=$hits runner_alive_during=$alive"
