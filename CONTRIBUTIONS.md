# Team contributions and reviews

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
The testing and cross-review responsibilities reported by the team are recorded
below.

## Testing and cross-review

The following table lists each member's responsibilities and the completion status
reported by the team.

| Member | Assigned tests | Assigned cross review | Status |
|---|---|---|---|
| Nikola MILOSAVLJEVIC | Native --help, missing/invalid arguments, timed headless shutdown, EOS and dynamic-property logs. | Chenyi's native sender and CMake integration; compare source behavior with architecture.md. | Done |
| Chenyi LI | Graphical sender and receiver, headless RTP reception, playback and the assigned 60-second configuration. | Amirhossein's experiment script, CSV calculations, limitations and conclusions. | Done |
| Amirhossein POUYANFAR | Two clean/build/verify cycles, recording discovery/decoding, process cleanup and two 45-second runs per codec. | Nikola's shell pipelines, shared configuration, queues and generated pipeline graph. | Done |

