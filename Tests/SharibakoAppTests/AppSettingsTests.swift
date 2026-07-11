import Foundation
import SwiftUI
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// ho-06.2 AT-03 tests: the appearance enum ↔ `ColorScheme?` mapping and the
/// read-only scan-root footer accessors.
///
/// Both are pure over injected state — the mapping needs no running scene, the
/// footer accessors read `scanRoots` + the injected `home` and never
/// `NSHomeDirectory()`. The `SettingsScene` view and the `Settings {}` wiring
/// are coverage-excluded (declarative, headless-undrivable) and verified at the
/// dogfood gate.
@Suite("App Appearance")
struct AppAppearanceTests {
    @Test("colorScheme maps system → nil, light → .light, dark → .dark")
    func colorSchemeMapping() {
        #expect(AppAppearance.system.colorScheme == nil)
        #expect(AppAppearance.light.colorScheme == .light)
        #expect(AppAppearance.dark.colorScheme == .dark)
    }

    @Test("every case has a label and round-trips through its rawValue")
    func labelsAndRawValues() {
        #expect(AppAppearance.allCases.count == 3)
        for appearance in AppAppearance.allCases {
            #expect(!appearance.label.isEmpty)
            #expect(AppAppearance(rawValue: appearance.rawValue) == appearance)
            #expect(appearance.id == appearance.rawValue)
        }
    }
}

/// Scan-root footer accessor tests (ho-06.2 AT-03 Decision 5).
@MainActor
@Suite("WorkshopModel ScanRootFooter")
struct WorkshopModelScanRootFooterTests {
    @Test("scanRootsShortDescription reads 'No scan root configured' when empty")
    func shortDescriptionEmpty() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": home.appendingPathComponent("absent").path],
                home: home
            )
            #expect(model.scanRoots.isEmpty)
            #expect(model.scanRootsShortDescription == "No scan root configured")
            #expect(model.scanRootsFullDescription == nil)
        }
    }

    @Test("scanRootsShortDescription abbreviates a single root under home with a tilde")
    func shortDescriptionSingleRootUnderHome() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": home.appendingPathComponent("absent").path],
                home: home
            )
            let root = home.appendingPathComponent("projects")
            model.scanRoots = [root]
            #expect(model.scanRootsShortDescription == "~/projects")
            #expect(model.scanRootsFullDescription == root.path)
        }
    }

    @Test("scanRootsShortDescription joins multiple roots; the tooltip lists every full path")
    func shortDescriptionMultipleRoots() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": home.appendingPathComponent("absent").path],
                home: home
            )
            let first = home.appendingPathComponent("code")
            let second = home.appendingPathComponent("work")
            model.scanRoots = [first, second]
            #expect(model.scanRootsShortDescription == "~/code, ~/work")
            #expect(model.scanRootsFullDescription == "\(first.path)\n\(second.path)")
        }
    }

    @Test("scanRootsShortDescription falls back to the full path for a root outside home")
    func shortDescriptionRootOutsideHome() throws {
        try WorkshopTestSupport.withTempDirectory { tempDir in
            let home = tempDir.appendingPathComponent("home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": home.appendingPathComponent("absent").path],
                home: home
            )
            let outside = tempDir.appendingPathComponent("elsewhere")
            model.scanRoots = [outside]
            #expect(model.scanRootsShortDescription == outside.path)
            #expect(model.scanRootsFullDescription == outside.path)
        }
    }
}
