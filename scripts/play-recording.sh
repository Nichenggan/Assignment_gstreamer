#!/usr/bin/env bash
# play-recording.sh - plays a recording made by the sender
#
# Usage: ./scripts/play-recording.sh [--headless] [FILE]
#
#   FILE         recording to play (default: artifacts/recording.<ext>)
#   --headless   decode the whole file into a fakesink (no window), useful to
#                check that the file is valid when there is no display

. "$(dirname "$0")/common.sh"

print_usage() {
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
}

HEADLESS=0
RECORDING_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --headless) HEADLESS=1 ;;
        -h|--help) print_usage; exit 0 ;;
        -*) log_error "unknown option: $1"; print_usage >&2; exit 2 ;;
        *) RECORDING_FILE="$1" ;;
    esac
    shift
done

load_config || exit 1
find_gstreamer || exit 1

[ -n "$RECORDING_FILE" ] || RECORDING_FILE="$ARTIFACTS_DIR/recording.$RECORDING_EXT"
if [ ! -s "$RECORDING_FILE" ]; then
    log_error "recording '$RECORDING_FILE' not found or empty (run ./scripts/sender.sh first)"
    exit 1
fi

# pick the demuxer from the file extension, not from the config, so we can
# also play a file recorded with the other container
case "$RECORDING_FILE" in
    *.mkv) DEMUXER="matroskademux" ;;
    *.ts)  DEMUXER="tsdemux" ;;
    *) log_error "unknown extension for '$RECORDING_FILE' (expected .mkv or .ts)"; exit 1 ;;
esac

if [ "$HEADLESS" -eq 1 ]; then
    # sync=false: decode as fast as possible, we only want to know if it decodes
    VIDEO_SINK="fakesink name=video_sink sync=false"
else
    VIDEO_SINK="autovideosink name=video_sink"
fi

check_elements filesrc "$DEMUXER" h264parse avdec_h264 videoconvert || exit 1

log_info "playing $RECORDING_FILE ($(wc -c < "$RECORDING_FILE") bytes)"
gst-launch-1.0 filesrc location="$RECORDING_FILE" \
    ! "$DEMUXER" name=demuxer \
    ! h264parse name=parser \
    ! avdec_h264 name=decoder \
    ! videoconvert \
    ! $VIDEO_SINK
STATUS=$?

if [ $STATUS -ne 0 ]; then
    log_error "playback failed (exit code $STATUS), the file is probably not finalized"
    exit $STATUS
fi
log_info "playback finished"
exit 0
