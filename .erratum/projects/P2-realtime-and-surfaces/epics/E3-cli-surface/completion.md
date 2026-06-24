# PT-P2-E3 · CLI Surface — Completion Record

**Status:** Frozen · **Closed:** 2026-05-16

## What was built

`record` is driven by an engine-side `RecordOrchestrator` that builds the capture/engine argv
(`RecordPlan`), spawns the capture daemon and `pulsartrace-engine --live` with a listen-before-connect
handshake, runs for `--duration` or until interrupted, then refines to a final transcript; flags
cover output, mic, system-audio toggle, and model, with host guards. `doctor` (`EnvironmentDoctor`)
runs pure checks — OS version, CPU arch, model cache, runtime, speaker library, permissions, writable
directories — into an actionable report that exits non-zero on any hard failure; `--capture-test`
(`CaptureSelfTest`) plays a tone and verifies the dominant frequency back through the mic path
(`ToneDetector`, Goertzel). `events tail` (`EventLogTail`) streams today's events with a repeatable,
validated `--type` filter and a clean follow loop; `install-cli` (`CLIInstaller`) symlinks into the
local bin with explicit consent and supports uninstall. A manual release smoke-test checklist covers
the hardware-dependent paths.

This CLI work was implemented before the menubar.

## Deltas from the spec

None.

## Requirements satisfied

| Project Requirement | Where |
| ------------------- | ----- |
| PT-P2-R7 | `Sources/PulsarTraceEngine/Engine/RecordOrchestrator.swift`, `Refinement/RecordPlan.swift`; `Sources/pulsartrace/RecordCommand.swift` |
| PT-P2-R8 | `Sources/PulsarTraceEngine/Support/Doctor.swift`, `Support/ToneDetector.swift`; `Sources/pulsartrace/DoctorCommand.swift`, `CaptureTest.swift` |
| PT-P2-R9 | `Sources/PulsarTraceEngine/Events/EventLogTail.swift`, `Support/CLIInstaller.swift`; `Sources/pulsartrace/EventsCommand.swift`, `InstallCommand.swift` |
| PT-P2-R14 | release smoke-test checklist (operational document, outside `.erratum/`) |

## To flow into the product layer

- Extend the Command-Line Interface component with `record`, `doctor`, `events`, and `install-cli`.
- Mint product requirements PT-R47 (`record`), PT-R50 (`doctor`), PT-R68 (capture self-test), PT-R66
  (loopback capture test target), PT-R86 (`events tail`), PT-R51 (`install-cli`), PT-R69 (smoke-test
  checklist).
