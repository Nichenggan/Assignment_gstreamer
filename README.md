# GStreamer video monitoring system

## Quick evaluation

```bash
git clone <repository>
cd <repository>
./scripts/clean.sh
./scripts/build.sh
./scripts/verify.sh
```

`verify.sh` prints a PASS/FAIL summary and writes it to `artifacts/verification-summary.txt`.

## Team

- Nikola MILOSAVLJEVIC
- Chenyi LI
- Amirhossein POUYANFAR

## Status

- [x] Part 1 - pipelines with `gst-launch-1.0` (sender, receiver, playback scripts)
- [x] Part 2 - architecture documentation (`architecture.md`, graph in `evidence/pipeline.png`)
- [x] Part 3 - native `monitor_sender` (`src/monitor_sender.c`, built with CMake)
- [x] Part 4 - debug report (`debug-report.md`)
- [x] Part 5 - experiment H.264/RTP vs JPEG/RTP (`experiment.md`, `evidence/measurements.csv`)
- [x] Part 6 - automated verification (`scripts/verify.sh`)

Other documents: `debug-report.md`, `CONTRIBUTIONS.md`, `AI_USAGE.md`.

## Assigned configuration

See `config/team.conf`: pattern `smpte`, 800x450, 10 fps, UDP port 5123,
overlay top-center, Matroska recording, H.264 network codec, runtime 60 s.

## Dependencies

GStreamer 1.x with base, good, bad, ugly and libav plugins (`x264enc` and
`avdec_h264` are needed), `gst-discoverer-1.0`, bash and coreutils (`timeout`).
Graphviz (`dot`) is only needed to regenerate `evidence/pipeline.png`.

To build `monitor_sender`: a C compiler, CMake >= 3.16, pkg-config and the
GStreamer development files.

- Codespaces / Ubuntu: `gstreamer1.0-tools gstreamer1.0-plugins-{base,good,bad,ugly} gstreamer1.0-libav
  libgstreamer1.0-dev build-essential cmake pkg-config`
- Windows (what we also used for development): official MSVC installer
  (`winget install gstreamerproject.gstreamer`, includes headers and `pkg-config.exe`)
  and Visual Studio 2022 with the C++ workload; scripts run in Git Bash.
  The scripts find `gst-launch-1.0`, the CMake of Visual Studio and the GStreamer
  `pkg-config` automatically. The executable is then `build/monitor_sender.exe`.

## Usage

All scripts are launched from the repository root.

| What | Command |
|---|---|
| native sender with preview window (60 s) | `./build/monitor_sender --pattern smpte --width 800 --height 450 --fps 10 --port 5123 --output artifacts/recording.mkv --duration 60` |
| native sender, headless | same + `--headless` |
| native sender options | `./build/monitor_sender --help` |
| shell sender (part 1) with preview window (60 s) | `./scripts/sender.sh` |
| sender until Ctrl+C | `./scripts/sender.sh --duration 0` |
| sender without window | `./scripts/sender.sh --headless --duration 15` |
| network receiver with window | `./scripts/receiver.sh` |
| network receiver, test mode | `./scripts/receiver.sh --test` |
| play the recording | `./scripts/play-recording.sh` (or give a file path) |
| play the sample recording of the repository | `./scripts/play-recording.sh recordings/sample.mkv` |
| regenerate the pipeline graph | `./scripts/make-graph.sh` (needs Graphviz) |
| run the experiment (part 5, ~4 min) | `./scripts/run-experiment.sh` (after `build.sh`) |

Start the receiver first, then the sender in another terminal. `sender.sh`
records to `artifacts/recording.mkv` by default (`--output` to change it).

## Native sender (`monitor_sender`)

Required options: `--pattern`, `--width`, `--height`, `--fps`, `--port`, `--output`.
Optional: `--duration SECONDS` (send EOS and exit 0 after this time, 0 = until Ctrl+C),
`--headless`, `--codec h264|jpeg`, `--overlay-position`, `--names`, `--host`, `--bitrate`.
The container comes from the extension of `--output` (`.mkv` Matroska, `.ts` MPEG-TS).
Bad arguments print an error and return exit code 2, runtime errors return 1.

### Dynamic property

| Element (name in the pipeline) | Property | Values |
|---|---|---|
| `videobalance` (`video_balance`) | `brightness` | 0.20 -> 0.00 -> -0.20 -> 0.00 -> ... every 5 s |

The change is done with `g_object_set()` on the running pipeline (the pipeline is not
rebuilt). Every change is logged, in headless mode too, for example:

```
DYNAMIC_PROPERTY element=video_balance property=brightness value=0.20
```

`videobalance` is placed before the overlays, so only the test pattern changes
brightness, the text stays readable.

### Messages printed by monitor_sender

`CONFIG ...`, `PIPELINE_STATE old -> new`, `DYNAMIC_PROPERTY ...`,
`STOP_REQUESTED reason=duration|interrupt`, `EOS_RECEIVED`, `PIPELINE_ERROR element=<name> message=...`
followed by the GStreamer debug information, and `EXIT code=N`. `verify.sh` uses these lines.

## Generated files

Everything generated goes to `artifacts/` (logs, recordings) and `build/`.
`./scripts/clean.sh` removes both.

After `./scripts/verify.sh`:

```
artifacts/
├── build.log                  output of build.sh
├── sender.log                 output of build/monitor_sender --headless
├── receiver.log               receiver in test mode (one "chain" line per decoded frame)
├── verification.log           every check done by verify.sh, with timestamps
├── verification-summary.txt   PASS/FAIL per test + OVERALL
└── test-recording.mkv         recording made during the test
```

## Timings (measured on our laptop)

- build: about 30 s on Windows/MSVC (CMake configure + compile), less on Linux
- verification: about 40 s (`verify.sh`), experiment: about 4 min (`run-experiment.sh`)

## Known limitations

- Ctrl+C on `sender.sh` relies on `gst-launch-1.0 -e`, on `monitor_sender` on a SIGINT
  handler that sends EOS. In some Windows terminals (mintty) Ctrl+C is not forwarded to
  native programs; use `--duration` there. We only tested the `--duration` path
  automatically, the Ctrl+C path of `monitor_sender` was not tested on Windows.
- `--duration` counts from the start of the program, so the recording is a few hundred
  ms shorter or longer than the requested duration.
- A truncated Matroska file can still be partly decoded, so `verify.sh` also checks
  the duration reported by `gst-discoverer-1.0`, not only that it decodes.
