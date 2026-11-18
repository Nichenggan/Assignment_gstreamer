#!/usr/bin/env bash
# debug-stop-signal.sh - reproduces the fault of debug-report.md with DOT graphs
#
# Usage: ./scripts/debug-stop-signal.sh
#
# Runs scripts/sender.sh twice with GST_DEBUG_DUMP_DOT_DIR set. gst-launch-1.0
# writes one .dot file at every state change of the pipeline, so the list of
# files shows which state changes really happened:
#   faulty : stop requested with "timeout -s INT 8s" (no --duration)
#   control: stop decided inside the pipeline with --duration 8 (EOS)
# Each run is bounded (25 s, then the process tree is killed).
# Results: artifacts/dot-faulty/, artifacts/dot-control/ (graphs + sender.log).
# Exit code 0 when both runs could be executed (the fault itself is OS dependent:
# on Windows/Git Bash the faulty run never shuts down, on Linux it should).

. "$(dirname "$0")/common.sh"

case "${1:-}" in -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac

load_config || exit 1
find_gstreamer || exit 1
RUN_DEADLINE=25
CURRENT_PID=""
trap 'kill_process_tree "$CURRENT_PID"; exit 130' INT TERM

run_case() {   # name, command...
    local name=$1; shift
    local dot_dir="$ARTIFACTS_DIR/dot-$name"
    rm -rf "$dot_dir"
    mkdir -p "$dot_dir" || return 1
    log_info "[$name] $*"
    GST_DEBUG_DUMP_DOT_DIR="$(cd "$dot_dir" && pwd)" "$@" > "$dot_dir/sender.log" 2>&1 &
    CURRENT_PID=$!
    wait_with_deadline "$CURRENT_PID" "$RUN_DEADLINE"
    local status=$?
    CURRENT_PID=""
    if [ $status -eq 124 ]; then
        echo "== $name: still running after ${RUN_DEADLINE}s -> process tree killed (exit 124)"
    else
        echo "== $name: exit code $status"
    fi
    echo "   state changes dumped as DOT:"
    ls "$dot_dir" | grep '\.dot$' | sed 's/^[0-9.]*-gst-launch\./     /'
    echo "   gst-launch shutdown messages:"
    local messages
    messages=$(grep -E "Handling interrupt|Interrupt: Stopping|EOS on shutdown|Got EOS|Execution ended" "$dot_dir/sender.log")
    if [ -n "$messages" ]; then echo "$messages" | sed 's/^/     /'; else echo "     (none)"; fi
}

run_case faulty  timeout -s INT 8s bash scripts/sender.sh --headless --duration 0 \
    --output "$ARTIFACTS_DIR/dot-faulty.$RECORDING_EXT" || exit 1
run_case control bash scripts/sender.sh --headless --duration 8 \
    --output "$ARTIFACTS_DIR/dot-control.$RECORDING_EXT" || exit 1
exit 0
