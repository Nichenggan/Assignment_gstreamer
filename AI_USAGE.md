# AI usage report

## Scope and division of work

The team defined the project plan and selected the tools manually. AI assistance was
used for script implementation details. Script debugging combined human analysis
with AI assistance. The team remains responsible for reviewing, understanding,
correcting and validating the submitted work.

This disclosure is based on the team's account and the repository. It does not claim
that an AI conversation or an individual test took place when no record is available.

## Tools and team members

The development tools reported by the team are **Gemini (web version)** and
**ChatGPT**. The team consists of Nikola MILOSAVLJEVIC, Chenyi LI and Amirhossein
POUYANFAR. The tools were used at team level for script details and joint debugging;
individual tool-to-member session records and model versions were not supplied.
Each member must confirm their own use before final submission.

A subsequent repository audit and preparation of this disclosure used **OpenAI
Codex**, at Chenyi LI's request. This assistance covered static source/document
review, drafting this report and the contribution record, and repository maintenance.
It is separate from the original development work.

## Representative prompts

These prompts are reconstructions of the described tasks, not verbatim conversation
transcripts:

1. "Implement the shell-script details for our human-designed GStreamer monitoring
   system. Read config/team.conf; use tee and a queue on each branch for preview,
   recording and RTP/UDP transmission. Include a headless receiver and finalize the
   recording with EOS. Return an error when a command fails."
2. "Help debug a sender that does not stop under timeout -s INT in Windows Git Bash.
   Compare the signal-based stop with an internal --duration timer. Explain how to
   distinguish a missing stop request from an EOS propagation problem and which
   logs to inspect."
3. "Review our verification and H.264/RTP versus JPEG/RTP experiment scripts. Check
   that results reflect actual received data, decoded recordings and process exit
   status, and identify cleanup and timeout gaps."

## Implementation choices retained

The following choices appear in the implementation and were retained during the
AI-assisted workflow; the original human plan and tool selection remained human work:

- Read shared parameters from config/team.conf and separate sender, receiver,
  playback, build, cleanup and verification scripts.
- Use separate queues after tee, explicit receiver RTP caps, a depayloader and a
  decoder; use a non-display sink for automated reception checks.
- Use an internal finite duration and EOS for normal recording termination.
- Inspect sender logs, actual decoded RTP frames, recording duration and decoding
  rather than treating a non-empty file alone as proof of success.

## Suggestions rejected or corrected, and limitations found

The repository's debug report documents a rejected diagnosis: the initial suspicion
that the pipeline was stuck propagating EOS was inconsistent with the absence of
STOP_REQUESTED. The correction uses an internal duration-triggered EOS instead of
relying on POSIX signal delivery to a native Windows process. We cannot attribute
that original hypothesis to a particular AI response because no transcript was
provided.

A concrete technical error found during static review of the AI-assisted scripts is
in scripts/run-experiment.sh: it records SENDER_STATUS but ends with unconditional
`exit 0`. Thus a failed sender or failed measurement can still produce a successful
script exit. The assumption that "writing a CSV means the experiment succeeded" is
rejected. The required correction is to propagate failures, validate measurement
outputs, and clean up child processes on interruption. **This correction is still
pending; it has not been implemented or tested in this documentation update.**

A second limitation is that scripts/verify.sh accepts most non-zero statuses as
invalid-argument rejection, so an abnormal termination can be mistaken for an
intentional usage error. It should require the application's documented usage-error
status (2). This is also pending.

These are observed limitations of the AI-assisted implementation, not invented
quotations from an AI response. A historical AI-response example still needs the
team's confirmation if the teacher requires direct attribution to a response.

## Validation evidence and final tests

Existing repository evidence includes debug-report.md, experiment.md,
evidence/measurements.csv, evidence/pipeline.dot, evidence/pipeline.png and
recordings/sample.mkv. The experiment report describes two 45-second runs per
codec on Windows. These are existing team records; this audit did not independently
reproduce their measurements.

The implemented verification procedure checks required files and plugins, --help,
invalid arguments, receiver startup, sender PLAYING, decoded RTP data, EOS, recording
creation and decoding, dynamic brightness changes and termination.

Final execution will take place on a teammate's computer. Run the teacher's sequence
**twice**, retaining the logs from each run before the next clean:

```bash
./scripts/clean.sh
./scripts/build.sh
./scripts/verify.sh
```

Also check graphical preview/reception, playback, the assigned normal runtime and
both experiment configurations. CONTRIBUTIONS.md assigns these tests and cross
reviews. They are pending, not claimed as completed. The supplied Codespaces
compatibility also remains to be confirmed. This update provides a static audit,
not a functional PASS certificate.

## Lessons

The technical lessons illustrated by the implementation and debugging evidence are:
encoding is different from RTP packetization; negotiated caps must agree across
sender and receiver; queues isolate branch scheduling; and a recording needs EOS
finalization. Process signal behavior can differ between operating systems.
AI-generated scripts require review of failure paths as well as the normal path:
plausible commands and successful-looking summaries are not evidence of correctness.
