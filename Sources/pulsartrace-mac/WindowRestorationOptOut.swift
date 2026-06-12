import AppKit
import SwiftUI

/// Excludes the hosting window from macOS state restoration
/// (`NSWindow.isRestorable = false`), so it is never re-presented at launch.
///
/// Why: restoration orders a saved window frontmost while the app launches,
/// but an accessory app is not activated at launch and cooperative
/// activation declines a self-issued activate with no user interaction
/// behind it — the restored window draws in the greyed inactive appearance
/// (QA rounds 4–7; see the scene comment in `PulsarTraceMacApp`). Opting
/// out keeps every window-open on a user-action path, where activation is
/// granted. Window frame persistence is a separate mechanism and is not
/// affected — a reopened window still gets its last size and position.
///
/// This is the AppKit-level equivalent of the macOS 15-only
/// `restorationBehavior(.disabled)` scene modifier (the PRD floor is
/// macOS 14, and `SceneBuilder` cannot branch on `#available`).
///
/// Usage: `.background(WindowRestorationOptOut())` on the window's root view.
struct WindowRestorationOptOut: NSViewRepresentable {

    func makeNSView(context: Context) -> OptOutView { OptOutView() }

    // Re-applied on every update in case SwiftUI reconfigures the window.
    func updateNSView(_ view: OptOutView, context: Context) { view.apply() }

    final class OptOutView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            window?.isRestorable = false
        }
    }
}
