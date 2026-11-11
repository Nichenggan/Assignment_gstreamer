#!/usr/bin/env bash
# run-experiment.sh - part 5: H.264/RTP versus JPEG/RTP on the network branch
#
# Usage: ./scripts/run-experiment.sh [--duration SECONDS] [--repeats N]
#
#   --duration S   length of each run (default 45, the assignment asks >= 45)
#   --repeats N    runs per configuration (default 2)
#
# Only --codec changes between the two configurations. Everything else
# (pattern, size, fps, recording branch, machine, duration) is the same.
#
# For each run:
#   - a raw UDP capture (udpsrc ! filesink) counts the bytes really sent on the port
#   - the CPU time of monitor_sender is sampled 1 s before the end of the run
#   - the size of the recording and the warnings/errors of the sender are collected
# Results: evidence/measurements.csv, logs in artifacts/experiment/.
# Needs ./scripts/build.sh first.

. "$(dirname "$0")/common.sh"

RUN_DURATION=45
REPEATS=2
while [ $# -gt 0 ]; do
    case "$1" in
        --duration) RUN_DURATION="$2"; shift ;;
        --repeats)  REPEATS="$2"; shift ;;
        -h|--help)  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) log_error "unknown option: $1"; exit 2 ;;
    esac
    shift
done
for value in "$RUN_DURATION" "$REPEATS"; do
    case "$value" in ''|*[!0-9]*|0) log_error "--duration and --repeats must be positive integers"; exit 2 ;; esac
done

load_config || exit 1
find_gstreamer || exit 1

SENDER_BIN="build/monitor_sender"
[ -x "$SENDER_BIN.exe" ] && SENDER_BIN="$SENDER_BIN.exe"
[ -x "$SENDER_BIN" ] || { log_error "$SENDER_BIN not found, run ./scripts/build.sh first"; exit 1; }

EXPERIMENT_DIR="$ARTIFACTS_DIR/experiment"
CSV_FILE="evidence/measurements.csv"
mkdir -p "$EXPERIMENT_DIR" evidence || exit 1

IS_WINDOWS=0
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;; esac
CPU_CORES=$(nproc 2>/dev/null || echo 1)

# prints "<cpu_seconds> <elapsed_seconds>" for a running process (MSYS or Linux pid)
sample_cpu() {
    local pid=$1
    if [ $IS_WINDOWS -eq 1 ]; then
        local winpid
        winpid=$(cat "/proc/$pid/winpid" 2>/dev/null) || return 1
        powershell.exe -NoProfile -Command \
            "\$p = Get-Process -Id $winpid -ErrorAction Stop; '{0:F2} {1:F2}' -f \$p.TotalProcessorTime.TotalSeconds, ((Get-Date) - \$p.StartTime).TotalSeconds" \
            2>/dev/null | tr -d '\r' | tr ',' '.'
    else
        local ticks utime stime start uptime
        ticks=$(getconf CLK_TCK)
        read -r utime stime start <<< "$(awk '{print $14, $15, $22}' "/proc/$pid/stat")" || return 1
        uptime=$(awk '{print $1}' /proc/uptime)
        awk -v u="$utime" -v s="$stime" -v st="$start" -v up="$uptime" -v t="$ticks" \
            'BEGIN { printf "%.2f %.2f\n", (u + s) / t, up - st / t }'
    fi
}

echo "run,codec,repetition,duration_s,sender_exit_code,sender_cpu_s,sender_elapsed_s,sender_cpu_percent_one_core,network_bytes,network_kbit_s,recording_bytes,sender_warnings,sender_errors,cpu_cores" > "$CSV_FILE"

log_info "experiment: H.264 vs JPEG over RTP, ${RUN_DURATION}s per run, $REPEATS repetitions"
log_info "fixed: pattern=$PATTERN ${WIDTH}x${HEIGHT}@${FPS}fps port=$PORT, recording H.264/$CONTAINER"

RUN_NUMBER=0
for repetition in $(seq 1 "$REPEATS"); do
    for codec in h264 jpeg; do
        RUN_NUMBER=$((RUN_NUMBER + 1))
        RUN_NAME="run${RUN_NUMBER}-${codec}-r${repetition}"
        CAPTURE_FILE="$EXPERIMENT_DIR/$RUN_NAME.udp"
        RECORDING_FILE="$EXPERIMENT_DIR/$RUN_NAME.$RECORDING_EXT"
        SENDER_LOG="$EXPERIMENT_DIR/$RUN_NAME-sender.log"
        CAPTURE_LOG="$EXPERIMENT_DIR/$RUN_NAME-capture.log"
        rm -f "$CAPTURE_FILE" "$RECORDING_FILE"

        log_info "[$RUN_NAME] starting UDP capture on port $PORT"
        # raw UDP payloads (RTP header + data) written unbuffered: file size = bytes received.
        # It has no file format to finalize, so it can simply be killed at the end.
        gst-launch-1.0 udpsrc port="$PORT" buffer-size=4194304 \
            ! filesink location="$CAPTURE_FILE" buffer-mode=unbuffered > "$CAPTURE_LOG" 2>&1 &
        CAPTURE_PID=$!
        sleep 2

        log_info "[$RUN_NAME] starting monitor_sender --codec $codec for ${RUN_DURATION}s"
        "$SENDER_BIN" --pattern "$PATTERN" --width "$WIDTH" --height "$HEIGHT" --fps "$FPS" \
            --port "$PORT" --output "$RECORDING_FILE" --duration "$RUN_DURATION" --headless \
            --codec "$codec" --overlay-position "$OVERLAY_POSITION" --names "$TEAM_MEMBERS" \
            > "$SENDER_LOG" 2>&1 &
        SENDER_PID=$!

        # sample the CPU 1 s before the EOS (the process is gone after it)
        sleep $((RUN_DURATION - 1))
        CPU_SAMPLE=$(sample_cpu "$SENDER_PID")
        wait "$SENDER_PID"
        SENDER_STATUS=$?

        # stop the capture (no more packets anyway). SIGKILL because SIGINT does not
        # reach native programs in Git Bash (see debug-report.md)
        sleep 1
        kill -KILL "$CAPTURE_PID" 2>/dev/null
        wait "$CAPTURE_PID" 2>/dev/null

        read -r CPU_SECONDS ELAPSED_SECONDS <<< "${CPU_SAMPLE:-NA NA}"
        if [ "$CPU_SECONDS" != NA ]; then
            CPU_PERCENT=$(awk -v c="$CPU_SECONDS" -v e="$ELAPSED_SECONDS" 'BEGIN { printf "%.1f", 100 * c / e }')
        else
            CPU_PERCENT=NA
        fi
        NETWORK_BYTES=$(wc -c < "$CAPTURE_FILE" 2>/dev/null || echo 0)
        NETWORK_KBPS=$(awk -v b="$NETWORK_BYTES" -v d="$RUN_DURATION" 'BEGIN { printf "%.1f", b * 8 / 1000 / d }')
        RECORDING_BYTES=$(wc -c < "$RECORDING_FILE" 2>/dev/null || echo 0)
        WARNINGS=$(grep -c "PIPELINE_WARNING" "$SENDER_LOG")
        ERRORS=$(grep -c "PIPELINE_ERROR" "$SENDER_LOG")

        echo "$RUN_NAME,$codec,$repetition,$RUN_DURATION,$SENDER_STATUS,$CPU_SECONDS,$ELAPSED_SECONDS,$CPU_PERCENT,$NETWORK_BYTES,$NETWORK_KBPS,$RECORDING_BYTES,$WARNINGS,$ERRORS,$CPU_CORES" >> "$CSV_FILE"
        log_info "[$RUN_NAME] exit=$SENDER_STATUS cpu=${CPU_PERCENT}% network=${NETWORK_KBPS} kbit/s recording=${RECORDING_BYTES} B"

        rm -f "$CAPTURE_FILE"   # can be large, only its size matters
    done
done

log_info "results written to $CSV_FILE"
column -s, -t < "$CSV_FILE" 2>/dev/null || cat "$CSV_FILE"
exit 0
