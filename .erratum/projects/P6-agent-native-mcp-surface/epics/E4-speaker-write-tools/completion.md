# PT-P6-E4 · Speaker Write Tools — Completion Record

**Status:** Frozen · **Closed:** 2026-06-29

## What was built

The MCP surface gained the nine speaker-management tools, each a thin one-to-one wrapper over the E1
`SpeakerEditService`, and the capture gate that protects them.

- **`RecordingGate`** (PT-R32). `blockIfRecording() async -> CallTool.Result?` consults the live
  recording id via the `RecordingsProviding` seam and returns an `isError` result naming the live
  recording when capture is in progress, else `nil`. Every write tool calls it first and performs no
  mutation when it returns non-`nil`.
- **Nine write tools** (PT-P6-R5, PT-P6-D6 — the full forward + inverse set): `rename_speaker`,
  `merge_speakers`, `split_speaker`, `unmerge_speakers`, `unsplit_speaker`, `delete_speaker`,
  `undelete_speaker`, `delist_speaker`, `undelist_speaker`. Each follows one shape: consult the gate,
  validate the required arguments (an `isError` result on a miss), resolve the output-folder roots
  (for the seven rewriting tools), call the matching service op, and return
  `{"rewritten_recording_ids": [...]}`. `delete` / `undelete` are state-only and take no roots (empty
  result). `delist_speaker` of the microphone speaker is refused by the service
  (`EditError.cannotDelistMicrophone`), surfaced as an `isError` result.
- **Output roots seam.** The roots are supplied as a `@Sendable () async -> [URL]` closure (the live
  app reads `MenuBarSettings`; tests return a temp root), so the tools are testable without the app.
- **`WriteTools.all(service:gate:outputRoots:)`** assembles all nine for registration (consumed by
  the E5 toolset assembly and app wiring).

Parity is proven through `tool.handler`: an MCP `rename_speaker` rewrites the same `final.md`
(`Steve:` → `Steven:`) and returns the same recording ids as the E1 service. The during-capture
contract is proven across the whole set: with a live recording, every one of the nine returns an
`isError` result and both seeded speakers remain live (the library is untouched).

## Deltas from the spec

- **`IdArg` instead of `Result`.** The plan's `idArg` returned `Result<String, CallTool.Result>`,
  which does not compile — `Result.Failure` must conform to `Error` and `CallTool.Result` does not. It
  is a small nested `enum IdArg { case success(String); case failure(CallTool.Result) }`; the call
  sites are byte-identical (`switch idArg(...) { case .failure: …; case .success: … }`).
- **Content form.** `RecordingGate` and the tools use the non-deprecated
  `.text(text:annotations:_meta:)` content form (the single-arg `.text("…")` is deprecated). The
  tools build their results through the shared `ReadTools.jsonResult` / `errorResult`.
- **`unsplit_speaker` direct test.** The per-tool suites directly test `unmerge` (and rename/merge/
  split/delete/undelete/delist); `unsplit` shares the identical verified wrapper shape and is exercised
  by the across-all refusal suite. Its underlying service op is covered by the E1 suite.
- **Registration deferred.** The tools are factories; the full 17-tool set is assembled and the live
  `RecordingGate` + `outputRoots` closure are wired into the app composition root in PT-P6-E5
  (`MCPToolset.all` + `MCPController`), not here.

## Requirements satisfied

- **PT-P6-R5** (thin speaker-management tools with retroactive rewrite + paired events, refused during
  capture) — `Sources/PulsarTraceMCP/WriteTools.swift` (the nine tool factories + `all`),
  `Sources/PulsarTraceMCP/RecordingGate.swift` (the PT-R32 gate). The rewrite/event parity rides on the
  E1 `SpeakerEditService`. Tests: `Tests/MCPTests/WriteToolsEditTests.swift`,
  `WriteToolsInverseTests.swift`, `WriteToolsLifecycleTests.swift`, `WriteToolsGateTests.swift`,
  `RecordingGateTests.swift`.

Code links carry `// PT-P6-R5`.

## To flow into the product layer

At project close-out (per `references/close-out.md`):

- **Architecture:** extend the MCP Server component (PT-C22) with the speaker write surface and the
  `RecordingGate`; note the gate enforces the existing read-only-during-capture guarantee (PT-R32) at
  the agent surface, and that every write rides the shared Speaker Edit Service (PT-P6-E1).
- **Requirements:** mint the product requirement for PT-P6-R5 (an *Introduce*, from `PT-R115` upward),
  `implemented_by` the tool factories + the service. PT-P6-D6's full-inverse-set rationale is recorded
  in the frozen Decision Log.
- **Traceability:** a write-once row for the PT-P6-R5 product requirement.
- **Reference sweep:** re-point every `// PT-P6-R5` code link to its minted product requirement id.
