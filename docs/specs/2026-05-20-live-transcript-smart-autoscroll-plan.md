# Live Transcript Smart Auto-Scroll

> **Status:** Shipped. This file kept in `docs/specs/` as a design record until
> the menubar UI gets a settled-zone home. Forward-zone rule still applies:
> settled docs (`overview.md`, the component pages) MUST NOT link here.

**Goal.** When the detached Live Transcript window is open and lines are
appending to `live.md`, the user sees the latest line without thinking about
it — **but only if they were already at the bottom**. If the user has scrolled
up to read earlier text, the view stays put while a "↓ N new" pill counts
how many lines arrived. Tapping the pill (or scrolling back to the bottom)
re-engages auto-follow.

## The algorithm

> Before the new line is scheduled to render, is the user at the bottom?
> If yes, keep them at the bottom.

That sentence is the spec, verbatim. The implementation is the smallest
machinery that can answer that question at the right moment.

```
on each transcript update (new joined-lines string is about to be applied):
    wasAtBottom := isAtBottom(scrollView)        # synchronous read of OLD layout
    textView.string = newJoinedLines             # mutate
    ensureLayout()                               # force layout pass
    if wasAtBottom:
        scrollToBottom(scrollView)               # keep them at the bottom
    else:
        controller.notePendingNewLines(delta)    # pill counter ticks up
```

`isAtBottom` is a strict 8pt threshold — "essentially at the bottom," well
under one line-height. There is no second threshold and no hysteresis.

Live scroll events (user dragging the scroller, two-finger scrolling, etc.)
post `boundsDidChangeNotification` on the scroll view's content view. A
coordinator subscribes and calls `controller.setIsAtBottom(...)` on every
event with the same 8pt threshold. The controller's `isAtBottom` and
`pendingNewLines` drive the SwiftUI pill overlay.

## Why NSScrollView, not pure SwiftUI

Pure SwiftUI (`GeometryReader` + `PreferenceKey`) cannot answer the spec.
Both fire **after** layout. By the time a `PreferenceKey` carries a fresh
distance-from-bottom value, the new line has already laid out — the
measurement reflects post-growth state, not the user's actual pre-growth
position. Two attempts to work around this with thresholds and hysteresis
both shipped briefly and both failed against the spec.

`NSViewRepresentable.updateNSView` gives us the hook the spec actually
requires: it is called with the new data but *before* `NSTextView.string`
is reassigned, so the `NSScrollView`'s `contentView.bounds.origin.y` still
reflects where the user is right now, against the old content. That is the
synchronous "before-render" moment, and it is the only place the spec's
question has a meaningful answer.

## Files

```
Sources/PulsarTraceMenuBar/
  AutoScrollController.swift      @MainActor @Observable. Pill-driving state
                                  (isAtBottom, pendingNewLines, jump generation).
                                  No threshold logic, no scroll decision.

Sources/pulsartrace-mac/
  TranscriptView.swift            TranscriptView (shared) +
                                  SmartScrollingTranscript (live overlay) +
                                  LiveScrollableTranscript (NSViewRepresentable
                                  wrapping NSScrollView + NSTextView, owns the
                                  before-render check) +
                                  JumpToLatestPill.
  LiveTranscriptView.swift        Owns an @State AutoScrollController and
                                  passes it through TranscriptView.autoScroll.

Tests/MenuBarTests/
  AutoScrollControllerTests.swift 7 tests on the simpler controller API.
```

`TranscriptView` accepts an optional `AutoScrollController?` — the recorded-
transcript viewer (`RecordingsListView`) passes `nil` and renders a plain
SwiftUI `ScrollView`, untouched by any of this.

## Public surface — `AutoScrollController`

```swift
@MainActor @Observable public final class AutoScrollController {
    public private(set) var isAtBottom: Bool                  // written by scroll view
    public private(set) var pendingNewLines: Int              // → "↓ N new"
    public private(set) var jumpToLatestGeneration: Int       // bumped on pill tap

    public init()
    public func setIsAtBottom(_ value: Bool)                  // live scroll events
    public func notePendingNewLines(_ delta: Int)             // arrived while away
    public func jumpToLatest()                                // pill tap
}
```

The scroll view writes `isAtBottom` / `pendingNewLines`; the pill reads them.
The "should I scroll on a new line?" decision is **not** in the controller —
it cannot be, because by the time the controller knows the line arrived, the
geometry has already moved. The decision lives where the synchronous answer
lives: inside `LiveScrollableTranscript.updateNSView`.

`jumpToLatestGeneration` is a monotonic counter: the pill calls
`jumpToLatest()`, which bumps the generation; `updateNSView` notices the
change against its last-seen value and animates a `scrollToBottom`. Using a
counter rather than a one-shot flag means the scroll view never has to call
back into the controller to "reset" it — fewer round-trips, fewer races.

## Lifecycle

- **Window opens.** `LiveTranscriptView` creates a fresh
  `AutoScrollController()` via `@State`. On first appear the scroll view
  jumps to the bottom (one-runloop `DispatchQueue.main.async` so the text
  view has finished laying out first). Reopen = fresh controller =
  follow-mode by default — the user's intent on opening the window is "show
  me the latest."
- **Recording stops while window open.** Lines stop appending. Last decision
  sticks. No state to unwind.
- **Window closes.** `NSViewRepresentable.dismantleNSView` runs on the main
  actor and removes the `boundsDidChangeNotification` observer. Swift 6.2's
  nonisolated `deinit` cannot touch the observer token, so the cleanup
  cannot live there — `dismantleNSView` is the right hook.

## What got tried before this shape

These are the simpler-looking shapes that don't work. Recorded here so a
future reader who thinks "why don't we just use SwiftUI's `ScrollView`?"
has an answer.

**Attempt 1 — single-threshold `GeometryReader` + `PreferenceKey`.** Outer
`GeometryReader` for viewport height, inner `GeometryReader` in a
`.background` to measure content `maxY` in a named coordinate space,
`distance = inner.maxY - outerHeight` fed to the controller, scroll on
`onChange(of: lines.count)` when distance ≤ 40pt. Failed because the
preference change reflects post-growth content: a new line bumps distance
by ~one line-height in the same render pass, so the threshold is crossed
spuriously and the pill flashes on every append.

**Attempt 2 — hysteresis (pause threshold 60pt, resume threshold 8pt).**
Tried to absorb the per-new-line content bump by widening the pause band.
"Worked" in the loose sense — pill stopped flashing — but the pause band
was too generous: it followed even when the user was 30–50pt above the
bottom, producing unwanted scroll-down jumps as the user tried to read
earlier text. Workaround for a measurement taken at the wrong time; never
the spec.

**Why both failed for the same reason.** They both took the measurement
*after* layout, then tried to recover the pre-growth answer with arithmetic.
The pre-growth answer is not recoverable post-growth without exact
knowledge of the bump — which `GeometryReader` doesn't give you. The fix
isn't a smarter post-layout calculation; it's reading the answer before
layout. That requires `NSViewRepresentable`.

## Commits

```
ce24084 feat(menubar): add AutoScrollController for live-transcript smart auto-scroll
2d82cec feat(transcript-view): smart auto-scroll variant gated on optional controller
5e1d2f7 feat(live-transcript): wire AutoScrollController into the live window
93dd799 fix(autoscroll): hysteresis + scoped animations to stop new-line jumps   # Attempt 2 — kept in history
693b731 fix(autoscroll): NSScrollView wrapper + before-render at-bottom check    # what shipped
```
