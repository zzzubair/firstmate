#!/usr/bin/env bash
# Live driver: real fm-procevent.sh runner + real fm-procevent-remote-reply.sh
# adapter + real remote entrypoint/delta reader, in a disposable parent/remote
# home pair. SSH transport is a local shim that execs the real remote entrypoint.
# Usage: live-remote-reply-rearm.sh <firstmate-root> <label> [rounds]
set -u
ROOT=$1 LABEL=$2 ROUNDS=${3:-6}
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-rearm.XXXXXX"); T=$(cd "$T" && pwd -P)
PARENT="$T/parent" REMOTE="$T/remote" CLAIMS="$T/claims" FAKE="$T/fake"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$REMOTE/data" "$CLAIMS" "$FAKE"
cat > "$PARENT/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
chmod 700 "$T" "$PARENT" "$PARENT/state" "$PARENT/data" "$CLAIMS"
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
    FM_REMOTE_REPLY_WAIT_SECONDS=30 "$@"
}
cleanup() {
  renv "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$T/remote-jobs/worker.pid" ]; then
    ( . "$ROOT/bin/fm-remote-job-lib.sh"; fm_remote_job_stop_worker_tree "$(cat "$T/remote-jobs/worker.pid")" ) >/dev/null 2>&1 || true
  fi
  rm -rf -- "$T"
}
trap cleanup EXIT
ident() { stat -c %d:%i "$1" 2>/dev/null; }
REG="$PARENT/state/procevent"
SID=$(renv "$ROOT/bin/fm-procevent-remote-reply.sh" source-id ios)
echo "== [$LABEL] root=$ROOT"
renv "$ROOT/bin/fm-procevent-remote-reply.sh" arm ios
renv "$ROOT/bin/fm-procevent.sh" start "$SID" > "$T/runner.out" 2>&1 &
RUNNER=$!
lost=0 delivered=0 recycled=0
for r in $(seq 1 "$ROUNDS"); do
  # Wait until the runner is mid-poll (the remote reader job is running).
  for _ in $(seq 1 200); do [ -n "$(ls "$T/remote-jobs" 2>/dev/null)" ] && break; sleep 0.05; done
  sleep 0.5
  claimed=$(ident "$REG/$SID.source")
  # Concurrent re-arm while the runner polls (e.g. a handler re-handling).
  renv "$ROOT/bin/fm-procevent-remote-reply.sh" arm ios >/dev/null
  after=$(ident "$REG/$SID.source")
  # Create files in the registry dir the way later registrations are created;
  # record if any reuses the claimed registration's identity.
  hit=0
  for _ in $(seq 1 "${PROBES:-50}"); do
    p=$(mktemp "$REG/.probe.XXXXXX") || { hit=err; break; }; [ -n "$claimed" ] && [ "$(ident "$p")" = "$claimed" ] && hit=1; rm -f -- "$p"
  done
  [ "$hit" = 0 ] || recycled=$((recycled + 1))
  # The remote second mate writes a note to its parent.
  printf 'working [key=round-%s]: remote note %s\n' "$r" "$r" >> "$REMOTE/state/parent-replies.status"
  ok=0
  for _ in $(seq 1 300); do grep -Fq "remote note $r" "$PARENT/state/ios.status" 2>/dev/null && { ok=1; break; }; sleep 0.1; done
  sleep 1
  reg_present=no; [ -f "$REG/$SID.source" ] && reg_present=yes
  alive=no; kill -0 "$RUNNER" 2>/dev/null && alive=yes
  owner=$(renv "$ROOT/bin/fm-procevent.sh" list 2>/dev/null | awk -v id="$SID" 'NR>1 && $1==id {print $3; exit}')
  echo "round $r: claimed=$claimed rearmed=$after probe_reused_claimed_identity=$hit note_mirrored=$ok registration_present=$reg_present runner_alive=$alive owner=${owner:-none}"
  [ "$ok" -eq 1 ] && delivered=$((delivered + 1))
  if [ "$reg_present" = no ] || [ "$alive" = no ]; then lost=1; echo "  listener dropped after round $r"; break; fi
done
# Final check: one more note after all rounds must still arrive.
if [ "$lost" -eq 0 ]; then
  printf 'done [key=final]: final remote note\n' >> "$REMOTE/state/parent-replies.status"
  fin=0; for _ in $(seq 1 300); do grep -Fq 'final remote note' "$PARENT/state/ios.status" && { fin=1; break; }; sleep 0.1; done
  echo "final note mirrored=$fin"
fi
echo "-- runner output:"; sed 's/^/   /' "$T/runner.out"
echo "-- parent state/ios.status:"; sed 's/^/   /' "$PARENT/state/ios.status" 2>/dev/null
echo "== [$LABEL] SUMMARY rounds_delivered=$delivered/$ROUNDS probe_identity_reuse_rounds=$recycled listener_lost=$lost"
renv "$ROOT/bin/fm-procevent.sh" retire "$SID" >/dev/null 2>&1 || true
kill "$RUNNER" 2>/dev/null; wait "$RUNNER" 2>/dev/null
