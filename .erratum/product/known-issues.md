# PT — Known Issues

Accepted limitations and deferred work that are understood, tracked, and consciously not being fixed
right now. This register exists so a known gap is a recorded decision rather than a surprise; it is
a product-local tailoring of Erratum (see the Tailoring section of `../erratum.md`), not part of the
framework's requirement / architecture / traceability core. Each entry carries a local `KI-n` tag (a
namespace separate from the Erratum ID scheme) so it can be referenced from commits and review
notes. An entry is removed when the underlying work lands or is promoted into a project.

## KI-2 · Cross-suite pipeline test flakiness

**Status:** Deferred.

Running every `Tests/PipelineTests/` suite together in one command
(`swift test --filter PipelineTests`) is known-flaky under cross-suite races on process-wide
resources (file descriptors, Unix domain sockets, subprocess slots); Swift Testing's `.serialized`
trait only serializes within a suite, so the set of failures shifts run-to-run. The root cause and
the evidence that it is pre-existing are documented in full in `CLAUDE.md`; that is the one home for
the detail. In practice verification uses the narrow per-area filters, and there is no
single-command green run of the full suite.

## KI-4 · Long output-folder names break the capture socket

**Status:** Accepted — deferred.

The capture daemon's per-session Unix socket embeds the recording output folder's basename verbatim
(`$TMPDIR/PulsarTrace/rec_<basename>-mic.sock`), and Darwin caps `sockaddr_un.sun_path` at 104 bytes
— under the standard `/var/folders` temp dir that leaves roughly 33 characters for the basename. A
`pulsartrace record --output` whose folder basename exceeds it fails at capture start with "socket
path too long". Surfaced by the real-audio smoke (PT-R132) during PT-P7; the clean fix is deriving
the socket name from a hash or truncation of the session name rather than the basename. It manifests
in the Capture Daemon (PT-C15) / record orchestrator boundary.
