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
- [ ] Part 3 - native `monitor_sender`
- [ ] Part 4 - debug report
- [ ] Part 5 - experiment
- [ ] Part 6 - full automated verification (current `verify.sh` tests the shell sender)

## Assigned configuration

See `config/team.conf`: pattern `smpte`, 800x450, 10 fps, UDP port 5123,
overlay top-center, Matroska recording, H.264 network codec, runtime 60 s.

## Dependencies

GStreamer 1.x with base, good, bad, ugly and libav plugins (`x264enc` and
`avdec_h264` are needed), `gst-discoverer-1.0`, bash and coreutils (`timeout`).
Graphviz (`dot`) is only needed to regenerate `evidence/pipeline.png`.

- Codespaces / Ubuntu: `gstreamer1.0-tools gstreamer1.0-plugins-{base,good,bad,ugly} gstreamer1.0-libav`
- Windows (what we also used for development): official MSVC installer
  (`winget install gstreamerproject.gstreamer`), scripts run in Git Bash.
  The scripts find `gst-launch-1.0` automatically in the default install folders.

## Usage

All scripts are launched from the repository root.

| What | Command |
|---|---|
| sender with preview window (60 s) | `./scripts/sender.sh` |
| sender until Ctrl+C | `./scripts/sender.sh --duration 0` |
| sender without window | `./scripts/sender.sh --headless --duration 15` |
| network receiver with window | `./scripts/receiver.sh` |
| network receiver, test mode | `./scripts/receiver.sh --test` |
| play the recording | `./scripts/play-recording.sh` (or give a file path) |
| regenerate the pipeline graph | `./scripts/make-graph.sh` (needs Graphviz) |

Start the receiver first, then the sender in another terminal. The sender
records to `artifacts/recording.mkv` by default (`--output` to change it).

## Generated files

Everything generated goes to `artifacts/` (logs, recordings) and `build/`.
`./scripts/clean.sh` removes both.

## Timings (measured on our laptop)

- build: a few seconds (only checks for now)
- verification: about 40 s

## Known limitations

- Ctrl+C on the sender relies on `gst-launch-1.0 -e`. In some Windows terminals
  (mintty) Ctrl+C is not forwarded to native programs; use `--duration` there.
- A truncated Matroska file can still be partly decoded, so `verify.sh` also checks
  the duration reported by `gst-discoverer-1.0`, not only that it decodes.
