# Debug report: the sender cannot be stopped by a signal on Windows, recording not finalized

Category: *recording terminated without EOS* / *pipeline state changes*.
Environment where it happened: Windows 11, Git Bash (MSYS2), GStreamer 1.28.8 MSVC
x86_64, `monitor_sender` built with MSVC 14.44.

## 1. Observed symptom

We wanted to test the "run until Ctrl+C" mode without a human pressing Ctrl+C, so we
wrapped the sender in `timeout -s INT`:

```bash
timeout -s INT 8s bash scripts/sender.sh --headless --duration 0 --output artifacts/debug1/fault.mkv
```

* `timeout` fired after 8 s, but the command **never returned**. More than one
  minute later `gst-launch-1.0.exe` was still running (`tasklist`) and the recording
  kept growing. We had to stop it by hand with `taskkill //PID <pid> //F`.
* Same thing with the native program, called directly (no bash wrapper):
  `timeout -s INT -k 4s 6s ./build/monitor_sender ... --headless` (no `--duration`).
  Nothing happened at 6 s; the process was only stopped by the SIGKILL at 10 s
  (exit code 137). The log has no `STOP_REQUESTED`, no `EOS_RECEIVED`, no `EXIT` line.
* The resulting `.mkv` is still readable (Matroska is tolerant) but its header is
  not finalized (see the log extract).

## 2. Initial hypotheses

1. The pipeline does not propagate EOS (e.g. the leaky queues or the live source
   swallow the EOS, or `x264enc` never drains), so the sender waits forever for EOS.
2. The interrupt never reaches the program, so no EOS is ever sent.
3. `bash scripts/sender.sh` receives the signal but `gst-launch-1.0` (its child)
   does not.

## 3. Commands used during the investigation

```bash
# what is still running after timeout fired?
tasklist //FI "IMAGENAME eq gst-launch-1.0.exe"
ps -ef | grep -E "sender|timeout|gst"

# native sender directly under timeout, with GStreamer warnings/errors enabled
GST_DEBUG=2 timeout -s INT -k 4s 6s ./build/monitor_sender --pattern smpte --width 800 \
    --height 450 --fps 10 --port 5123 --output artifacts/debug3/int.mkv --headless > artifacts/debug3/int.log 2>&1
grep -E "STOP_REQUESTED|EOS_RECEIVED|EXIT" artifacts/debug3/int.log      # -> nothing

# control: same pipeline, stop decided inside the program
GST_DEBUG=2 ./build/monitor_sender ... --headless --duration 6 > artifacts/debug4/ok.log 2>&1

# compare the two files
gst-discoverer-1.0 artifacts/debug2/int.mkv
GST_DEBUG="matroskademux:4" gst-launch-1.0 filesrc location=artifacts/debug2/int.mkv ! matroskademux ! fakesink
GST_DEBUG="matroskademux:4" gst-launch-1.0 filesrc location=artifacts/debug4/ok.mkv  ! matroskademux ! fakesink
```

## 4. Log extract (selected, 18 lines)

```
# ps -ef, 1 min after "timeout -s INT 8s" fired: everything is still alive
gratz 1945 1943  timeout -s INT 8s bash scripts/sender.sh --headless --duration 0 ...
gratz 1946 1945  bash scripts/sender.sh --headless --duration 0 ...
gratz 1968 1946  C:\...\gst-launch-1.0.exe -e videotestsrc name=video_source ... num-buffers=-1 ...

# monitor_sender under "timeout -s INT -k 4s 6s", GST_DEBUG=2 (end of the log)
PIPELINE_STATE PAUSED -> PLAYING
WARN aggregator gstaggregator.c:2355:...:<record_muxer> Latency query failed
DYNAMIC_PROPERTY element=video_balance property=brightness value=0.20
bash: line 1: 59 Killed   GST_DEBUG=2 timeout -s INT -k 4s 6s ./build/monitor_sender ...
exit=137                  (no STOP_REQUESTED / EOS_RECEIVED / EXIT line)

# GST_DEBUG=matroskademux:4 on the killed file
matroskademux0> Too large SeekPosition 18446744073709551615
matroskademux0> Incomplete seekhead entry (0x1549a966/18446744073709551615)

# same pipeline with --duration 6 (control run)
WARN aggregator gstaggregator.c:2355:...:<record_muxer> Latency query failed
STOP_REQUESTED reason=duration -> sending EOS
EOS_RECEIVED all sinks finished, recording finalized
EXIT code=0               (0 "Incomplete seekhead" lines on this file)
```

## 5. Root cause

`gst-launch-1.0.exe` and `monitor_sender.exe` are **native Win32 programs** (MSVC
build), not MSYS programs. In Git Bash, POSIX signals (`kill -INT`, `timeout -s INT`)
are emulated by the MSYS2 runtime and are only delivered to MSYS processes. A native
console program only learns about Ctrl+C through a Windows console control event
(`CTRL_C_EVENT`), which `timeout`/`kill` do not generate. So:

* the `SIGINT` handler of `monitor_sender` (and the `-e` handling of `gst-launch-1.0`)
  is never called, no EOS is sent, the pipeline keeps PLAYING forever;
* in the `sender.sh` case the signal only reaches the bash wrapper, which keeps waiting
  for its native child;
* `SIGKILL` is mapped to `TerminateProcess()`, which works, but kills the process
  without EOS: `matroskamux` never rewrites its SeekHead / duration / cues, which is
  why the demuxer finds the placeholder positions (`18446744073709551615` = `-1`).

The GStreamer pipeline itself is fine; the stop request never reached it.

## 6. Correction

The end of the recording must be decided **inside the program**, not by an external
signal:

* `monitor_sender --duration N`: a GLib timer (`g_timeout_add_seconds`) calls
  `gst_element_send_event(pipeline, gst_event_new_eos())`, then the program waits for
  `GST_MESSAGE_EOS` on the bus before setting the pipeline to NULL
  (`src/monitor_sender.c`, `on_duration_elapsed()` / `request_stop()`).
* `scripts/sender.sh --duration N`: `videotestsrc num-buffers=N*FPS`, the source sends
  EOS itself.
* `verify.sh` always uses `--duration`. The external `timeout -s INT -k 5s` stays only
  as a watchdog so the script can never hang; if it ever has to act, the run is
  reported as a failure (`EOS_HANDLING=FAIL`, `CLEAN_TERMINATION=FAIL`, "sender TIMEOUT"
  in `verification.log`), never as a success.
* README "Known limitations" says that Ctrl+C from mintty does not reach native
  programs and that `--duration` must be used there.

## 7. Why the correction works

The EOS is created by GStreamer code running in the program (timer in the GLib main
loop, or the source after its last buffer), so no operating-system signal is needed and
the behaviour is the same on Linux and on Windows. The EOS travels through the `tee`
into the three branches; `matroskamux` receives it, writes the final SeekHead,
duration and cues, `filesink` closes the file, and only then the bus gets EOS and the
program exits with 0. The control run shows exactly this sequence and a file with no
incomplete SeekHead entries; `verify.sh` gets `EOS_HANDLING=PASS` and a duration of
~12 s from `gst-discoverer-1.0`.

## 8. Alternative diagnosis considered and rejected

**Hypothesis 1: the pipeline cannot finish on EOS** (live source + leaky queues +
encoder that does not drain, so the program waits forever after the EOS).

## 9. Evidence used to reject it

* In the faulty run there is **no `STOP_REQUESTED` line**: `request_stop()` was never
  called, so no EOS was ever sent. The program could not be "waiting for EOS".
* With `GST_DEBUG=2` there is no GStreamer error, and the only warning
  (`Latency query failed` on `record_muxer`) also appears in the control run that
  finishes correctly, so it is unrelated.
* The control run uses the exact same pipeline (same queues, same encoders) and goes
  from `STOP_REQUESTED` to `EOS_RECEIVED` and `EXIT code=0` with a valid file.
  The same pipeline therefore handles EOS correctly.

## 10. How to reproduce the original fault

In **Git Bash on Windows**, after `./scripts/build.sh`:

```bash
mkdir -p artifacts/debug
timeout -s INT -k 4s 6s ./build/monitor_sender.exe --pattern smpte --width 800 --height 450 \
    --fps 10 --port 5123 --output artifacts/debug/int.mkv --headless > artifacts/debug/int.log 2>&1
echo $?                                            # 137 = killed, not 0
grep -E "STOP_REQUESTED|EOS_RECEIVED|EXIT" artifacts/debug/int.log   # nothing
GST_DEBUG="matroskademux:4" gst-launch-1.0 filesrc location=artifacts/debug/int.mkv \
    ! matroskademux ! fakesink 2>&1 | grep "Incomplete seekhead"
```

The fixed behaviour is the same command with `--duration 6` instead of relying on the
signal (exit code 0, `EOS_RECEIVED`, no incomplete SeekHead).

On Linux (Codespaces) we expect the signal to be delivered, because `timeout` sends a
real `SIGINT` to the process, which runs the handler of `monitor_sender` (EOS, exit 0).
We could not test this ourselves, so the Windows procedure above is the reference.
Do not use `timeout -s INT` without `-k` on Windows: the process would never stop.
