import AppKit
import SwiftUI

/// The app's appearance override (ho-06.2 AT-03, Decision 4).
///
/// A pure UI preference — stored in UserDefaults via `@AppStorage`, not
/// `config.yaml` (which holds operational vault/scan state). The enum and its
/// ``colorScheme`` mapping live here, out of the SwiftUI `SettingsScene` view,
/// so the mapping is unit-tested without a running scene and carries real
/// coverage (the view is the coverage-excluded, headless-undrivable part).
enum AppAppearance: String, CaseIterable, Identifiable {
    /// Follow the system appearance (no override).
    case system
    /// Force light appearance.
    case light
    /// Force dark appearance.
    case dark

    /// Stable identity for the SwiftUI picker.
    var id: String { rawValue }

    /// Human-readable label for the Settings picker.
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The `ColorScheme` this override resolves to, or `nil` for "follow the
    /// system" — the value handed to `.preferredColorScheme`.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// The AppKit appearance this override applies to the whole app, or `nil`
    /// to follow the system.
    ///
    /// Applied to `NSApp.appearance` rather than through SwiftUI's
    /// `.preferredColorScheme`: passing that modifier `nil` after an explicit
    /// scheme does not reliably return the window to following the system,
    /// so "System" left the window in the last forced look while sheets and
    /// dialogs followed the real system — a mix of light and dark (the
    /// ho-06.9 gate finding). The app-level AppKit setting drives every
    /// window, sheet, and system-rendered dialog together.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Applies this override app-wide (see ``nsAppearance``).
    @MainActor
    func apply() {
        NSApp.appearance = nsAppearance
    }

    /// The UserDefaults key shared by the Settings picker and the app's
    /// appearance applier, so both bind to the same stored value.
    static let storageKey = "appearance"
}
