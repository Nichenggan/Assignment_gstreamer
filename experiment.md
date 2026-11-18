# Engineering experiment: H.264/RTP versus JPEG/RTP

## Question

For the network branch of our monitoring sender, what do we gain or lose by sending
the video as **JPEG over RTP** instead of **H.264 over RTP**, in network data rate and
in CPU usage of the sender?

## Hypothesis

* JPEG compresses every frame independently (intra only), H.264 also uses the
  similarity between frames, so JPEG should need **several times more bandwidth**.
* JPEG is a much simpler encoder, so we expected the sender to use **less CPU** with
  JPEG.

## The two configurations

Only `--codec` changes (`./build/monitor_sender ... --codec h264` vs `--codec jpeg`):

| | Config A: H.264/RTP | Config B: JPEG/RTP |
|---|---|---|
| network encoder | `x264enc speed-preset=ultrafast tune=zerolatency bitrate=1000 key-int-max=15` + `profile=baseline` | `jpegenc quality=80` |
| payloader | `rtph264pay pt=96 config-interval=1` | `rtpjpegpay pt=26` |

## Controlled variables

* same machine (Windows 11, 8 logical cores, GStreamer 1.28.8 MSVC), nothing else
  running during the measured series;
* same pipeline apart from the network encoder/payloader, with our assigned team-4
  configuration: `zone-plate` (`kx2=20 ky2=20 kt=1`, moving rings), 640x360, 15 fps,
  same overlays, same `videobalance` changes every 5 s, headless preview (`fakesink`);
* same recording branch (H.264 `ultrafast`, MPEG-TS): this branch costs the same in
  both configurations, its file size is measured to check it really stayed constant;
* same duration: **45 s** per run, stop by `--duration` (EOS), 2 repetitions per
  configuration, runs alternated (A, B, A, B) to spread any drift over both configs;
* same receiver side for the measurement: a raw UDP capture on port 5104.

## Measurement method

Everything is done by `scripts/run-experiment.sh` (results in `evidence/measurements.csv`,
logs in `artifacts/experiment/`):

* **Network data rate**: a separate `gst-launch-1.0 udpsrc port=5104 ! filesink
  buffer-mode=unbuffered` writes every received UDP payload (RTP header + data) to a
  file. `rate = file size x 8 / 45 s`. It counts what really arrives on the port,
  not what the encoder is configured to do. UDP/IP headers (28 B per packet) are not
  included.
* **CPU**: the CPU time (user + system) of the `monitor_sender` process is read 1 s
  before the end of the run (`Get-Process ... TotalProcessorTime` on Windows,
  `/proc/<pid>/stat` on Linux) and divided by the process elapsed time.
  The result is a percentage of **one** core (100 % = one core fully busy). It is the
  CPU of the whole sender (both encoders, overlays, preview, recording).
* **Recording size**: size of the `.ts` of each run (control value).
* **Warnings/errors**: number of `PIPELINE_WARNING` / `PIPELINE_ERROR` lines of the sender.
* **Validity**: a run only counts if the sender exited with 0 after `EOS_RECEIVED`, the
  CPU sample is a number, UDP data was captured and the recording is not empty.
  Otherwise the script exits with code 1 and does not update the CSV.

## Results

Raw data: `evidence/measurements.csv` (series of 18 November 2026, team-4 configuration).

| run | codec | CPU (% of one core) | network (kbit/s) | network bytes in 45 s | recording (bytes) | warnings / errors |
|---|---|---|---|---|---|---|
| run1 | h264 | 19.8 | 1012.6 | 5 695 840 | 12 026 924 | 0 / 0 |
| run2 | jpeg | 20.3 | 6821.1 | 38 368 789 | 12 067 532 | 0 / 0 |
| run3 | h264 | 20.9 | 1033.1 | 5 810 952 | 12 251 584 | 0 / 0 |
| run4 | jpeg | 19.3 | 6848.5 | 38 522 994 | 12 117 916 | 0 / 0 |

Averages:

| | H.264/RTP | JPEG/RTP | JPEG / H.264 |
|---|---|---|---|
| network data rate | **1023 kbit/s** | **6835 kbit/s** | **x 6.7** |
| data per frame (675 frames) | ~8.5 kB | ~57 kB | x 6.7 |
| sender CPU (% of one core) | 20.4 % | 19.8 % | -0.6 points |
| recording size | 12.14 MB | 12.09 MB | -0.4 % (control) |

* The H.264 rate (1023 kbit/s) is close to the configured `bitrate=1000`; the extra ~2 %
  is the RTP headers and the SPS/PPS sent every second.
* The recording size is the same in both configurations (difference 0.4 %), so the
  rest of the pipeline really did the same work.
* No warnings or errors in any run; all runs exited with code 0 after EOS.
* An earlier series with the example configuration of the assignment (`smpte`, 800x450,
  10 fps, Matroska) gave 1022 vs 3705 kbit/s (x 3.6) and 26.8 vs 24.4 % CPU. The ratio is
  much higher with the moving, very detailed zone plate (see limitations).

## Limitations

* **CPU difference is within the noise.** The two H.264 runs differ by 1.1 points
  (19.8 vs 20.9), more than the H.264/JPEG difference (0.6 points). We cannot say that
  one is cheaper; the CPU is dominated by parts common to both configurations
  (recording encoder, overlays, conversions, startup of ~1-2 s included in the
  measurement).
* **Quality not measured, and not equal.** H.264 is limited to 1000 kbit/s while JPEG
  uses a fixed quality (80). The zone plate is full of fine moving details, which is
  very hard for H.264 at 1000 kbit/s, so the H.264 image is probably worse than the JPEG
  one. We did not compute PSNR/SSIM and did not compare the received images: the 6.7x
  ratio compares a bitrate-limited stream with a quality-limited one.
* **Test pattern.** The zone plate is not a camera image: it changes everywhere in every
  frame (worst case for H.264) but has no noise. With the almost static `smpte` pattern
  the ratio was 3.6x. A real monitoring camera (mostly static background) is probably
  closer to the second case.
* **Latency and packet loss not measured.** Everything is on localhost (no loss, no
  bandwidth limit); the results say nothing about behaviour on a real network.
* Only 2 x 2 runs of 45 s, one machine, Windows only (not reproduced in Codespaces).
* The data rate is averaged over 45 s including the start of the pipeline, so the
  steady-state rate is slightly higher (< 3 %).

## Engineering conclusion

For a video monitoring system that streams several cameras over a shared network,
**H.264/RTP is the better default**: with our assigned configuration it needs about
**6.7x less bandwidth** than JPEG (≈1.0 vs ≈6.8 Mbit/s per stream, and still 3.6x with a
static pattern) for **no measurable extra CPU** on the sender. With a 100 Mbit/s link,
this is roughly 90 H.264 streams against 14 JPEG streams.

The price of H.264 is not CPU but:

* **image quality at a fixed bitrate**: on scenes with a lot of motion and detail (our
  zone plate), 1000 kbit/s may not be enough; the bitrate must be chosen for the scene,
  or a quality-based rate control used;
* **error recovery**: every JPEG frame is independent, a lost packet damages one frame
  only, whereas with H.264 an error can last until the next keyframe (up to 1 s with our
  `key-int-max=15` at 15 fps);
* **interoperability / complexity**: JPEG over RTP has a static payload type (26), needs
  no SPS/PPS and any frame can be decoded alone, which makes the receiver and the
  "join late" case simpler.

JPEG/RTP is therefore worth considering only when the network has plenty of capacity
and robustness to packet loss or a very simple receiver matters more than bandwidth.
For our assigned configuration (640x360, 15 fps) we keep H.264 for the network branch,
with a short GOP (1 s), `config-interval=1` and the receiver jitter buffer to limit its
error sensitivity.

## Reproduce

```bash
./scripts/clean.sh
./scripts/build.sh
./scripts/run-experiment.sh                 # 2 x 2 runs of 45 s, ~4 min
./scripts/run-experiment.sh --repeats 3     # more repetitions
```

The script prints the table, exits with code 1 if any run is invalid, and only then
rewrites `evidence/measurements.csv`.
