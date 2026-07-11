import AppKit
import SwiftUI

/// The Workshop's semantic color-token layer (ho-06.4).
///
/// Maps the [pālana design system](../../ho-process/hos/ho-06.4-palette-theming.md)
/// palette to named *roles* so no view ever spells a hue. The view code asks for
/// `Color.accentMoss` or `Color.drift`; this file owns what those mean and how
/// they resolve across light and dark.
///
/// Light values are pālana §2, authoritative. Dark values are a warm-dark
/// sibling set designed in ho-06.4 (Decision 2) — pālana specifies only light;
/// these are the candidate to bring pālana in line later. Both halves stay warm,
/// never pure black or white, one moss accent, one rust alarm (pālana's register).
///
/// The raw values live in ``Palette``'s pure ``Palette/resolved(dark:)`` seam, so
/// every token is unit-tested without a running scene — the file carries real
/// coverage and is not CI-excluded, unlike the declarative `View` bodies.

/// A single sRGB color with alpha, as plain `Double` components.
///
/// `Sendable` by construction (all `Double`), so it can be captured by the
/// `NSColor` dynamic-provider closure without crossing a concurrency boundary
/// with a non-`Sendable` `NSColor`.
struct RGBA: Sendable, Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    /// The concrete `NSColor` for these components, in the sRGB space.
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// A token's light and dark values, and the machinery to resolve between them.
struct Palette: Sendable, Equatable {
    /// The value in light appearance (pālana §2).
    let light: RGBA
    /// The value in dark appearance (ho-06.4 Decision 2).
    let dark: RGBA

    /// The raw components for a given appearance — the pure, tested seam both the
    /// dynamic color and the tests read, so neither can drift from the other.
    func resolved(dark isDark: Bool) -> RGBA {
        isDark ? dark : light
    }

    /// An appearance-aware `NSColor` that re-resolves whenever the effective
    /// appearance changes, with no asset catalog.
    ///
    /// The closure captures only the `Sendable` `self`.
    var nsColor: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return resolved(dark: isDark).nsColor
        }
    }

    /// The SwiftUI `Color` view code consumes.
    var color: Color {
        Color(nsColor: nsColor)
    }
}

/// The palette itself — every token's light/dark values in one place (ho-06.4
/// Decision 2).
///
/// The single source of truth; the `Color` extension below is a thin naming
/// layer over it.
enum Theme {
    /// The one interactive color — quiet moss (`#5A7552` / lifted `#7E9B72`).
    static let accent = Palette(
        light: RGBA(red: 0.3529, green: 0.4588, blue: 0.3216, alpha: 1),
        dark: RGBA(red: 0.4941, green: 0.6078, blue: 0.4471, alpha: 1))

    /// The alarm voice — quiet rust (`#984D3C` / lifted `#C56B57`) for drift,
    /// errors, and destructive intent.
    static let alarm = Palette(
        light: RGBA(red: 0.5961, green: 0.3020, blue: 0.2353, alpha: 1),
        dark: RGBA(red: 0.7725, green: 0.4196, blue: 0.3412, alpha: 1))

    /// Primary text — near-black warm ink light, warm off-white dark
    /// (`#1D1B18` / `#ECE7DF`); never pure black or white.
    static let ink = Palette(
        light: RGBA(red: 0.1137, green: 0.1059, blue: 0.0941, alpha: 1),
        dark: RGBA(red: 0.9255, green: 0.9059, blue: 0.8745, alpha: 1))

    /// Secondary facts — `ink` at reduced opacity (pālana's `inkFaint`, 0.55α;
    /// dark carries a touch more presence at 0.60α).
    static let inkSecondary = Palette(
        light: RGBA(red: 0.1137, green: 0.1059, blue: 0.0941, alpha: 0.55),
        dark: RGBA(red: 0.9255, green: 0.9059, blue: 0.8745, alpha: 0.60))

    /// The faintest hints — `ink` fainter still (0.35α light, 0.40α dark).
    static let inkTertiary = Palette(
        light: RGBA(red: 0.1137, green: 0.1059, blue: 0.0941, alpha: 0.35),
        dark: RGBA(red: 0.9255, green: 0.9059, blue: 0.8745, alpha: 0.40))

    /// Warm paper — the ground every view sits on (`#FAF7F3` / `#1B1A17`),
    /// defined for the panel ho (06.5) while the existing window keeps its
    /// materials.
    static let ground = Palette(
        light: RGBA(red: 0.9804, green: 0.9686, blue: 0.9529, alpha: 1),
        dark: RGBA(red: 0.1059, green: 0.1020, blue: 0.0902, alpha: 1))

    /// A shade off `ground` — headers, chips, key-caps (`#F4F1EA` / `#24221E`).
    static let groundDeep = Palette(
        light: RGBA(red: 0.9569, green: 0.9451, blue: 0.9176, alpha: 1),
        dark: RGBA(red: 0.1412, green: 0.1333, blue: 0.1176, alpha: 1))

    /// The cooler "data" surface — the panel ho's reason this layer exists
    /// (`#EDEEF1` cool slate / `#20222A` cool dark slate).
    static let panelGround = Palette(
        light: RGBA(red: 0.9294, green: 0.9333, blue: 0.9451, alpha: 1),
        dark: RGBA(red: 0.1255, green: 0.1333, blue: 0.1647, alpha: 1))
}

extension Color {
    /// The one interactive color — tint, selection, link icon, CTA wash.
    static var accentMoss: Color { Theme.accent.color }

    /// Drift, errors, validation failures, destructive intent (pālana `alarm`).
    static var drift: Color { Theme.alarm.color }

    /// The affirmative — success pulse and "in sync", reusing moss since the
    /// system has no green (ho-06.4 Decision 1).
    static var inSync: Color { Theme.accent.color }

    /// Primary text.
    static var ink: Color { Theme.ink.color }

    /// Secondary facts — the `.secondary` replacement.
    static var inkSecondary: Color { Theme.inkSecondary.color }

    /// The faintest hints — the `.tertiary` replacement.
    static var inkTertiary: Color { Theme.inkTertiary.color }

    /// Warm paper ground (defined for the panel ho, 06.5).
    static var ground: Color { Theme.ground.color }

    /// A shade off ground — headers and chips (panel ho).
    static var groundDeep: Color { Theme.groundDeep.color }

    /// The cooler data surface — the panel ho's primary surface.
    static var panelGround: Color { Theme.panelGround.color }
}
