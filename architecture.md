# Architecture

This document describes the sender and receiver pipelines. The same sender pipeline
exists twice: `scripts/sender.sh` (part 1, `gst-launch-1.0`) and `build/monitor_sender`
(part 3, C, section 10). The only difference is the `videobalance` element
(`video_balance`) that the native sender adds after `source_convert` for the dynamic
property. `verify.sh` tests the native sender.

Team configuration used below (team 4, from `config/team.conf`): `zone-plate`, 640x360,
15 fps, UDP port 5104, overlay top-center, MPEG-TS recording, H.264 over RTP, runtime 60 s.
All values are read from `config/team.conf`; the scripts also support the other values
of the assignment (Matroska, JPEG, other patterns and positions).

## 1. Sender diagram

```
videotestsrc (video_source)  pattern=zone-plate kx2=20 ky2=20 kt=1 is-live=true
      |  video/x-raw,width=640,height=360,framerate=15/1
videoconvert (source_convert)
      |
textoverlay (names_overlay)   "Nikola MILOSAVLJEVIC, Chenyi LI, Amirhossein POUYANFAR"  (top-center)
      |
timeoverlay (time_overlay)    "640x360 @ 15 fps | elapsed 0:00:06.011"                  (bottom-left)
      |
videoconvert ! video/x-raw,format=I420,width=640,height=360,framerate=15/1
      |
     tee (split)
      |
      +--------------------------+------------------------------------+
      |                          |                                    |
 A: PREVIEW                 B: RECORDING                         C: RTP/UDP
 queue (preview_queue)      queue (record_queue)                 queue (network_queue)
  leaky, 5 buffers           3 s, not leaky                       leaky, 10 buffers
      |                          |                                    |
 videoconvert               x264enc (record_encoder)             x264enc (network_encoder)
      |                      ultrafast, keyframe every 2 s        zerolatency, 1000 kbit/s,
 autovideosink                   |                                keyframe every 1 s
 (fakesink if --headless)   h264parse (record_parser)                 |  video/x-h264,profile=baseline
                                 |                               rtph264pay (network_payloader)
                            mpegtsmux (record_muxer)              pt=96, config-interval=1
                                 |                                    |
                            filesink (record_sink)               udpsink (network_sink)
                            artifacts/recording.ts                127.0.0.1:5104
```

Same structure as a Mermaid diagram (rendered by GitHub):

```mermaid
flowchart LR
    SRC["videotestsrc<br/>video_source<br/>zone-plate, is-live"] --> CAPS1["capsfilter<br/>640x360 @ 15/1"]
    CAPS1 --> CONV["videoconvert<br/>source_convert"]
    CONV --> NAMES["textoverlay<br/>names_overlay<br/>(top-center)"]
    NAMES --> TIME["timeoverlay<br/>time_overlay<br/>res/fps + elapsed"]
    TIME --> CAPS2["videoconvert + capsfilter<br/>I420 640x360 15/1"]
    CAPS2 --> TEE{{"tee<br/>split"}}

    subgraph A["Branch A - preview"]
        QA["queue preview_queue<br/>leaky, 5 buf"] --> VCA["videoconvert"] --> SA["autovideosink<br/>(fakesink if --headless)"]
    end
    subgraph B["Branch B - recording"]
        QB["queue record_queue<br/>3 s, not leaky"] --> EB["x264enc<br/>record_encoder"] --> PB["h264parse<br/>record_parser"] --> MB["mpegtsmux<br/>record_muxer"] --> FB["filesink<br/>recording.ts"]
    end
    subgraph C["Branch C - RTP/UDP"]
        QC["queue network_queue<br/>leaky, 10 buf"] --> EC["x264enc<br/>network_encoder<br/>1000 kbit/s"] --> CC["capsfilter<br/>profile=baseline"] --> PC["rtph264pay<br/>pt=96"] --> UC["udpsink<br/>127.0.0.1:5104"]
    end

    TEE --> QA
    TEE --> QB
    TEE --> QC
```

### Pipeline graph from the real pipeline

![sender pipeline graph](evidence/pipeline.png)

`evidence/pipeline.png` is generated from the running sender, not drawn by hand:

```bash
./scripts/make-graph.sh
```

The script runs `scripts/sender.sh --headless --duration 4` with
`GST_DEBUG_DUMP_DOT_DIR` set, keeps the `*PAUSED_PLAYING.dot` file (at this point all
caps are negotiated, so the graph shows the real caps on every link) and converts it
with `dot -Tpng`. The raw `.dot` is kept next to it in `evidence/pipeline.dot`.

What we checked on the graph:
* `split` has three source pads `src_0`, `src_1`, `src_2`, each followed by its own queue;
* the link before the tee carries `video/x-raw, format=I420, width=640, height=360, framerate=15/1`;
* `video_source` has `pattern=zone-plate` with `kx2=20 ky2=20 kt=1` (see section 2);
* in the recording branch the H.264 caps are `stream-format=byte-stream` from
  `record_encoder` to `record_muxer`, because `mpegtsmux` only accepts Annex-B
  byte-stream; in the network branch they are `stream-format=avc` because `rtph264pay`
  prefers it. The same `x264enc` produces a different format in each branch: caps
  negotiation propagates what the downstream element wants up to the encoder (section 5);
* after `network_payloader` the caps are `application/x-rtp, media=video, clock-rate=90000,
  encoding-name=H264, payload=96, packetization-mode=1` - these are the caps the receiver
  has to recreate by hand (section 7).

Receiver (`scripts/receiver.sh`):

```
udpsrc port=5104 caps="application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96"
  ! rtpjitterbuffer latency=200
  ! rtph264depay ! h264parse ! avdec_h264
  ! videoconvert ! autovideosink                          (display mode)
  ! identity eos-after=N ! fakesink silent=false          (test mode)
```

## 2. Main elements

| Element | Name in pipeline | Purpose |
|---|---|---|
| `videotestsrc` | `video_source` | live test pattern (no camera needed). `is-live=true` makes it produce frames at the real frame rate. `num-buffers` (shell sender) stops it after the requested duration. For `zone-plate` we set `kx2=20 ky2=20 kt=1`: with the default coefficients (all 0) the zone plate is a uniform grey picture; `kt=1` makes the rings move over time. |
| capsfilter | - | forces the assigned resolution and frame rate |
| `textoverlay` | `names_overlay` | team member names at the assigned position |
| `timeoverlay` | `time_overlay` | running time + configured resolution/fps |
| `tee` | `split` | duplicates every buffer into the 3 branches |
| `queue` | `*_queue` | one per branch, see section 6 |
| `autovideosink` / `fakesink` | `preview_sink` | local window / no display in headless mode |
| `x264enc` | `record_encoder`, `network_encoder` | raw video -> H.264 |
| `h264parse` | `record_parser` | H.264 parser (see below) |
| `matroskamux` / `mpegtsmux` | `record_muxer` | puts the H.264 stream in a container |
| `filesink` | `record_sink` | writes the file |
| `rtph264pay` / `rtpjpegpay` | `network_payloader` | cuts the encoded stream into RTP packets |
| `udpsink` | `network_sink` | sends the packets to 127.0.0.1:PORT |

## 3. Raw video caps before the tee

```
video/x-raw, format=I420, width=640, height=360, framerate=15/1
```

We fix `I420` before the tee so the format is known and the same for all branches
(without it, the format is whatever `videotestsrc`/overlays negotiate first). I420 is
accepted directly by `x264enc` and `jpegenc`, so the encoding branches do not need their
own conversion.

### Transmission and recording parameters

| | Network (branch C) | Recording (branch B) |
|---|---|---|
| Codec | H.264 (`x264enc`, `tune=zerolatency`, `speed-preset=ultrafast`, constrained-baseline, 1000 kbit/s, keyframe every 15 frames = 1 s) | H.264 (`x264enc`, `speed-preset=ultrafast`, keyframe every 30 frames = 2 s) |
| Packaging | RTP, `rtph264pay`, dynamic payload type **96**, clock-rate 90000, packetization-mode 1, SPS/PPS re-sent every 1 s | container **MPEG-TS** (`mpegtsmux`), file `.ts` |
| Destination | UDP `127.0.0.1`, port **5104** (`udpsink`) | `artifacts/recording.ts` (or `--output`), `artifacts/test-recording.ts` in `verify.sh`, `recordings/sample.ts` in the repository |

All these values come from `config/team.conf`; with `NETWORK_CODEC=jpeg` the network
branch becomes `jpegenc ! rtpjpegpay` (static payload type 26), with `CONTAINER=matroska`
the recording uses `matroskamux` and `.mkv`.

Why two separate encoders instead of one encoder before the tee: the two uses have
different needs (network: low latency, constant bitrate, short GOP for fast recovery;
recording: quality per byte, longer GOP). The cost is encoding twice; at 640x360 / 15 fps
with `ultrafast` this is cheap.

## 4. Raw video vs compressed video

* **Raw** (`video/x-raw`): from `videotestsrc` to the tee, the whole preview branch,
  and the input of the two encoders. On the receiver: after `avdec_h264`.
* **Compressed** (`video/x-h264` or `image/jpeg`): after `x264enc`/`jpegenc` in branches B and C,
  inside the `.ts` (or `.mkv`) file, and inside the RTP packets (`application/x-rtp`).
  On the receiver: from `udpsrc` to the input of the decoder.

A 640x360 I420 frame is 345.6 kB, so 5.2 MB/s (41 Mbit/s) at 15 fps; the H.264 network
stream is about 1 Mbit/s. That is why we only send compressed video on the network.

## 5. Encoder, payloader, depayloader, caps, parser, muxer

**Encoder vs RTP payloader.** The encoder (`x264enc`) compresses the pictures: it turns
raw frames into an H.264 bitstream (NAL units). The payloader (`rtph264pay`) does not
compress anything; it splits this bitstream into packets small enough for UDP
(MTU ~1400 bytes, fragmentation FU-A for big NAL units) and adds the RTP header
(payload type 96, sequence number, 90 kHz timestamp, marker bit at the end of a frame).
`config-interval=1` re-sends SPS/PPS every second so a receiver started late can decode.

**Why the receiver needs a depayloader.** The decoder expects a H.264 stream, not RTP
packets. `rtph264depay` removes the RTP headers, puts the fragments back together into
complete NAL units / access units, and uses the RTP timestamps for the buffer
timestamps. Before it, `rtpjitterbuffer` re-orders packets and removes network jitter.

**Why the receiver needs explicit caps.** UDP carries only bytes: `udpsrc` cannot know
that the datagrams contain RTP, which codec, which clock rate or payload type. Without
`caps="application/x-rtp,...,encoding-name=H264,payload=96"` the depayloader can not
negotiate and the pipeline fails with a `not-negotiated` error. (With RTSP/SDP this
information would come from the signalling, here there is none.)

**Parser (`h264parse`).** A parser reads the H.264 bitstream and describes it in the
caps (profile, level, resolution, `parsed=true`), checks that buffers are complete
access units and flags keyframes. It can also convert between the two H.264 formats:
`byte-stream` (Annex-B, start codes, needed by `mpegtsmux`) and `avc` (length-prefixed
NAL units + `codec_data`, needed by `matroskamux`). The pipeline graph shows that with our
configuration `x264enc` already outputs `byte-stream` for `mpegtsmux` (and `avc` when we
used Matroska), so the parser does not convert anything here; it is kept because it
guarantees the muxer gets parsed, correctly flagged access units whatever the encoder
and container (with an encoder that only outputs one format, `h264parse` does the
conversion). On the receiver and
playback side, `h264parse` sits between the depayloader/demuxer and `avdec_h264` so the
decoder gets complete access units with full caps.

**Recording muxer (`mpegtsmux`).** The muxer stores the H.264 stream with its
timestamps in a container. MPEG-TS cuts it into 188-byte packets, puts each frame in a
PES packet with its PTS/DTS, and repeats the program tables (PAT/PMT) that describe the
stream, so a player can start reading anywhere in the file. Without a container a raw
`.h264` file has no timing information. MPEG-TS has no global header or index (it was
made for broadcast), so a truncated file stays readable, but a player must scan the
file to know its duration. With `CONTAINER=matroska` the scripts use `matroskamux`
(`.mkv`), which writes a header, clusters and, at EOS, the duration and the seek index.

## 6. Queues

`tee` pushes the same buffer into its source pads one after the other **in the
same thread**. Without queues, a slow branch (e.g. the window waiting for vsync,
or x264 encoding a keyframe) would block the tee and so every other branch.
A `queue` after each tee pad starts a new streaming thread, so each branch runs
independently. With a live source a missing queue can also make the pipeline
stuck in PAUSED (the preroll of one sink waits for data that the other branch blocks).

* `preview_queue` - `leaky=downstream`, 5 buffers: if the display is late we
  drop old frames instead of slowing down the recording and the network. For a
  monitoring preview showing the latest frame is more important than showing all.
* `record_queue` - not leaky, up to 3 s: the recording must not lose frames,
  the 3 s buffer absorbs x264 peaks (keyframes).
* `network_queue` - `leaky=downstream`, 10 buffers: for live transmission a late
  frame is useless, better to drop it than to accumulate latency.

## 7. How the receiver reconstructs the stream

1. `udpsrc` receives the datagrams on port 5104 and tags them with the RTP caps.
2. `rtpjitterbuffer` orders them using the sequence numbers and waits up to 200 ms
   for late packets.
3. `rtph264depay` reassembles the FU-A fragments into NAL units / access units.
4. `h264parse` + `avdec_h264` decode to `video/x-raw` (I420, 640x360, 15/1).
5. The raw frames go to a window (display mode) or to `fakesink` (test mode).

## 8. Finalizing the recording

The recording is only complete when the muxer receives **EOS**: `mpegtsmux` then
pushes the frames and TS packets it still holds and `filesink` flushes its buffer and
closes the file. (`matroskamux` also rewrites the duration and writes the seek index at
EOS; a Matroska file killed without EOS has an unfinished header, see `debug-report.md`.)

* `monitor_sender --duration N` (used by `verify.sh`): a GLib timer fires after N s and
  the application calls `gst_element_send_event(pipeline, gst_event_new_eos())`. The
  pipeline forwards the EOS to the source, which pushes it downstream through the tee
  and the 3 branches. When every sink has it, the bus gets `GST_MESSAGE_EOS`, the
  application quits the main loop, sets the pipeline to NULL and returns 0. If the EOS
  does not come back within 10 s the program stops anyway and returns 1 (so a stuck
  pipeline is reported as an error, not hidden).
* `scripts/sender.sh --duration N`: `videotestsrc` has `num-buffers=N*FPS`.
  After the last frame it sends EOS itself. The EOS goes through the tee into the
  three branches, the muxer finalizes the file, `filesink` closes it, and when all
  sinks got EOS the pipeline posts EOS on the bus, `gst-launch-1.0` prints
  `Got EOS from element "pipeline0"` and exits with 0. No kill at all.
* Without a duration (`--duration 0`), the sender runs until Ctrl+C. `sender.sh` uses
  `gst-launch-1.0 -e`, which turns the interrupt into an EOS event; `monitor_sender`
  has a SIGINT handler that sets a flag, and a 100 ms GLib timer sends the EOS from the
  main loop (GStreamer functions must not be called inside a signal handler). A second
  Ctrl+C quits without waiting.
* We never use `kill -9` to stop a recording: the muxer would not get EOS, the end of
  the recording would be lost (and a Matroska file would have no duration/index).

## 9. Normal mode vs test mode

| | normal (display) mode | test (headless) mode |
|---|---|---|
| sender preview | `autovideosink` window | `fakesink sync=true` |
| sender recording / network | same | same |
| receiver | `videoconvert ! autovideosink` | `identity eos-after=N ! fakesink silent=false` |
| receiver end | Ctrl+C | stops by itself after N decoded frames (exit 0), or `timeout` -> exit 1 |
| proof of reception | look at the window | exit code + one `chain` line per decoded frame in `receiver.log` |

In test mode only the sinks change, the encode/payload/depayload/decode path is
exactly the same as in normal mode, so the test really checks the network chain.

## 10. Native sender (`monitor_sender`)

### Option B: parsed pipeline

We chose **option B**: the program builds the same textual description as
`sender.sh` (with the values of the command line) and calls `gst_parse_launch()`.
The elements that must be controlled at runtime have a name and are fetched with
`gst_bin_get_by_name()` (`video_balance` for the brightness).

* Advantage: the pipeline in C is exactly the one we tested and debugged with
  `gst-launch-1.0` in part 1 (copy/paste of the same string), caps filters and
  request pads of the `tee` (`split. ! queue ...`) are handled by the parser, so the
  code is short and the pipeline is easy to read and compare with `architecture.md`.
* Limitation: errors are found only at runtime and as text (`no element "x264enc"`,
  `no property "foo"`), not at compile time; values put in the string must be checked
  and quoted by us (we reject `"` in `--names`/`--output`), and changing the structure
  dynamically (e.g. adding a branch while running) is not possible without manual
  `gst_element_factory_make()`/`gst_element_link()` code. We also check
  `error != NULL` after `gst_parse_launch()` because it can return a pipeline *and*
  an error (for example an unknown property).

### Runtime behaviour

```
parse options (GOptionContext, also --help and the GStreamer options)
  -> validate (missing / out of range / unknown pattern / unknown extension -> exit 2)
gst_init
gst_parse_launch(description)              -> error: print it, exit 1
gst_bin_get_by_name("video_balance")
bus watch (gst_bus_add_watch)              -> on_bus_message()
timers: every 5 s brightness, after N s EOS, every 100 ms Ctrl+C flag
gst_element_set_state(PLAYING)             -> failure: print the bus error, exit 1
g_main_loop_run
   ERROR   -> "PIPELINE_ERROR element=<src name> message=..." + debug info, quit
   WARNING -> printed, continue
   STATE_CHANGED (pipeline only) -> "PIPELINE_STATE A -> B" (+ DOT dump at PLAYING)
   EOS     -> "EOS_RECEIVED", quit
cleanup: remove timers and bus watch, set_state(NULL), unref elements, pipeline,
         main loop, free options, gst_deinit, "EXIT code=N"
```

Exit code: 0 only if the EOS was received and no error happened, 1 for runtime errors,
2 for command-line errors. stdout is unbuffered so the log is complete even if the
process is killed by the `timeout` of `verify.sh`.

Example of the error report (output directory that does not exist):

```
PIPELINE_ERROR element=record_sink message=Could not open file "no_such_dir/x.ts" for writing.
Debug information: ../plugins/elements/gstfilesink.c(510): gst_file_sink_open_file (): /GstPipeline:pipeline0/GstFileSink:record_sink:
system error: No such file or directory
EXIT code=1
```
