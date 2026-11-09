#!/usr/bin/env bash
# verify.sh - automated, non-interactive check of the whole chain
#
#   1. dependencies, config and required files
#   2. receiver started in test mode (background)
#   3. sender started in headless mode for a finite duration
#   4. RTP reception, recording validity, EOS and clean termination are checked
#   5. logs + artifacts/verification-summary.txt (PASS/FAIL for each test)
#
# Every step has a timeout, nothing can wait forever.
# Current version tests the shell sender (scripts/sender.sh); it will switch to
# build/monitor_sender once the native application exists.

. "$(dirname "$0")/common.sh"

VERIFY_DURATION=12                       # seconds of video sent by the sender
SENDER_TIMEOUT=$((VERIFY_DURATION + 30))  # max time we give to the sender
RECEIVER_TIMEOUT=$((VERIFY_DURATION + 20))
RECEIVER_START_DELAY=3                   # let udpsrc bind the port before sending

VERIFICATION_LOG="$ARTIFACTS_DIR/verification.log"
SUMMARY_FILE="$ARTIFACTS_DIR/verification-summary.txt"
SENDER_LOG="$ARTIFACTS_DIR/sender.log"
RECEIVER_LOG="$ARTIFACTS_DIR/receiver.log"
BUILD_LOG="$ARTIFACTS_DIR/build.log"

mkdir -p "$ARTIFACTS_DIR" || exit 1
: > "$VERIFICATION_LOG"

RECEIVER_PID=""

# ------------------------------------------------------------------ helpers
vlog() { log_info "$*"; echo "$(date '+%H:%M:%S') $*" >> "$VERIFICATION_LOG"; }

TEST_NAMES="BUILD HELP_OPTION INVALID_ARGUMENTS SENDER_START RECEIVER_START RTP_RECEPTION EOS_HANDLING RECORDING_CREATED RECORDING_DECODABLE CLEAN_TERMINATION"
for name in $TEST_NAMES; do eval "RESULT_$name=FAIL"; done
pass() { eval "RESULT_$1=PASS"; vlog "PASS $1${2:+ - $2}"; }
fail() { eval "RESULT_$1=FAIL"; vlog "FAIL $1${2:+ - $2}"; }

cleanup() {
    if [ -n "$RECEIVER_PID" ] && kill -0 "$RECEIVER_PID" 2>/dev/null; then
        vlog "stopping receiver (pid $RECEIVER_PID)"
        kill "$RECEIVER_PID" 2>/dev/null
        wait "$RECEIVER_PID" 2>/dev/null
    fi
}
trap cleanup EXIT
trap 'vlog "interrupted"; exit 130' INT TERM

write_summary() {
    local overall=PASS name value
    : > "$SUMMARY_FILE"
    for name in $TEST_NAMES; do
        eval "value=\$RESULT_$name"
        echo "$name=$value" >> "$SUMMARY_FILE"
        [ "$value" = PASS ] || overall=FAIL
    done
    echo "OVERALL=$overall" >> "$SUMMARY_FILE"
    echo
    echo "===== verification summary ====="
    cat "$SUMMARY_FILE"
    [ "$overall" = PASS ]
}

# ------------------------------------------------------------------ 1. prerequisites
vlog "checking configuration"
if ! load_config >> "$VERIFICATION_LOG" 2>&1; then
    vlog "config/team.conf missing or invalid, cannot continue"
    write_summary; exit 1
fi
RECORDING_FILE="$ARTIFACTS_DIR/test-recording.$RECORDING_EXT"
rm -f "$RECORDING_FILE"

vlog "checking required commands"
MISSING=0
find_gstreamer >> "$VERIFICATION_LOG" 2>&1 || MISSING=1
for command_name in gst-launch-1.0 gst-inspect-1.0 gst-discoverer-1.0 timeout; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        vlog "missing command: $command_name"; MISSING=1
    fi
done
if [ $MISSING -eq 0 ]; then
    check_elements videotestsrc textoverlay timeoverlay tee queue x264enc h264parse \
        udpsrc udpsink rtpjitterbuffer fakesink identity avdec_h264 >> "$VERIFICATION_LOG" 2>&1 || MISSING=1
fi
if [ $MISSING -ne 0 ]; then
    vlog "dependencies missing, cannot continue"
    write_summary; exit 1
fi

vlog "checking required files"
for required_file in config/team.conf scripts/sender.sh scripts/receiver.sh scripts/play-recording.sh \
                     scripts/build.sh scripts/clean.sh architecture.md README.md; do
    [ -f "$required_file" ] || { vlog "missing file: $required_file"; MISSING=1; }
done
[ $MISSING -eq 0 ] || { write_summary; exit 1; }

# BUILD: build.sh must have been run successfully before
if [ -f "$BUILD_LOG" ] && grep -q "^BUILD OK" "$BUILD_LOG"; then
    pass BUILD
else
    fail BUILD "run ./scripts/build.sh first (no 'BUILD OK' in $BUILD_LOG)"
fi

# ------------------------------------------------------------------ 2. command line
SENDER_CMD="scripts/sender.sh"
if timeout 10s bash "$SENDER_CMD" --help >> "$VERIFICATION_LOG" 2>&1; then
    pass HELP_OPTION "$SENDER_CMD --help returns 0"
else
    fail HELP_OPTION "$SENDER_CMD --help failed"
fi

INVALID_OK=1
for invalid_args in "--duration abc" "--duration" "--unknown-option"; do
    # shellcheck disable=SC2086
    if timeout 20s bash "$SENDER_CMD" --headless $invalid_args >> "$VERIFICATION_LOG" 2>&1; then
        vlog "'$invalid_args' was accepted but should be rejected"
        INVALID_OK=0
    fi
done
[ $INVALID_OK -eq 1 ] && pass INVALID_ARGUMENTS "bad arguments give a non-zero exit code" || fail INVALID_ARGUMENTS

# ------------------------------------------------------------------ 3. receiver + sender
FRAMES_EXPECTED=$((FPS * 3))
vlog "starting receiver in test mode (expects $FRAMES_EXPECTED frames on port $PORT)"
bash scripts/receiver.sh --test --frames "$FRAMES_EXPECTED" --timeout "$RECEIVER_TIMEOUT" > "$RECEIVER_LOG" 2>&1 &
RECEIVER_PID=$!
sleep "$RECEIVER_START_DELAY"
if kill -0 "$RECEIVER_PID" 2>/dev/null; then
    pass RECEIVER_START "pid $RECEIVER_PID"
else
    fail RECEIVER_START "receiver exited immediately, see $RECEIVER_LOG"
fi

vlog "starting sender (headless, ${VERIFY_DURATION}s) -> $RECORDING_FILE"
SENDER_START_TIME=$(date +%s)
# SIGINT first (gst-launch -e turns it into EOS), SIGKILL 5s later if still alive
timeout -s INT -k 5s "${SENDER_TIMEOUT}s" bash "$SENDER_CMD" --headless --duration "$VERIFY_DURATION" \
    --output "$RECORDING_FILE" > "$SENDER_LOG" 2>&1
SENDER_STATUS=$?
SENDER_ELAPSED=$(( $(date +%s) - SENDER_START_TIME ))
vlog "sender finished with exit code $SENDER_STATUS after ${SENDER_ELAPSED}s"

if grep -q "Setting pipeline to PLAYING" "$SENDER_LOG"; then
    pass SENDER_START "pipeline reached PLAYING"
else
    fail SENDER_START "pipeline never reached PLAYING, see $SENDER_LOG"
fi

if grep -q "Got EOS from element" "$SENDER_LOG"; then
    pass EOS_HANDLING "EOS reached the end of the pipeline"
else
    fail EOS_HANDLING "no EOS message in $SENDER_LOG"
fi

if [ $SENDER_STATUS -eq 0 ] && grep -q "Freeing pipeline" "$SENDER_LOG"; then
    CLEAN_SENDER=1
else
    CLEAN_SENDER=0
    [ $SENDER_STATUS -eq 124 ] || [ $SENDER_STATUS -eq 137 ] && vlog "sender TIMEOUT after ${SENDER_TIMEOUT}s"
fi

# ------------------------------------------------------------------ 4. results
vlog "waiting for the receiver to finish"
wait "$RECEIVER_PID"
RECEIVER_STATUS=$?
RECEIVER_PID=""
FRAMES_DECODED=$(grep -c "last-message = chain" "$RECEIVER_LOG")
if [ $RECEIVER_STATUS -eq 0 ] && [ "$FRAMES_DECODED" -gt 0 ]; then
    pass RTP_RECEPTION "$FRAMES_DECODED decoded frames seen by the fakesink"
else
    fail RTP_RECEPTION "receiver exit code $RECEIVER_STATUS, $FRAMES_DECODED frames, see $RECEIVER_LOG"
fi

if [ -s "$RECORDING_FILE" ]; then
    pass RECORDING_CREATED "$RECORDING_FILE, $(wc -c < "$RECORDING_FILE") bytes"
else
    fail RECORDING_CREATED "$RECORDING_FILE missing or empty"
fi

# a non-empty file is not enough: it must be discoverable AND fully decodable
DISCOVERER_OUTPUT=$(timeout 20s gst-discoverer-1.0 "$RECORDING_FILE" 2>&1)
echo "$DISCOVERER_OUTPUT" >> "$VERIFICATION_LOG"
# "Duration: 0:00:12.000000000" -> 12
RECORDED_SECONDS=$(echo "$DISCOVERER_OUTPUT" | sed -n 's/^ *Duration: \([0-9]*\):\([0-9]*\):\([0-9]*\).*/\1 \2 \3/p' | head -1 \
    | awk '{ print $1 * 3600 + $2 * 60 + $3 }')
vlog "recording duration according to gst-discoverer: ${RECORDED_SECONDS:-?}s (expected ~${VERIFY_DURATION}s)"
if echo "$DISCOVERER_OUTPUT" | grep -q "H.264" \
   && [ "${RECORDED_SECONDS:-0}" -ge $((VERIFY_DURATION - 2)) ] \
   && timeout 30s bash scripts/play-recording.sh --headless "$RECORDING_FILE" >> "$VERIFICATION_LOG" 2>&1; then
    pass RECORDING_DECODABLE "$(echo "$DISCOVERER_OUTPUT" | grep -m1 Duration | sed 's/^ *//')"
else
    fail RECORDING_DECODABLE "gst-discoverer / decode failed, see $VERIFICATION_LOG"
fi

# clean termination: sender exited 0 by itself and no gst-launch process is left
LEFTOVER=0
if command -v tasklist >/dev/null 2>&1; then
    tasklist //FI "IMAGENAME eq gst-launch-1.0.exe" 2>/dev/null | grep -qi "gst-launch" && LEFTOVER=1
elif command -v pgrep >/dev/null 2>&1; then
    pgrep -u "$(id -u)" -f "gst-launch-1.0.*($PORT|test-recording)" >/dev/null && LEFTOVER=1
fi
if [ $CLEAN_SENDER -eq 1 ] && [ $LEFTOVER -eq 0 ]; then
    pass CLEAN_TERMINATION "sender exit code 0, no process left"
else
    fail CLEAN_TERMINATION "sender exit code $SENDER_STATUS, leftover processes=$LEFTOVER"
fi

write_summary
exit $?
