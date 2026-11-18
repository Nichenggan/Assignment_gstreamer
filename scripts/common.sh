#!/usr/bin/env bash
# common.sh - helpers shared by all the scripts (sourced, not executed directly)
#
# - goes to the repository root so every script works when launched from there
# - loads config/team.conf
# - finds the GStreamer tools (on Linux/Codespaces they are in PATH, on our
#   Windows machines the MSVC installer does not always add them to PATH)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

CONFIG_FILE="config/team.conf"
ARTIFACTS_DIR="artifacts"

log_info()  { echo "[$(basename "$0")] $*"; }
log_error() { echo "[$(basename "$0")] ERROR: $*" >&2; }

load_config() {
    if [ ! -r "$CONFIG_FILE" ]; then
        log_error "cannot read $CONFIG_FILE"
        return 1
    fi
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"

    local key
    for key in PATTERN WIDTH HEIGHT FPS PORT OVERLAY_POSITION CONTAINER NETWORK_CODEC RUNTIME; do
        if [ -z "${!key}" ]; then
            log_error "$key is missing in $CONFIG_FILE"
            return 1
        fi
    done

    case "$CONTAINER" in
        matroska) RECORDING_EXT="mkv" ;;
        mpegts)   RECORDING_EXT="ts" ;;
        *) log_error "unsupported CONTAINER=$CONTAINER (matroska or mpegts)"; return 1 ;;
    esac
    case "$NETWORK_CODEC" in
        h264|jpeg) ;;
        *) log_error "unsupported NETWORK_CODEC=$NETWORK_CODEC (h264 or jpeg)"; return 1 ;;
    esac
    return 0
}

find_gstreamer() {
    if command -v gst-launch-1.0 >/dev/null 2>&1; then
        return 0
    fi
    # Windows (Git Bash): try the usual install locations of the MSVC package
    local candidate
    for candidate in \
        "${GSTREAMER_1_0_ROOT_MSVC_X86_64:-}/bin" \
        "${LOCALAPPDATA:-}/Programs/gstreamer/1.0/msvc_x86_64/bin" \
        "/c/Program Files/gstreamer/1.0/msvc_x86_64/bin" \
        "/c/gstreamer/1.0/msvc_x86_64/bin"; do
        if [ -x "$candidate/gst-launch-1.0.exe" ] || [ -x "$candidate/gst-launch-1.0" ]; then
            export PATH="$candidate:$PATH"
            return 0
        fi
    done
    log_error "gst-launch-1.0 not found, install GStreamer 1.x first"
    return 1
}

# max time for one gst-inspect-1.0 call (the first call can rebuild the plugin registry)
GST_INSPECT_TIMEOUT=30

# check_elements elem1 elem2 ... -> fails if one element is not installed
check_elements() {
    local element missing=0 status
    for element in "$@"; do
        timeout -k 5s "${GST_INSPECT_TIMEOUT}s" gst-inspect-1.0 "$element" >/dev/null 2>&1
        status=$?
        if [ $status -eq 124 ] || [ $status -eq 137 ]; then
            log_error "gst-inspect-1.0 $element timed out after ${GST_INSPECT_TIMEOUT}s"
            missing=1
        elif [ $status -ne 0 ]; then
            log_error "GStreamer element '$element' is not available"
            missing=1
        fi
    done
    return $missing
}

# list_descendants PID -> prints the PIDs of all children, grandchildren, ...
# (column 2 = PID, column 3 = PPID in "ps -ef" on Linux and in Git Bash)
list_descendants() {
    local child
    for child in $(ps -ef 2>/dev/null | awk -v parent="$1" 'NR > 1 && $3 == parent { print $2 }'); do
        list_descendants "$child"
        echo "$child"
    done
}

# kill_process_tree PID -> kills PID and every process it started.
# SIGKILL: only used on error/interrupt paths, the normal path stops with EOS.
# (SIGINT/SIGTERM do not reach native programs in Git Bash, see debug-report.md)
kill_process_tree() {
    local root=$1 pid
    [ -n "$root" ] || return 0
    for pid in $(list_descendants "$root") "$root"; do
        kill -KILL "$pid" 2>/dev/null
    done
    wait "$root" 2>/dev/null
    return 0
}

# wait_with_deadline PID SECONDS -> exit status of PID, or 124 if it was still
# running after SECONDS (it is then killed with all its children)
# (real time with $SECONDS: counting "sleep 0.1" iterations is wrong on Windows,
# where each iteration takes much longer than 0.1 s)
wait_with_deadline() {
    local pid=$1 deadline=$((SECONDS + $2))
    while kill -0 "$pid" 2>/dev/null; do
        if [ $SECONDS -ge $deadline ]; then
            kill_process_tree "$pid"
            return 124
        fi
        sleep 0.2
    done
    wait "$pid"
}
