# PT-P6-E7 · Review Hardening — Completion Record

**Status:** Complete · **Closed:** 2026-07-01

## What was built

A one-line guard in `LoopbackHTTPRequest.parse`
(`Sources/PulsarTraceMCP/LoopbackHTTPListener.swift`): after reading `Content-Length`, the parser
now returns `nil` when the declared length is negative, before the `available.prefix(expected)` that
would otherwise call `Data.prefix(-1)` and trap. A negative length is unrecoverable, so it is
treated like any other malformed request — the connection is left to the 15 s idle-timeout reaper.
The oversized-body cap and the happy-path round-trip are untouched.

Driven test-first: a parser-level regression test drives a raw `Content-Length: -1` buffer
(`URLSession` rewrites `Content-Length` to the real body size, so the listener cannot be exercised
end-to-end for this case). Before the fix the test aborted the whole test process with
`Fatal error: Can't take a prefix of negative length` (signal 5) — the exact process-kill an
attacker could trigger; after the fix `parse` returns `nil` and the suite is green
(`swift test --filter MCPTests`, 36 tests).

## Deltas from the spec

None.

## Requirements satisfied

- **PT-R115** (opt-in loopback MCP server / its bounded-request front end) —
  `Sources/PulsarTraceMCP/LoopbackHTTPListener.swift` (`LoopbackHTTPRequest.parse`, the
  `expected >= 0` guard); regression test `Tests/MCPTests/LoopbackHTTPListenerTests.swift`
  (`negativeContentLengthRejected`). Code link `// PT-R115`.

## To flow into the product layer

Nothing. This epic introduces, supersedes, and retires no requirement, and changes no component
structure — PT-R115's body and PT-C22's shape are unchanged, and the traceability row for PT-R115
already lists `LoopbackHTTPListener.swift` as an implementation site.
