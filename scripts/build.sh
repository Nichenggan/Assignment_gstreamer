#!/usr/bin/env bash
# build.sh - prepares the project
#
# Part 1 (shell pipelines): checks the dependencies and creates the output dirs.
# When CMakeLists.txt exists (part 3, native monitor_sender), it is also built
# into build/. Everything is logged in artifacts/build.log.

. "$(dirname "$0")/common.sh"

BUILD_DIR="build"
BUILD_LOG="$ARTIFACTS_DIR/build.log"

mkdir -p "$BUILD_DIR" "$ARTIFACTS_DIR" || { log_error "cannot create $BUILD_DIR/ or $ARTIFACTS_DIR/"; exit 1; }
: > "$BUILD_LOG"

# log to the console and to build.log at the same time
step() { log_info "$*"; echo "$*" >> "$BUILD_LOG"; }
fail() { log_error "$*"; echo "ERROR: $*" >> "$BUILD_LOG"; echo "BUILD FAILED" >> "$BUILD_LOG"; exit 1; }

step "checking config/team.conf"
load_config >> "$BUILD_LOG" 2>&1 || fail "invalid configuration"

step "checking GStreamer installation"
find_gstreamer || fail "GStreamer not found"
gst-launch-1.0 --version >> "$BUILD_LOG" 2>&1

ELEMENTS="videotestsrc videoconvert textoverlay timeoverlay tee queue fakesink autovideosink \
x264enc h264parse avdec_h264 matroskamux matroskademux mpegtsmux tsdemux filesrc filesink \
udpsrc udpsink rtpjitterbuffer rtph264pay rtph264depay jpegenc jpegdec rtpjpegpay rtpjpegdepay identity"
step "checking GStreamer elements"
# shellcheck disable=SC2086
check_elements $ELEMENTS 2>> "$BUILD_LOG" || fail "some GStreamer elements are missing (see above)"

if [ -f CMakeLists.txt ]; then
    command -v cmake >/dev/null 2>&1 || fail "cmake not found"
    step "configuring native sender (cmake)"
    cmake -S . -B "$BUILD_DIR" >> "$BUILD_LOG" 2>&1 || fail "cmake configure failed, see $BUILD_LOG"
    step "compiling native sender"
    cmake --build "$BUILD_DIR" >> "$BUILD_LOG" 2>&1 || fail "compilation failed, see $BUILD_LOG"
else
    step "no CMakeLists.txt yet: native monitor_sender not built (shell sender only)"
fi

echo "BUILD OK" >> "$BUILD_LOG"
log_info "build done (log: $BUILD_LOG)"
exit 0
