import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// Seeds a project directory holding a `.sharibako` marker for `scope` under
/// `root`, and returns the project directory.
///
/// Shared by `WorkshopModelWaymarkingTests` and
/// `WorkshopModelJumpAndAnnounceTests` (`WorkshopModelJumpAndAnnounceTests.swift`);
/// mirrors `WorkshopModelConcurrencyTests.seedMarker`. `internal` (not
/// `private`) so both files' `@Suite` structs can call it — Swift's `private`
/// is file-scoped even within one test target.
func seedWaymarkingMarker(
    scope: String,
    materializeTo: String = ".env",
    under root: URL,
    named dirName: String = "project"
) throws -> URL {
    let projectDir = root.appendingPathComponent(dirName)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let markerContent = "scope: \(scope)\nmaterialize_to: \(materializeTo)\n"
    try markerContent.write(
        to: projectDir.appendingPathComponent(".sharibako"),
        atomically: true,
        encoding: .utf8
    )
    return projectDir
}

/// ho-06.1 AT-02 waymarking tests: sidebar footer (vault + remote) and the
/// detail pane's marker-target read.
///
/// Jump-to-directory and the creation announces live in
/// `WorkshopModelJumpAndAnnounceTests` (`WorkshopModelJumpAndAnnounceTests.swift`)
/// — split to keep each suite under SwiftLint's `type_body_length` ceiling.
///
/// All fixtures inject temp homes/roots/vaults — no live user state, no
/// Keychain, no signing (file-key path throughout), matching the
/// `WorkshopModel Concurrency` suite's fixture discipline.
@MainActor
@Suite("WorkshopModel Waymarking")
struct WorkshopModelWaymarkingTests {
    // MARK: - Vault directory description

    @Test("vaultDirectoryShortDescription abbreviates a path under home with a tilde")
    func vaultDirectoryShortDescriptionAbbreviates() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let vault = home.appendingPathComponent(".sharibako").appendingPathComponent("vault")
            try FileManager.default.createDirectory(
                at: vault.appendingPathComponent("scopes"), withIntermediateDirectories: true)
            let model = WorkshopModel(environment: [:], home: home)
            #expect(model.vaultDirectoryShortDescription == "~/.sharibako/vault")
            #expect(model.vaultDirectoryFullDescription == vault.path)
        }
    }

    @Test("vaultDirectoryShortDescription falls back to the full path outside home")
    func vaultDirectoryShortDescriptionOutsideHome() throws {
        try WorkshopTestSupport.withTempDirectory { tempDir in
            let home = tempDir.appendingPathComponent("home")
            let vault = tempDir.appendingPathComponent("elsewhere").appendingPathComponent("vault")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: vault.appendingPathComponent("scopes"), withIntermediateDirectories: true)
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: home
            )
            #expect(model.vaultDirectoryShortDescription == vault.path)
        }
    }

    @Test("vaultDirectoryShortDescription is nil in the .noVault state")
    func vaultDirectoryShortDescriptionNilWhenNoVault() throws {
        try WorkshopTestSupport.withTempDirectory { tempDir in
            let absent = tempDir.appendingPathComponent("nope")
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": absent.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            #expect(model.vaultDirectoryShortDescription == nil)
            #expect(model.vaultDirectoryFullDescription == nil)
        }
    }

    // MARK: - Remote description

    @Test("remoteShortDescription is nil before the launch scan resolves it")
    func remoteDescriptionNilBeforeResolution() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            #expect(model.remoteShortDescription == nil)
            #expect(model.remoteFullDescription == nil)
        }
    }

    @Test("performLaunchScan resolves remoteShortDescription to 'No remote' for a vault with no git")
    func remoteDescriptionNoneForNonGitVault() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            await model.performLaunchScan()
            #expect(model.remoteShortDescription == "No remote")
            #expect(model.remoteFullDescription == "No remote configured")
        }
    }

    @Test("performLaunchScan resolves remoteShortDescription to the configured origin URL")
    func remoteDescriptionConfigured() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            try conduit.initializeRepository()
            try conduit.setRemote("https://example.invalid/sharibako-vault.git")

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            await model.performLaunchScan()
            #expect(model.remoteShortDescription == "https://example.invalid/sharibako-vault.git")
            #expect(model.remoteFullDescription == "https://example.invalid/sharibako-vault.git")
        }
    }

    @Test("performLaunchScan resolves the remote even with no scan roots configured")
    func remoteDescriptionResolvesWithoutScanRoots() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            #expect(model.scanRoots.isEmpty)
            await model.performLaunchScan()
            // The remote resolution has nothing to do with scan roots — it must
            // still resolve even when there is nothing to scan.
            #expect(model.remoteShortDescription == "No remote")
            #expect(model.scanReport == nil)
        }
    }

    @Test("performLaunchScan resolves the remote exactly once, not on every call")
    func remoteDescriptionResolvesOnce() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let conduit = try Conduit(vaultURL: vault)
            try conduit.initializeRepository()
            try conduit.setRemote("https://example.invalid/first.git")

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            await model.performLaunchScan()
            #expect(model.remoteShortDescription == "https://example.invalid/first.git")

            // Remote changes after the first resolution — a second launch-scan
            // call (as if the .task fired again) must not re-shell for it.
            try conduit.setRemote("https://example.invalid/second.git")
            await model.performLaunchScan()
            #expect(model.remoteShortDescription == "https://example.invalid/first.git")
        }
    }

    // MARK: - Marker target description (detail pane)

    @Test("markerTargetDescription is .notScanned before any scan runs")
    func markerTargetNotScanned() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            #expect(model.markerTargetDescription(forScope: "kanyo-dev") == .notScanned)
        }
    }

    @Test("markerTargetDescription is .notFound on a warm-cache miss")
    func markerTargetNotFound() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let root = vault.deletingLastPathComponent().appendingPathComponent(
                "roots-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            // No marker seeded — the scan will run and find nothing.

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.scanRoots = [root]
            await model.performLaunchScan()
            #expect(model.scanReport != nil)
            #expect(model.markerTargetDescription(forScope: "kanyo-dev") == .notFound)
        }
    }

    @Test("markerTargetDescription is .found with the marker directory and target on a cache hit")
    func markerTargetFound() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let root = vault.deletingLastPathComponent().appendingPathComponent(
                "roots-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let projectDir = try seedWaymarkingMarker(scope: "kanyo-dev", under: root)

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.scanRoots = [root]
            await model.performLaunchScan()

            guard
                case .found(let markerDirectory, let targetURL) = model.markerTargetDescription(
                    forScope: "kanyo-dev")
            else {
                Issue.record("Expected .found, got \(model.markerTargetDescription(forScope: "kanyo-dev"))")
                return
            }
            // Compare standardized paths: the scan resolves URLs through
            // `.standardizedFileURL` (`Materializer+Scan`), which on macOS
            // also resolves the `/var` → `/private/var` temp-directory
            // symlink — the raw `projectDir` built from
            // `FileManager.default.temporaryDirectory` has not gone through
            // that resolution. `.env` does not exist on disk yet, so it is
            // derived from the already-resolved `markerDirectory` rather than
            // re-appended to the unresolved `projectDir` (`.standardizedFileURL`
            // only resolves symlinks for path components that exist).
            #expect(markerDirectory.standardizedFileURL.path == projectDir.standardizedFileURL.path)
            #expect(targetURL.path == markerDirectory.appendingPathComponent(".env").path)
        }
    }
}
