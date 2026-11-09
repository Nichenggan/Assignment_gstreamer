#!/usr/bin/env bash
# make-graph.sh - dumps the DOT graph of the real sender pipeline and converts it to PNG
#
# Usage: ./scripts/make-graph.sh [OUTPUT_PNG]     (default: evidence/pipeline.png)
#
# Runs scripts/sender.sh headless for a few seconds with GST_DEBUG_DUMP_DOT_DIR set.
# gst-launch-1.0 writes one .dot file per state change; we keep PAUSED_PLAYING
# because at that moment all caps are negotiated. Needs Graphviz (dot).

. "$(dirname "$0")/common.sh"

OUTPUT_PNG="${1:-evidence/pipeline.png}"
DOT_DIR="$ARTIFACTS_DIR/dot"
GRAPH_DURATION=4

case "$OUTPUT_PNG" in
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

find_dot() {
    command -v dot >/dev/null 2>&1 && return 0
    local candidate
    for candidate in "/c/Program Files/Graphviz/bin" "/c/Program Files (x86)/Graphviz/bin"; do
        if [ -x "$candidate/dot.exe" ]; then
            export PATH="$candidate:$PATH"
            return 0
        fi
    done
    log_error "Graphviz 'dot' not found (apt install graphviz / winget install Graphviz.Graphviz)"
    return 1
}
load_config || exit 1
find_dot || exit 1

rm -rf "$DOT_DIR"
mkdir -p "$DOT_DIR" "$(dirname "$OUTPUT_PNG")" || exit 1

log_info "running the sender for ${GRAPH_DURATION}s with GST_DEBUG_DUMP_DOT_DIR=$DOT_DIR"
# absolute path: gst-launch is a native program and the dir must not depend on its cwd
GST_DEBUG_DUMP_DOT_DIR="$(cd "$DOT_DIR" && pwd)" \
    timeout 60s bash scripts/sender.sh --headless --duration "$GRAPH_DURATION" \
    --output "$ARTIFACTS_DIR/graph-recording.$RECORDING_EXT" > "$ARTIFACTS_DIR/graph-sender.log" 2>&1 \
    || { log_error "sender failed, see $ARTIFACTS_DIR/graph-sender.log"; exit 1; }

DOT_FILE=$(ls "$DOT_DIR"/*PAUSED_PLAYING.dot 2>/dev/null | head -1)
if [ -z "$DOT_FILE" ]; then
    log_error "no PAUSED_PLAYING .dot file was written in $DOT_DIR"
    exit 1
fi

log_info "converting $(basename "$DOT_FILE") -> $OUTPUT_PNG"
dot -Tpng "$DOT_FILE" -o "$OUTPUT_PNG" || { log_error "dot conversion failed"; exit 1; }
cp "$DOT_FILE" "${OUTPUT_PNG%.png}.dot"
log_info "done: $OUTPUT_PNG (and ${OUTPUT_PNG%.png}.dot)"
exit 0
