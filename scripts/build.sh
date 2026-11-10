#!/usr/bin/env bash
# build.sh - prepares the project
#
# Checks the dependencies, creates the output dirs and compiles the native
# sender with CMake into build/monitor_sender. Everything is logged in
# artifacts/build.log.

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

# Windows (Git Bash): use the cmake shipped with Visual Studio and the pkg-config
# shipped with GStreamer. On Linux/Codespaces everything is already in PATH.
CMAKE_EXTRA_ARGS=""
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        if ! command -v cmake >/dev/null 2>&1; then
            VSWHERE="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
            if [ -x "$VSWHERE" ]; then
                VS_PATH=$("$VSWHERE" -latest -products '*' -property installationPath | tr -d '\r')
                VS_CMAKE_DIR="$(cygpath -u "$VS_PATH")/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin"
                [ -x "$VS_CMAKE_DIR/cmake.exe" ] && export PATH="$VS_CMAKE_DIR:$PATH"
            fi
        fi
        GST_BIN_DIR="$(dirname "$(command -v gst-launch-1.0)")"
        GST_ROOT_DIR="$(cd "$GST_BIN_DIR/.." && pwd)"
        export PKG_CONFIG_PATH="$(cygpath -m "$GST_ROOT_DIR/lib/pkgconfig")"
        CMAKE_EXTRA_ARGS="-DPKG_CONFIG_EXECUTABLE=$(cygpath -m "$GST_BIN_DIR/pkg-config.exe")"
        ;;
esac

command -v cmake >/dev/null 2>&1 || fail "cmake not found"
step "configuring native sender (cmake)"
# shellcheck disable=SC2086
cmake -S . -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release $CMAKE_EXTRA_ARGS >> "$BUILD_LOG" 2>&1 \
    || fail "cmake configure failed, see $BUILD_LOG"
step "compiling native sender"
cmake --build "$BUILD_DIR" --config Release >> "$BUILD_LOG" 2>&1 || fail "compilation failed, see $BUILD_LOG"

MONITOR_SENDER="$BUILD_DIR/monitor_sender"
[ -x "$MONITOR_SENDER" ] || [ -x "$MONITOR_SENDER.exe" ] || fail "$MONITOR_SENDER was not produced"
step "built $MONITOR_SENDER"

echo "BUILD OK" >> "$BUILD_LOG"
log_info "build done (log: $BUILD_LOG)"
exit 0
