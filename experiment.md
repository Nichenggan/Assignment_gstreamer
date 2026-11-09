# Engineering experiment: H.264/RTP versus JPEG/RTP

## Question

For the network branch of our monitoring sender, what do we gain or lose by sending
the video as **JPEG over RTP** instead of **H.264 over RTP**, in network data rate and
in CPU usage of the sender?

## Hypothesis

* JPEG compresses every frame independently (intra only), H.264 also uses the
  similarity between frames, so JPEG should need **several times more bandwidth**
  (we expected 3x to 5x for a mostly static test pattern).
* JPEG is a much simpler encoder, so we expected the sender to use **less CPU** with
  JPEG.

## The two configurations

Only `--codec` changes (`./build/monitor_sender ... --codec h264` vs `--codec jpeg`):

| | Config A: H.264/RTP | Config B: JPEG/RTP |
|---|---|---|
| network encoder | `x264enc speed-preset=ultrafast tune=zerolatency bitrate=1000 key-int-max=10` + `profile=baseline` | `jpegenc quality=80` |
| payloader | `rtph264pay pt=96 config-interval=1` | `rtpjpegpay pt=26` |

## Controlled variables

* same machine (Windows 11, 8 logical cores, GStreamer 1.28.8 MSVC), nothing else
  running during the measured series;
* same pipeline apart from the network encoder/payloader: `smpte`, 800x450, 10 fps,
  same overlays, same `videobalance` changes every 5 s, headless preview (`fakesink`);
* same recording branch (H.264 `ultrafast`, Matroska): this branch costs the same in
  both configurations, its file size is measured to check it really stayed constant;
* same duration: **45 s** per run, stop by `--duration` (EOS), 2 repetitions per
  configuration, runs alternated (A, B, A, B) to spread any drift over both configs;
* same receiver side for the measurement: a raw UDP capture on port 5123.

## Measurement method

Everything is done by `scripts/run-experiment.sh` (results in `evidence/measurements.csv`,
logs in `artifacts/experiment/`):

* **Network data rate**: a separate `gst-launch-1.0 udpsrc port=5123 ! filesink
  buffer-mode=unbuffered` writes every received UDP payload (RTP header + data) to a
  file. `rate = file size x 8 / 45 s`. It counts what really arrives on the port,
  not what the encoder is configured to do. UDP/IP headers (28 B per packet) are not
  included.
* **CPU**: the CPU time (user + system) of the `monitor_sender` process is read 1 s
  before the end of the run (`Get-Process ... TotalProcessorTime` on Windows,
  `/proc/<pid>/stat` on Linux) and divided by the process elapsed time.
  The result is a percentage of **one** core (100 % = one core fully busy). It is the
  CPU of the whole sender (both encoders, overlays, preview, recording).
* **Recording size**: size of the `.mkv` of each run (control value).
* **Warnings/errors**: number of `PIPELINE_WARNING` / `PIPELINE_ERROR` lines of the sender.

## Results

Raw data: `evidence/measurements.csv`.

| run | codec | CPU (% of one core) | network (kbit/s) | network bytes in 45 s | recording (bytes) | warnings / errors |
|---|---|---|---|---|---|---|
| run1 | h264 | 28.1 | 1026.5 | 5 774 014 | 11 636 652 | 0 / 0 |
| run2 | jpeg | 24.9 | 3700.8 | 20 817 168 | 11 652 443 | 0 / 0 |
| run3 | h264 | 25.4 | 1018.1 | 5 726 609 | 11 566 350 | 0 / 0 |
| run4 | jpeg | 23.8 | 3709.0 | 20 863 377 | 11 678 032 | 0 / 0 |

Averages:

| | H.264/RTP | JPEG/RTP | JPEG / H.264 |
|---|---|---|---|
| network data rate | **1022 kbit/s** | **3705 kbit/s** | **x 3.6** |
| data per frame (450 frames) | ~12.8 kB | ~46.3 kB | x 3.6 |
| sender CPU (% of one core) | 26.8 % | 24.4 % | -2.4 points |
| recording size | 11.60 MB | 11.67 MB | +0.6 % (control) |

* The H.264 rate (1022 kbit/s) is close to the configured `bitrate=1000`, the extra ~2 %
  is the RTP headers and the SPS/PPS sent every second.
* The recording size is the same in both configurations (difference 0.6 %), so the
  rest of the pipeline really did the same work.
* No warnings or errors in any run; all runs exited with code 0 after EOS.
* A first series run under slightly different conditions (another sender was running
  for 20 s during one JPEG run) gave 1034/1023 kbit/s (H.264), 3726/3706 kbit/s (JPEG) and
  CPU 22.9-26.8 %, i.e. the same conclusion. We kept only the clean series in the CSV.

## Limitations

* **CPU difference is within the noise.** The two H.264 runs differ by 2.7 points
  (28.1 vs 25.4), as much as the H.264/JPEG difference. With 2 runs per configuration we
  cannot say that JPEG is cheaper; we can only say that the difference is small
  compared to the total cost of the sender. The CPU is dominated by parts common to both
  configs (recording encoder, overlays, conversions, startup of ~1-2 s included in the
  measurement).
* **Test pattern.** `smpte` is almost static (only the time overlay and the brightness
  change), which is the best case for H.264 inter-frame prediction. A real camera image
  with motion and noise would increase the H.264 rate (or lower its quality at
  1000 kbit/s) and also increase the JPEG frame size; the ratio would probably be lower.
* **Quality not measured.** The two configurations do not have the same image quality
  (JPEG quality=80 vs H.264 at a fixed 1000 kbit/s); we did not compute PSNR/SSIM and did
  not compare the received images, so a lower bitrate could also mean a lower quality.
* **Latency and packet loss not measured.** Everything is on localhost (no loss, no
  bandwidth limit); the results say nothing about behaviour on a real network.
* Only 2 x 2 runs of 45 s, one machine, Windows only (not reproduced in Codespaces).
* The data rate is averaged over 45 s including the start of the pipeline, so the
  steady-state rate is slightly higher (< 3 %).

## Engineering conclusion

For a video monitoring system that streams several cameras over a shared network,
**H.264/RTP is the better default**: at our resolution it needs about **3.6x less
bandwidth** than JPEG (≈1.0 vs ≈3.7 Mbit/s per stream) for **no measurable extra CPU** on
the sender (the difference, ~2 points of one core, is within our measurement noise).
With a 100 Mbit/s link, this is roughly 90 H.264 streams against 25 JPEG streams.

JPEG/RTP is still worth considering when:

* **error recovery** matters more than bandwidth: every JPEG frame is independent, a lost
  packet damages one frame only, whereas with H.264 an error can last until the next
  keyframe (up to 1 s with our `key-int-max=10`);
* **interoperability / simplicity** matters: JPEG over RTP has a static payload type
  (26) and needs no SPS/PPS, the receiver caps are simpler and any frame can be
  decoded alone, which also makes the "join late" case trivial;
* the sender is a very weak device without hardware H.264, where the encoder cost would
  dominate (not the case here: x264 `ultrafast` at 800x450/10 fps is cheap).

The price of H.264 is therefore not CPU but complexity and error sensitivity, which we
reduce with a short GOP (1 s), `config-interval=1` and the receiver jitter buffer.
For our assigned configuration (800x450, 10 fps, localhost) we keep H.264 for the
network branch.

## Reproduce

```bash
./scripts/clean.sh
./scripts/build.sh
./scripts/run-experiment.sh                 # 2 x 2 runs of 45 s, ~4 min
./scripts/run-experiment.sh --repeats 3     # more repetitions
```

The script prints the table and rewrites `evidence/measurements.csv`.
