> Read [`00-overview.md`](00-overview.md) first; execute tasks in order.

# Task 15: Menubar — remove the live model setting, WhisperKit refine picker, captions

The live pass has no model knob: `MenuBarSettings.liveModelName` (and its picker) is deleted, and its `UserDefaults` key is **removed on load**, exactly like the file's existing legacy-key migrations (`legacyModelName`, `legacyOutputFolderBookmark`). The refine picker reads `WhisperKitModelCatalog`. The "Restrict to languages" caption is rewritten for the new cross-pass behaviour (Delta B).

**Files:**
- Modify: `Sources/PulsarTraceMenuBar/MenuBarSettings.swift`
- Modify: `Sources/pulsartrace-mac/SettingsView.swift:35-80`
- Test: `Tests/MenuBarTests/MenuBarSettingsTests.swift`

- [ ] **Step 1: Update the settings tests first (failing)**

In `Tests/MenuBarTests/MenuBarSettingsTests.swift` (match the suite's existing temp-`UserDefaults` fixture pattern — it constructs throwaway suites; the code below shows the inline form, adapt to the local helper if one exists):

1. The persistence round-trip test (~lines 28–40): delete the `settings.liveModelName = "base"` write and `#expect(reloaded.liveModelName == "base")`; change the refine value to a catalog name: `settings.refineModelName = "large-v3-whisperkit"` / `#expect(reloaded.refineModelName == "large-v3-whisperkit")`.
2. The defaults test (~lines 55–56): delete the `liveModelName` line; keep `#expect(settings.refineModelName == MenuBarSettings.defaultRefineModelName)`.
3. Replace the "a legacy `modelName` key migrates into `liveModelName` (D29)" test (~lines 97–108) and the explicit-keys test's `liveModelName` parts (~lines 117–122) with:

```swift
    @Test("legacy live-model keys are removed on load (D39)")
    func legacyLiveModelKeysRemoved() {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        suite.set("large-v3", forKey: "modelName")      // pre-D29 single knob
        suite.set("base", forKey: "liveModelName")      // pre-D39 live knob
        let settings = MenuBarSettings(defaults: suite)
        #expect(suite.object(forKey: "modelName") == nil)
        #expect(suite.object(forKey: "liveModelName") == nil)
        #expect(settings.refineModelName == MenuBarSettings.defaultRefineModelName)
    }

    @Test("a persisted pre-D39 refine model name re-defaults to the ANE catalog")
    func staleRefineModelNameRedefaults() {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        suite.set("large-v3", forKey: "refineModelName")   // retired ggml name
        let settings = MenuBarSettings(defaults: suite)
        #expect(settings.refineModelName == "large-v3-turbo")
    }
```

Run: `swift test --filter MenuBar` (bare; `dangerouslyDisableSandbox: true` per CLAUDE.md)
Expected: FAIL on the new/changed assertions (and compile errors once `liveModelName` is referenced nowhere — that's next).

- [ ] **Step 2: Implement the MenuBarSettings changes**

In `Sources/PulsarTraceMenuBar/MenuBarSettings.swift`:

1. Add `import PulsarTraceEngine` at the top (verified missing — the file currently imports only `Foundation`; the new default references `WhisperKitModelCatalog`).
2. Delete `static let defaultLiveModelName` and the `public var liveModelName: String { didSet { save() } }` property (with their doc comments). Replace `defaultRefineModelName`:

```swift
    /// Default refine-pass model — Whisper large-v3-turbo on the ANE via
    /// WhisperKit (D39): near-large-v3 accuracy, ~626 MB, GPU-free.
    public static let defaultRefineModelName = WhisperKitModelCatalog.defaultModel.name
```

3. In `Key`, replace `static let liveModelName = "liveModelName"` with:

```swift
        /// Legacy live-model key (pre-D39) — removed on load; the live pass
        /// has exactly one backend now (parakeet-v3, not user-selectable).
        static let legacyLiveModelName = "liveModelName"
```

   (`Key.legacyModelName` already exists — keep it.)
4. In `init`, replace the whole D29 migration block (the `legacyModelName` read, the `self.liveModelName = …` assignment, the `self.refineModelName = …` assignment, and the `removeObject(forKey: Key.legacyModelName)` cleanup) with:

```swift
        // D39: the live model knob is gone (Parakeet is the only live
        // backend). Drop both stale keys — the pre-D29 single `modelName`
        // and the pre-D39 `liveModelName` — so they can never resurface,
        // same pattern as the legacy bookmark migrations below.
        store.removeObject(forKey: Key.legacyModelName)
        store.removeObject(forKey: Key.legacyLiveModelName)
        // A persisted pre-D39 refine name ("base"/"large-v3") names a
        // retired ggml backend — re-default to the ANE catalog (clean over
        // compat: no display shims for dead backends).
        self.refineModelName = store.string(forKey: Key.refineModelName)
            .flatMap { WhisperKitModelCatalog.model(named: $0)?.name }
            ?? Self.defaultRefineModelName
```

5. In `save()`, delete the `defaults.set(liveModelName, forKey: Key.liveModelName)` line.

- [ ] **Step 3: Update SettingsView**

In `Sources/pulsartrace-mac/SettingsView.swift` (the `Section("Transcription")` block, lines ~35–80):

1. Delete the whole `Picker("Live transcription model", …)` (the live pass has no knob — nothing replaces it).
2. Replace the refinement picker's `ForEach(ModelCatalog.all, …)` and the "large-v3 is higher quality…" caption with:

```swift
                Picker("Refinement model",
                       selection: $settings.refineModelName) {
                    ForEach(WhisperKitModelCatalog.all.map(\.name), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Text("Runs on the Neural Engine — recording never competes "
                    + "with Meet or screen-share for the GPU. large-v3-turbo "
                    + "is the fast default (~626 MB download on first use); "
                    + "large-v3-whisperkit is the slower accuracy fallback "
                    + "(~947 MB). Live transcription always uses Parakeet v3 "
                    + "(~0.5 GB on first recording).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
```

3. Replace the "Restrict to languages" caption ("Leave empty to let whisper auto-detect freely…") with the Delta B cross-pass behaviour:

```swift
                Text("Applies to both passes. Pick exactly one language to "
                    + "pin refinement to it and steer live transcription "
                    + "toward its script. Pick several and refinement "
                    + "detects the best match among them per turn (live "
                    + "stays auto). Leave empty for full auto-detect. "
                    + "Changes apply to refinements queued after the next "
                    + "app launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
```

   (The "next app launch" sentence is honest: queue `whisperOptions` are fixed at bootstrap — same behaviour the old `allowedLanguages` wiring had. Do not re-architect queue options here.)

- [ ] **Step 4: Sweep the remaining `liveModelName` references**

Run: `grep -rn "liveModelName" Sources/ Tests/`
Expected: zero hits after steps 2–3 (task 12 already removed the `RecordingViewModel` consumer). If any test still sets `settings.liveModelName` (e.g. a `RecordingViewModelTests` fixture), delete that line — the property is gone.

- [ ] **Step 5: Build + run the menubar suite**

Run: `swift build`
Expected: compiles.
Run: `swift test --filter MenuBar`
Expected: PASS, including the two new tests from step 1.

- [ ] **Step 6: Commit**

```bash
git add Sources/PulsarTraceMenuBar/MenuBarSettings.swift Sources/pulsartrace-mac/SettingsView.swift Tests/MenuBarTests
git commit -m "feat(menubar): drop the live-model setting; WhisperKit refine picker + cross-pass language caption"
```
