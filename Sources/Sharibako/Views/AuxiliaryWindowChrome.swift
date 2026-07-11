import SwiftUI

#if os(macOS)
    import AppKit

    /// Strips an auxiliary window's chrome down to the close button.
    ///
    /// The Add windows are small fixed-size forms (ho-06.1 AT-03 Decision 6);
    /// minimize and zoom are noise on them — the ho-06.1 gate asked for "just
    /// an x". SwiftUI has no window-button API at the macOS 14 deployment
    /// target, so this reaches the hosting `NSWindow` through a zero-size
    /// `NSViewRepresentable` (the languages module's blessed AppKit-interop
    /// path for window chrome).
    ///
    /// Attach via `.background(AuxiliaryWindowChrome())` on the window's root
    /// view.
    ///
    /// Coverage-excluded: AppKit window chrome, not headlessly drivable
    /// (ho-05 Decision 8).
    struct AuxiliaryWindowChrome: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            // The view has no window until it lands in the hierarchy; defer
            // one runloop turn so `view.window` resolves.
            DispatchQueue.main.async {
                guard let window = view.window else { return }
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                window.standardWindowButton(.zoomButton)?.isHidden = true
            }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}
    }
#endif
