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
# The sender under test is the native build/monitor_sender (built by build.sh).

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

TEST_NAMES="BUILD HELP_OPTION INVALID_ARGUMENTS SENDER_START RECEIVER_START RTP_RECEPTION EOS_HANDLING RECORDING_CREATED RECORDING_DECODABLE DYNAMIC_PROPERTY CLEAN_TERMINATION"
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
    # elements of the sender + receiver + recording check for the assigned configuration
    REQUIRED_ELEMENTS="videotestsrc videoconvert videobalance textoverlay timeoverlay tee queue fakesink \
        x264enc h264parse avdec_h264 filesrc filesink udpsrc udpsink rtpjitterbuffer identity"
    case "$CONTAINER" in
        matroska) REQUIRED_ELEMENTS="$REQUIRED_ELEMENTS matroskamux matroskademux" ;;
        mpegts)   REQUIRED_ELEMENTS="$REQUIRED_ELEMENTS mpegtsmux tsdemux" ;;
    esac
    case "$NETWORK_CODEC" in
        h264) REQUIRED_ELEMENTS="$REQUIRED_ELEMENTS rtph264pay rtph264depay" ;;
        jpeg) REQUIRED_ELEMENTS="$REQUIRED_ELEMENTS jpegenc jpegdec rtpjpegpay rtpjpegdepay" ;;
    esac
    # shellcheck disable=SC2086
    if check_elements $REQUIRED_ELEMENTS >> "$VERIFICATION_LOG" 2>&1; then
        vlog "all $(echo $REQUIRED_ELEMENTS | wc -w) GStreamer elements available"
    else
        MISSING=1
    fi
fi
if [ $MISSING -ne 0 ]; then
    vlog "dependencies missing, cannot continue"
    write_summary; exit 1
fi

vlog "checking required files"
for required_file in config/team.conf CMakeLists.txt src/monitor_sender.c \
                     README.md architecture.md AI_USAGE.md CONTRIBUTIONS.md debug-report.md experiment.md \
                     evidence/pipeline.png evidence/measurements.csv; do
    [ -s "$required_file" ] || { vlog "missing or empty file: $required_file"; MISSING=1; }
done
for required_script in build.sh clean.sh sender.sh receiver.sh play-recording.sh run-experiment.sh verify.sh; do
    [ -x "scripts/$required_script" ] || { vlog "missing or not executable: scripts/$required_script"; MISSING=1; }
done
[ $MISSING -eq 0 ] || { write_summary; exit 1; }
vlog "all required source, documentation and evidence files present"

# BUILD: build.sh must have been run successfully and produced the executable
SENDER_CMD="build/monitor_sender"
[ -x "$SENDER_CMD.exe" ] && SENDER_CMD="$SENDER_CMD.exe"   # Windows build
if [ -f "$BUILD_LOG" ] && grep -q "^BUILD OK" "$BUILD_LOG" && [ -x "$SENDER_CMD" ]; then
    pass BUILD "$SENDER_CMD"
else
    fail BUILD "run ./scripts/build.sh first (no 'BUILD OK' in $BUILD_LOG or no $SENDER_CMD)"
    write_summary; exit 1
fi

# ------------------------------------------------------------------ 2. command line
if timeout 10s "$SENDER_CMD" --help >> "$VERIFICATION_LOG" 2>&1; then
    pass HELP_OPTION "monitor_sender --help returns 0"
else
    fail HELP_OPTION "monitor_sender --help failed"
fi

# arguments taken from the team configuration
VALID_ARGS="--pattern $PATTERN --width $WIDTH --height $HEIGHT --fps $FPS --port $PORT"
INVALID_OK=1
for invalid_args in \
    "" \
    "--pattern $PATTERN --width $WIDTH --height $HEIGHT --fps $FPS --port $PORT" \
    "$VALID_ARGS --output $ARTIFACTS_DIR/x.mkv --width abc" \
    "$VALID_ARGS --output $ARTIFACTS_DIR/x.mkv --fps 0" \
    "$VALID_ARGS --output $ARTIFACTS_DIR/x.mkv --port 80" \
    "$VALID_ARGS --output $ARTIFACTS_DIR/x.mkv --pattern not-a-pattern" \
    "$VALID_ARGS --output $ARTIFACTS_DIR/x.avi" \
    "$VALID_ARGS --output $ARTIFACTS_DIR/x.mkv --unknown-option"; do
    # shellcheck disable=SC2086
    timeout 10s "$SENDER_CMD" --headless --duration 1 $invalid_args >> "$VERIFICATION_LOG" 2>&1
    status=$?
    if [ $status -eq 0 ] || [ $status -eq 124 ]; then
        vlog "'$invalid_args' was not rejected (exit code $status)"
        INVALID_OK=0
    fi
done
rm -f "$ARTIFACTS_DIR/x.mkv" "$ARTIFACTS_DIR/x.avi"
[ $INVALID_OK -eq 1 ] && pass INVALID_ARGUMENTS "8 bad command lines give a non-zero exit code" || fail INVALID_ARGUMENTS

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
# Normal stop = --duration (EOS sent from inside monitor_sender). The timeout is only
# a watchdog: SIGINT (works on Linux, not delivered to native programs in Git Bash,
# see debug-report.md), then SIGKILL 5s later. If it acts, EOS/clean tests fail.
# shellcheck disable=SC2086
timeout -s INT -k 5s "${SENDER_TIMEOUT}s" "$SENDER_CMD" $VALID_ARGS --output "$RECORDING_FILE" \
    --duration "$VERIFY_DURATION" --headless --codec "$NETWORK_CODEC" \
    --overlay-position "$OVERLAY_POSITION" --names "$TEAM_MEMBERS" > "$SENDER_LOG" 2>&1
SENDER_STATUS=$?
SENDER_ELAPSED=$(( $(date +%s) - SENDER_START_TIME ))
vlog "sender finished with exit code $SENDER_STATUS after ${SENDER_ELAPSED}s"

if grep -q "PIPELINE_STATE PAUSED -> PLAYING" "$SENDER_LOG"; then
    pass SENDER_START "pipeline reached PLAYING"
else
    fail SENDER_START "pipeline never reached PLAYING, see $SENDER_LOG"
fi

if grep -q "STOP_REQUESTED reason=duration" "$SENDER_LOG" && grep -q "^EOS_RECEIVED" "$SENDER_LOG"; then
    pass EOS_HANDLING "EOS sent after ${VERIFY_DURATION}s and received on the bus"
else
    fail EOS_HANDLING "no STOP_REQUESTED/EOS_RECEIVED in $SENDER_LOG"
fi

# with 12 s we expect a change at 5 s and at 10 s
DYNAMIC_CHANGES=$(grep -c "^DYNAMIC_PROPERTY element=video_balance property=brightness" "$SENDER_LOG")
if [ "$DYNAMIC_CHANGES" -ge $((VERIFY_DURATION / 5)) ]; then
    pass DYNAMIC_PROPERTY "$DYNAMIC_CHANGES brightness changes logged"
else
    fail DYNAMIC_PROPERTY "only $DYNAMIC_CHANGES changes logged, expected $((VERIFY_DURATION / 5))"
fi

if [ $SENDER_STATUS -eq 0 ] && grep -q "^EXIT code=0" "$SENDER_LOG"; then
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

# clean termination: sender exited 0 by itself and no sender/receiver process is left
LEFTOVER=0
if command -v tasklist >/dev/null 2>&1; then
    for image in gst-launch-1.0.exe monitor_sender.exe; do
        tasklist //FI "IMAGENAME eq $image" 2>/dev/null | grep -qi "${image%.exe}" && LEFTOVER=1
    done
elif command -v pgrep >/dev/null 2>&1; then
    pgrep -u "$(id -u)" -f "(gst-launch-1.0.*port=$PORT|monitor_sender)" >/dev/null && LEFTOVER=1
fi
if [ $CLEAN_SENDER -eq 1 ] && [ $LEFTOVER -eq 0 ]; then
    pass CLEAN_TERMINATION "sender exit code 0, no process left"
else
    fail CLEAN_TERMINATION "sender exit code $SENDER_STATUS, leftover processes=$LEFTOVER"
fi

write_summary
exit $?
