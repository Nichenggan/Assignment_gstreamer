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

A concrete technical error found during static review of the AI-assisted scripts was
that scripts/run-experiment.sh originally recorded SENDER_STATUS but ended with an
unconditional `exit 0`. A failed sender or measurement could therefore appear
successful. The team rejected the assumption that writing a CSV means the experiment
succeeded. The current script checks run results, returns a non-zero status if any
run fails, and does not replace the evidence CSV with failed results. This update
was checked in the source but was not rerun as part of this documentation change.

Another issue found during review was that scripts/verify.sh accepted most non-zero
statuses as invalid-argument rejection, which could mistake an abnormal termination
for a correct usage error. The current script requires the application's documented
usage-error status (2). This change was also checked in the source only.

These are observed limitations of the AI-assisted implementation, not invented
quotations from an AI response. A historical AI-response example still needs the
team's confirmation if the teacher requires direct attribution to a response.

## Validation evidence and final tests

Existing repository evidence includes debug-report.md, experiment.md,
evidence/measurements.csv, evidence/pipeline.dot, evidence/pipeline.png and
recordings/sample.ts. The experiment report describes two 45-second runs per
codec on Windows. These are existing team records; this audit did not independently
reproduce their measurements.

The implemented verification procedure checks required files and plugins, --help,
invalid arguments, receiver startup, sender PLAYING, decoded RTP data, EOS, recording
creation and decoding, dynamic brightness changes and termination.

For final evaluation on a teammate's computer, run the teacher's sequence **twice**,
retaining the logs from each run before the next clean:

```bash
./scripts/clean.sh
./scripts/build.sh
./scripts/verify.sh
```

Also check graphical preview/reception, playback, the assigned normal runtime and
both experiment configurations. CONTRIBUTIONS.md lists the members' tests and cross
reviews; the team should retain the corresponding run records. This documentation
update provides a static review, not a functional PASS certificate.

## Lessons

The technical lessons illustrated by the implementation and debugging evidence are:
encoding is different from RTP packetization; negotiated caps must agree across
sender and receiver; queues isolate branch scheduling; and a recording needs EOS
finalization. Process signal behavior can differ between operating systems.
AI-generated scripts require review of failure paths as well as the normal path:
plausible commands and successful-looking summaries are not evidence of correctness.
