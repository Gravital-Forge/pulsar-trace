> Read [`00-overview.md`](00-overview.md) first; execute tasks in order.

# Task 19: Verification sweep + acceptance run

- [ ] **Step 1: Run every narrow filter (each bare; `dangerouslyDisableSandbox: true` per CLAUDE.md)**

```
swift test --filter UnitTests
swift test --filter Refinement
swift test --filter IPC
swift test --filter RecordOrchestrator
swift test --filter LiveRunner
swift test --filter Streaming
swift test --filter Speaker
swift test --filter Source
swift test --filter Lifecycle
swift test --filter FinalMarkdownRewriter
swift test --filter Parakeet
swift test --filter WhisperKitRefine
swift test --filter FluidVAD
swift test --filter LanguageCatalog
swift test --filter MenuBar
```

Expected: every filter green. Any failure — even in a suite this plan didn't touch — is handled per the CLAUDE.md test posture (fix, gate explicitly, or escalate; never move on red). `DiarizationE2E` is unchanged by this plan; run `swift test --filter DiarizationE2E` too if the venv + HF_TOKEN are present.

- [ ] **Step 2: End-to-end menubar dogfood (human-in-the-loop)**

Build and run `pulsartrace-mac`. Settings should show: no live-model picker; Refinement model `large-v3-turbo` (pre-D39 persisted names re-default automatically); the rewritten "Restrict to languages" caption. Record a short real meeting, let auto-refine complete. Verify live.md appended during the call (Parakeet — watch the first-recording ~0.5 GB download on a clean cache), final.md replaced it, the refinement queue UI showed stages, and pausing/resuming refinement around a second recording still works (the WhisperKit release-hook path).

- [ ] **Step 3: Run the D39 acceptance checklist**

Execute `docs/release-smoke-test.md` "ANE pipeline (D39)" (written in task 18) on the M2 Air — this is the spec's acceptance criteria, verbatim: GPU-free live + Meet (`sudo powermetrics --samplers gpu_power,ane_power -i 1000 -n 30`), refine-vs-1×-real-time baseline (`sudo asitop`), Polish + English end-to-end, language pre-selection via the Restrict-to-languages selector **and** `refine --language pl`, and the `model_downloaded` digest events on a clean cache. `powermetrics`/`asitop` need `sudo`, so the human runs those terminals.

- [ ] **Step 4: Wrap up the branch**

Use the `pulsartrace-finishing-a-development-branch` skill (which invokes `pulsartrace-doc-sync`) to sync remaining docs (README model mentions, `docs/` references to `base`/`large-v3` defaults or `scripts/build-whisper.sh` setup steps — the vendored-whisper build instructions must go) and integrate the branch.
