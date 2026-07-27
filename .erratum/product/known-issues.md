# PT — Known Issues

Accepted limitations and deferred work that are understood, tracked, and consciously not being fixed
right now. This register exists so a known gap is a recorded decision rather than a surprise; it is
a product-local tailoring of Erratum (see the Tailoring section of `../erratum.md`), not part of the
framework's requirement / architecture / traceability core. Each entry carries a local `KI-n` tag (a
namespace separate from the Erratum ID scheme) so it can be referenced from commits and review
notes. An entry is removed when the underlying work lands or is promoted into a project.

## KI-1 · No continuous integration

**Status:** Deferred — cost.

There is no CI pipeline: nothing enforces the build, the test suites, or the pre-commit formatting
hooks on push — every check is run by hand. The suite is macOS-only by nature: transcription and
diarization run on the Apple Neural Engine (CoreML), so there is no cheaper Linux/container runner
to fall back to, and hosted macOS runner minutes are expensive. That cost is why it is deferred. The
gap compounds with KI-2, which constrains which suites could run unattended at all.

## KI-2 · Cross-suite pipeline test flakiness

**Status:** Deferred.

Running every `Tests/PipelineTests/` suite together in one command
(`swift test --filter PipelineTests`) is known-flaky under cross-suite races on process-wide
resources (file descriptors, Unix domain sockets, subprocess slots); Swift Testing's `.serialized`
trait only serializes within a suite, so the set of failures shifts run-to-run. The root cause and
the evidence that it is pre-existing are documented in full in `CLAUDE.md`; that is the one home for
the detail. In practice verification uses the narrow per-area filters, and there is no
single-command green run of the full suite.

## KI-3 · Microphone speaker identified by display name

**Status:** Accepted — deferred.

The rule "the microphone speaker can never be delisted" is enforced by comparing the speaker's
display name to the constant `"You"` (`SpeakerEditService.cannotDelistMicrophone`). Display names
are mutable, so the guard keys on a value that can change: renaming the microphone speaker to a real
name makes it delistable again, and naming a guest `"You"` makes that guest un-delistable. This is
one ordinary rename away, not an exotic edge case. It manifests in the Speaker Edit Service (PT-C23)
over the Speaker Library (PT-C5).
