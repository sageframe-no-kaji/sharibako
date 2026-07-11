import AppKit
import SwiftUI
import Testing

@testable import Sharibako

/// ho-06.4 tests: the semantic color-token layer.
///
/// The palette lives in a pure ``Palette/resolved(dark:)`` seam, so the values
/// are asserted directly (no running scene) and the dynamic `NSColor` provider
/// is exercised against real `.aqua` / `.darkAqua` appearances. Every value
/// below is ho-06.4 Decision 2 — the light half is pālana §2, the dark half the
/// warm-dark sibling set designed there.
@Suite("Color Theme")
struct ColorThemeTests {
    /// One row of the Decision 2 table: a token and its expected values.
    private struct Expected {
        let name: String
        let palette: Palette
        let light: RGBA
        let dark: RGBA
    }

    /// The whole Decision 2 table — light (pālana §2) and dark (designed here).
    private static let expected: [Expected] = [
        Expected(
            name: "accent",
            palette: Theme.accent,
            light: RGBA(red: 0.3529, green: 0.4588, blue: 0.3216, alpha: 1),
            dark: RGBA(red: 0.4941, green: 0.6078, blue: 0.4471, alpha: 1)),
        Expected(
            name: "alarm",
            palette: Theme.alarm,
            light: RGBA(red: 0.5961, green: 0.3020, blue: 0.2353, alpha: 1),
            dark: RGBA(red: 0.7725, green: 0.4196, blue: 0.3412, alpha: 1)),
        Expected(
            name: "inSync",
            palette: Theme.inSync,
            light: RGBA(red: 0.3686, green: 0.5412, blue: 0.3137, alpha: 1),
            dark: RGBA(red: 0.5216, green: 0.7451, blue: 0.4510, alpha: 1)),
        Expected(
            name: "ink",
            palette: Theme.ink,
            light: RGBA(red: 0.1137, green: 0.1059, blue: 0.0941, alpha: 1),
            dark: RGBA(red: 0.9255, green: 0.9059, blue: 0.8745, alpha: 1)),
        Expected(
            name: "inkSecondary",
            palette: Theme.inkSecondary,
            light: RGBA(red: 0.1137, green: 0.1059, blue: 0.0941, alpha: 0.55),
            dark: RGBA(red: 0.9255, green: 0.9059, blue: 0.8745, alpha: 0.60)),
        Expected(
            name: "inkTertiary",
            palette: Theme.inkTertiary,
            light: RGBA(red: 0.1137, green: 0.1059, blue: 0.0941, alpha: 0.35),
            dark: RGBA(red: 0.9255, green: 0.9059, blue: 0.8745, alpha: 0.40)),
        Expected(
            name: "ground",
            palette: Theme.ground,
            light: RGBA(red: 0.9804, green: 0.9686, blue: 0.9529, alpha: 1),
            dark: RGBA(red: 0.1059, green: 0.1020, blue: 0.0902, alpha: 1)),
        Expected(
            name: "groundDeep",
            palette: Theme.groundDeep,
            light: RGBA(red: 0.9569, green: 0.9451, blue: 0.9176, alpha: 1),
            dark: RGBA(red: 0.1412, green: 0.1333, blue: 0.1176, alpha: 1)),
        Expected(
            name: "panelGround",
            palette: Theme.panelGround,
            light: RGBA(red: 0.9294, green: 0.9333, blue: 0.9451, alpha: 1),
            dark: RGBA(red: 0.1255, green: 0.1333, blue: 0.1647, alpha: 1)),
    ]

    @Test("every token resolves to its Decision 2 light and dark values")
    func resolvedValues() {
        for entry in Self.expected {
            #expect(entry.palette.resolved(dark: false) == entry.light, "\(entry.name) light")
            #expect(entry.palette.resolved(dark: true) == entry.dark, "\(entry.name) dark")
        }
    }

    @MainActor
    @Test("the dynamic NSColor switches between light and dark by appearance")
    func dynamicColorResolvesByAppearance() throws {
        for entry in Self.expected {
            for isDark in [false, true] {
                let got = try Self.resolveComponents(entry.palette, dark: isDark)
                let want = entry.palette.resolved(dark: isDark)
                #expect(abs(got.red - want.red) < 0.01, "\(entry.name) red (dark=\(isDark))")
                #expect(abs(got.green - want.green) < 0.01, "\(entry.name) green (dark=\(isDark))")
                #expect(abs(got.blue - want.blue) < 0.01, "\(entry.name) blue (dark=\(isDark))")
                #expect(abs(got.alpha - want.alpha) < 0.01, "\(entry.name) alpha (dark=\(isDark))")
            }
        }
    }

    @MainActor
    @Test("Color statics are wired; inSync is its own moss, distinct from accent (Decision 1)")
    func colorStaticsAreWired() throws {
        // Touch every semantic token so the `Color` extension is exercised.
        let all: [Color] = [
            .accentMoss, .drift, .inSync, .ink, .inkSecondary, .inkTertiary,
            .ground, .groundDeep, .panelGround,
        ]
        #expect(all.count == 9)

        let sync = try #require(NSColor(Color.inSync).usingColorSpace(.sRGB))
        let moss = try #require(NSColor(Color.accentMoss).usingColorSpace(.sRGB))
        // Both stay in the moss family (green-dominant) — the affirmative is not
        // a rust/alarm hue, and a red/blue mis-wiring would be caught.
        #expect(sync.greenComponent > sync.redComponent)
        #expect(sync.greenComponent > sync.blueComponent)
        #expect(moss.greenComponent > moss.redComponent)
        #expect(moss.greenComponent > moss.blueComponent)
        // inSync is its own tuned tone (a cleaner/brighter moss for the status
        // wash), NOT the raw accent — it must be brighter (higher green).
        #expect(sync.greenComponent > moss.greenComponent)
    }

    /// Resolves a palette's dynamic `NSColor` under a concrete appearance and
    /// returns its sRGB components — the seam that proves the provider closure
    /// picks the right half.
    @MainActor
    private static func resolveComponents(_ palette: Palette, dark: Bool) throws -> RGBA {
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = palette.nsColor.usingColorSpace(.sRGB)
        }
        let color = try #require(resolved)
        return RGBA(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent),
            alpha: Double(color.alphaComponent))
    }
}
