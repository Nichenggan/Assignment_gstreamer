#!/usr/bin/env bash
# receiver.sh - receives the RTP/UDP stream sent by the sender and decodes it
#
# Usage: ./scripts/receiver.sh [--test] [--frames N] [--timeout SECONDS]
#
#   (default)        display mode: decoded video is shown in a window (Ctrl+C to stop)
#   --test           test mode: video is decoded into a fakesink, no window.
#                    The receiver stops by itself (exit 0) after N decoded frames,
#                    so reception can be checked without looking at the screen.
#   --frames N       number of frames to receive in test mode (default: 3 s of video)
#   --timeout S      test mode only: give up with an error after S seconds (default 30)
#
# Start the receiver BEFORE the sender (UDP does not buffer anything for us).

. "$(dirname "$0")/common.sh"

print_usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

TEST_MODE=0
FRAMES_TO_RECEIVE=""
TIMEOUT_SECONDS=30

while [ $# -gt 0 ]; do
    case "$1" in
        --test) TEST_MODE=1 ;;
        --frames)
            [ $# -ge 2 ] || { log_error "--frames needs a value"; exit 2; }
            FRAMES_TO_RECEIVE="$2"; shift ;;
        --timeout)
            [ $# -ge 2 ] || { log_error "--timeout needs a value"; exit 2; }
            TIMEOUT_SECONDS="$2"; shift ;;
        -h|--help) print_usage; exit 0 ;;
        *) log_error "unknown option: $1"; print_usage >&2; exit 2 ;;
    esac
    shift
done

load_config || exit 1
find_gstreamer || exit 1

[ -n "$FRAMES_TO_RECEIVE" ] || FRAMES_TO_RECEIVE=$((FPS * 3))
for value in "$FRAMES_TO_RECEIVE" "$TIMEOUT_SECONDS"; do
    case "$value" in
        ''|*[!0-9]*|0) log_error "--frames and --timeout must be positive integers"; exit 2 ;;
    esac
done

# udpsrc only sees bytes, it cannot guess what is inside the packets, so we
# give the RTP caps explicitly (must match the payloader of the sender).
case "$NETWORK_CODEC" in
    h264)
        RTP_CAPS="application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96"
        DEPAY_DECODE="rtph264depay name=depayloader ! h264parse name=parser ! avdec_h264 name=decoder"
        CODEC_ELEMENTS="rtph264depay h264parse avdec_h264" ;;
    jpeg)
        RTP_CAPS="application/x-rtp,media=video,clock-rate=90000,encoding-name=JPEG,payload=26"
        DEPAY_DECODE="rtpjpegdepay name=depayloader ! jpegdec name=decoder"
        CODEC_ELEMENTS="rtpjpegdepay jpegdec" ;;
esac

if [ "$TEST_MODE" -eq 1 ]; then
    # identity eos-after=N -> sends EOS after N decoded frames, gst-launch then exits with 0.
    # fakesink silent=false + -v prints one "chain" line per frame in the log.
    OUTPUT_PART="identity name=frame_counter eos-after=$FRAMES_TO_RECEIVE ! fakesink name=video_sink sync=false silent=false"
    SINK_ELEMENTS="identity fakesink"
    LAUNCH_FLAGS="-v"
else
    OUTPUT_PART="videoconvert ! autovideosink name=video_sink sync=false"
    SINK_ELEMENTS="videoconvert autovideosink"
    LAUNCH_FLAGS=""
fi

# shellcheck disable=SC2086
check_elements udpsrc rtpjitterbuffer $CODEC_ELEMENTS $SINK_ELEMENTS || exit 1

PIPELINE="udpsrc name=network_source port=$PORT caps=\"$RTP_CAPS\" \
 ! rtpjitterbuffer name=jitterbuffer latency=200 \
 ! $DEPAY_DECODE \
 ! $OUTPUT_PART"

if [ "$TEST_MODE" -eq 1 ]; then
    log_info "test mode: waiting for $FRAMES_TO_RECEIVE $NETWORK_CODEC frames on udp port $PORT (timeout ${TIMEOUT_SECONDS}s)"
    # the receiver has no file to finalize, so stopping it with timeout is ok
    eval "timeout ${TIMEOUT_SECONDS}s gst-launch-1.0 $LAUNCH_FLAGS $PIPELINE"
    STATUS=$?
    if [ $STATUS -eq 124 ]; then
        log_error "timeout: did not receive $FRAMES_TO_RECEIVE frames in ${TIMEOUT_SECONDS}s"
        exit 1
    elif [ $STATUS -ne 0 ]; then
        log_error "receiver pipeline failed (exit code $STATUS)"
        exit $STATUS
    fi
    log_info "RTP_RECEPTION OK: $FRAMES_TO_RECEIVE frames received and decoded"
else
    log_info "display mode: listening on udp port $PORT ($NETWORK_CODEC), Ctrl+C to quit"
    eval "gst-launch-1.0 $PIPELINE"
    STATUS=$?
    [ $STATUS -eq 0 ] || { log_error "receiver pipeline failed (exit code $STATUS)"; exit $STATUS; }
fi
exit 0
