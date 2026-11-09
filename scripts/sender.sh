#!/usr/bin/env bash
# sender.sh - shell (gst-launch) version of the video monitoring sender
#
#   videotestsrc -> caps -> overlays -> tee -+-> A: preview
#                                            +-> B: recording (H.264 + container)
#                                            +-> C: RTP/UDP transmission
#
# Usage: ./scripts/sender.sh [--headless] [--duration SECONDS] [--output FILE]
#
#   --headless          preview branch uses fakesink instead of a window
#   --duration SECONDS  stop by itself after SECONDS (EOS is sent, file is finalized)
#                       default: RUNTIME from config/team.conf, 0 = run until Ctrl+C
#   --output FILE       recording file (default: artifacts/recording.<ext>)

. "$(dirname "$0")/common.sh"

print_usage() {
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

HEADLESS=0
DURATION=""
OUTPUT_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --headless) HEADLESS=1 ;;
        --duration)
            [ $# -ge 2 ] || { log_error "--duration needs a value"; exit 2; }
            DURATION="$2"; shift ;;
        --output)
            [ $# -ge 2 ] || { log_error "--output needs a value"; exit 2; }
            OUTPUT_FILE="$2"; shift ;;
        -h|--help) print_usage; exit 0 ;;
        *) log_error "unknown option: $1"; print_usage >&2; exit 2 ;;
    esac
    shift
done

load_config || exit 1
find_gstreamer || exit 1

[ -n "$DURATION" ] || DURATION="$RUNTIME"
case "$DURATION" in
    ''|*[!0-9]*) log_error "--duration must be a positive integer (got '$DURATION')"; exit 2 ;;
esac
[ -n "$OUTPUT_FILE" ] || OUTPUT_FILE="$ARTIFACTS_DIR/recording.$RECORDING_EXT"
mkdir -p "$(dirname "$OUTPUT_FILE")" || exit 1

# ---------------------------------------------------------------- overlays
case "$OVERLAY_POSITION" in
    top-left)      NAMES_VALIGN=top;    NAMES_HALIGN=left;   INFO_VALIGN=bottom; INFO_HALIGN=left ;;
    top-center)    NAMES_VALIGN=top;    NAMES_HALIGN=center; INFO_VALIGN=bottom; INFO_HALIGN=left ;;
    bottom-right)  NAMES_VALIGN=bottom; NAMES_HALIGN=right;  INFO_VALIGN=top;    INFO_HALIGN=left ;;
    *) log_error "unsupported OVERLAY_POSITION=$OVERLAY_POSITION"; exit 1 ;;
esac

# keyframe every 2 s for the recording, every 1 s for the network
# (a receiver that joins late only waits 1 s for a picture)
RECORD_KEYINT=$((FPS * 2))
NETWORK_KEYINT=$FPS
NETWORK_BITRATE_KBPS=1000

# ---------------------------------------------------------------- source
# with a duration we let videotestsrc stop by itself after N frames: it sends
# EOS, the EOS goes through the tee into the 3 branches and the muxer writes
# its index before gst-launch exits. No kill needed.
NUM_BUFFERS=-1
if [ "$DURATION" -gt 0 ]; then
    NUM_BUFFERS=$((DURATION * FPS))
fi

RAW_CAPS="video/x-raw,format=I420,width=$WIDTH,height=$HEIGHT,framerate=$FPS/1"

SOURCE_PART="videotestsrc name=video_source is-live=true pattern=$PATTERN num-buffers=$NUM_BUFFERS \
 ! video/x-raw,width=$WIDTH,height=$HEIGHT,framerate=$FPS/1 \
 ! videoconvert name=source_convert \
 ! textoverlay name=names_overlay text=\"$TEAM_MEMBERS\" valignment=$NAMES_VALIGN halignment=$NAMES_HALIGN font-desc=\"Sans 14\" shaded-background=true \
 ! timeoverlay name=time_overlay time-mode=running-time text=\"${WIDTH}x${HEIGHT} @ ${FPS} fps | elapsed\" valignment=$INFO_VALIGN halignment=$INFO_HALIGN font-desc=\"Sans 12\" shaded-background=true \
 ! videoconvert ! $RAW_CAPS \
 ! tee name=split"

# ---------------------------------------------------------------- branch A
if [ "$HEADLESS" -eq 1 ]; then
    PREVIEW_SINK="fakesink name=preview_sink sync=true"
else
    PREVIEW_SINK="autovideosink name=preview_sink sync=true"
fi
# leaky queue: if the window is slow we drop old frames instead of blocking the tee
PREVIEW_BRANCH="split. ! queue name=preview_queue max-size-buffers=5 max-size-time=0 max-size-bytes=0 leaky=downstream \
 ! videoconvert name=preview_convert ! $PREVIEW_SINK"

# ---------------------------------------------------------------- branch B
case "$CONTAINER" in
    matroska) RECORD_MUXER="matroskamux name=record_muxer" ;;
    mpegts)   RECORD_MUXER="mpegtsmux name=record_muxer" ;;
esac
RECORD_BRANCH="split. ! queue name=record_queue max-size-time=3000000000 max-size-buffers=0 max-size-bytes=0 \
 ! x264enc name=record_encoder speed-preset=ultrafast tune=zerolatency key-int-max=$RECORD_KEYINT \
 ! h264parse name=record_parser ! $RECORD_MUXER \
 ! filesink name=record_sink location=\"$OUTPUT_FILE\""

# ---------------------------------------------------------------- branch C
case "$NETWORK_CODEC" in
    h264)
        NETWORK_ENCODE="x264enc name=network_encoder speed-preset=ultrafast tune=zerolatency bitrate=$NETWORK_BITRATE_KBPS key-int-max=$NETWORK_KEYINT \
 ! video/x-h264,profile=baseline \
 ! rtph264pay name=network_payloader pt=96 config-interval=1" ;;
    jpeg)
        NETWORK_ENCODE="jpegenc name=network_encoder quality=80 \
 ! rtpjpegpay name=network_payloader pt=26" ;;
esac
NETWORK_BRANCH="split. ! queue name=network_queue max-size-buffers=10 max-size-time=0 max-size-bytes=0 leaky=downstream \
 ! $NETWORK_ENCODE \
 ! udpsink name=network_sink host=127.0.0.1 port=$PORT sync=true"

PIPELINE="$SOURCE_PART $PREVIEW_BRANCH $RECORD_BRANCH $NETWORK_BRANCH"

# ---------------------------------------------------------------- run
REQUIRED_ELEMENTS="videotestsrc videoconvert textoverlay timeoverlay tee queue x264enc h264parse filesink udpsink"
[ "$HEADLESS" -eq 1 ] && REQUIRED_ELEMENTS="$REQUIRED_ELEMENTS fakesink" || REQUIRED_ELEMENTS="$REQUIRED_ELEMENTS autovideosink"
[ "$CONTAINER" = matroska ] && REQUIRED_ELEMENTS="$REQUIRED_ELEMENTS matroskamux" || REQUIRED_ELEMENTS="$REQUIRED_ELEMENTS mpegtsmux"
[ "$NETWORK_CODEC" = h264 ] && REQUIRED_ELEMENTS="$REQUIRED_ELEMENTS rtph264pay" || REQUIRED_ELEMENTS="$REQUIRED_ELEMENTS jpegenc rtpjpegpay"
# shellcheck disable=SC2086
check_elements $REQUIRED_ELEMENTS || exit 1

log_info "pattern=$PATTERN ${WIDTH}x${HEIGHT}@${FPS}fps codec=$NETWORK_CODEC -> udp://127.0.0.1:$PORT"
log_info "recording ($CONTAINER) -> $OUTPUT_FILE"
if [ "$DURATION" -gt 0 ]; then
    log_info "running for $DURATION s ($NUM_BUFFERS frames), headless=$HEADLESS"
else
    log_info "running until Ctrl+C (EOS is sent on interrupt thanks to -e), headless=$HEADLESS"
fi

# -e : on Ctrl+C gst-launch sends EOS first, so the recording is still finalized
eval "gst-launch-1.0 -e $PIPELINE"
STATUS=$?

if [ $STATUS -ne 0 ]; then
    log_error "gst-launch-1.0 failed (exit code $STATUS)"
    exit $STATUS
fi
if [ ! -s "$OUTPUT_FILE" ]; then
    log_error "recording $OUTPUT_FILE is missing or empty"
    exit 1
fi
log_info "done, recording saved in $OUTPUT_FILE ($(wc -c < "$OUTPUT_FILE") bytes)"
exit 0
