# Team contributions and final review plan

## Recorded implementation contributions

The table summarizes the areas represented by each member's commits. Commit
ownership is evidence of submitted changes, not proof of sole authorship or of tests
performed personally. AI assistance is disclosed in AI_USAGE.md.

| Member | Git identity | Work represented in the repository |
|---|---|---|
| Nikola MILOSAVLJEVIC | Nikola-Milosavljevic-1 | Team configuration; shell sender, receiver and playback; initial build, cleanup and verification scripts; architecture, pipeline graph and initial README. |
| Chenyi LI | Nichenggan | Native C sender; CMake integration; verification of the native sender; native runtime and dynamic-property documentation; Windows signal/EOS debugging report; final repository audit and disclosure preparation. |
| Amirhossein POUYANFAR | amirpnf | Codec-comparison experiment script, measurements and report; required-file/plugin checks; sample recording; final usage/status documentation. |

## Collaborative work

The team reports that project planning and tool selection were human work, while
script details were AI-assisted and debugging combined human and AI work. The
components share config/team.conf and are integrated through build.sh and verify.sh.
The complete system requires collective review; individual completed cross reviews
and individual historical test records have not yet been supplied.

## Balanced final testing and cross-review allocation

The following is the team's proposed final allocation, based on the implemented
components. **All statuses are pending. These entries are responsibilities, not
claims that the tests or reviews have already occurred.**

| Member | Assigned tests | Assigned cross review | Status |
|---|---|---|---|
| Nikola MILOSAVLJEVIC | Native --help, missing/invalid arguments, timed headless shutdown, EOS and dynamic-property logs. | Chenyi's native sender and CMake integration; compare source behavior with architecture.md. | Pending |
| Chenyi LI | Graphical sender and receiver, headless RTP reception, playback and the assigned 60-second configuration. | Amirhossein's experiment script, CSV calculations, limitations and conclusions. | Pending |
| Amirhossein POUYANFAR | Two clean/build/verify cycles, recording discovery/decoding, process cleanup and two 45-second runs per codec. | Nikola's shell pipelines, shared configuration, queues and generated pipeline graph. | Pending |

All three members should review the integrated system, debug-report.md and
AI_USAGE.md together. Before submission, replace each pending status with the actual
test date, environment, result, evidence path and reviewer confirmation. Record any
failed check and its correction. Do not infer personal testing from a commit date.
