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

# check_elements elem1 elem2 ... -> fails if one element is not installed
check_elements() {
    local element missing=0
    for element in "$@"; do
        if ! gst-inspect-1.0 "$element" >/dev/null 2>&1; then
            log_error "GStreamer element '$element' is not available"
            missing=1
        fi
    done
    return $missing
}
