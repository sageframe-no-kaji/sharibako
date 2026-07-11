import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// ho-06.1 AT-02 tests: jump-to-directory's target/disabled-reason/announce,
/// and the three creation announces (Decision 6).
///
/// Split from `WorkshopModelWaymarkingTests` (`WorkshopModelWaymarkingTests.swift`,
/// which holds the sidebar footer and marker-target-description tests) to
/// keep each suite under SwiftLint's `type_body_length` ceiling. Shares the
/// `seedWaymarkingMarker` fixture helper declared in that file.
///
/// All fixtures inject temp homes/roots/vaults — no live user state, no
/// Keychain, no signing (file-key path throughout), matching the
/// `WorkshopModel Concurrency` suite's fixture discipline.
@MainActor
@Suite("WorkshopModel Jump and Announce")
struct WorkshopModelJumpAndAnnounceTests {
    // MARK: - Jump-to-directory

    @Test("jumpTargetDirectory is nil with no selection or a cold/miss cache")
    func jumpTargetDirectoryNilCases() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            #expect(model.jumpTargetDirectory(forScope: "kanyo-dev") == nil)
        }
    }

    @Test("jumpTargetDirectory resolves the marker's own directory on a cache hit")
    func jumpTargetDirectoryFound() async throws {
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
            // Standardized comparison — the scan resolves URLs through
            // `.standardizedFileURL` (`Materializer+Scan`), which on macOS also
            // resolves the `/var` → `/private/var` temp-directory symlink; the
            // raw `projectDir` has not gone through that resolution.
            #expect(
                model.jumpTargetDirectory(forScope: "kanyo-dev")?.standardizedFileURL.path
                    == projectDir.standardizedFileURL.path)
        }
    }

    @Test("jumpDisabledReason names 'select a scope' with no selection")
    func jumpDisabledReasonNoSelection() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            #expect(model.selectedScopeID == nil)
            #expect(model.jumpDisabledReason?.contains("Select a scope") == true)
        }
    }

    @Test("jumpDisabledReason names 'not scanned yet' before any scan")
    func jumpDisabledReasonNotScanned() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.selectedScopeID = "kanyo-dev"
            #expect(model.jumpDisabledReason?.contains("Not scanned yet") == true)
        }
    }

    @Test("jumpDisabledReason names 'no marker found' on a warm-cache miss")
    func jumpDisabledReasonNotFound() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let root = vault.deletingLastPathComponent().appendingPathComponent(
                "roots-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.scanRoots = [root]
            model.selectedScopeID = "kanyo-dev"
            await model.performLaunchScan()
            #expect(model.jumpDisabledReason?.contains("No marker found") == true)
        }
    }

    @Test("jumpDisabledReason is nil on a cache hit — the button is enabled")
    func jumpDisabledReasonNilOnHit() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let root = vault.deletingLastPathComponent().appendingPathComponent(
                "roots-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try seedWaymarkingMarker(scope: "kanyo-dev", under: root)

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.scanRoots = [root]
            model.selectedScopeID = "kanyo-dev"
            await model.performLaunchScan()
            #expect(model.jumpDisabledReason == nil)
        }
    }

    @Test("announceJump sets statusMessage naming the opened path and clears errorMessage")
    func announceJumpSetsStatusMessage() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.errorMessage = "stale"
            let directory = URL(fileURLWithPath: "/tmp/some-project")
            model.announceJump(to: directory)
            #expect(model.statusMessage == "Opened /tmp/some-project in Finder.")
            #expect(model.errorMessage == nil)
        }
    }

    // MARK: - Creation announces (Decision 6)

    @Test("addScope announces 'Created scope <id>.'")
    func addScopeAnnounces() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.addScope(id: "new-project", type: .projectDev, displayName: nil)
            #expect(model.statusMessage == "Created scope new-project.")
        }
    }

    @Test("addSecret announces 'Added <key> to <scope>.'")
    func addSecretAnnounces() throws {
        try AppAgeKeyFixture.withEphemeralKey { fixture in
            try WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.addSecret(
                    key: "DATABASE_URL", value: "postgres://test", notes: nil, inScope: "kanyo-dev")
                #expect(model.statusMessage == "Added DATABASE_URL to kanyo-dev.")
            }
        }
    }

    @Test("addSharedEntry announces 'Created shared entry <id>.'")
    func addSharedEntryAnnounces() throws {
        try AppAgeKeyFixture.withEphemeralKey { fixture in
            try WorkshopTestSupport.withTempVault { vault in
                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.addSharedEntry(id: "openai-personal", value: "sk-test", notes: nil)
                #expect(model.statusMessage == "Created shared entry openai-personal.")
            }
        }
    }

    @Test("Creation announces do not fire on failure")
    func creationAnnouncesDoNotFireOnFailure() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("alpha", type: .other, in: vault)
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.addScope(id: "alpha", type: .service, displayName: nil)
            #expect(model.errorMessage != nil)
            #expect(model.statusMessage == nil)
        }
    }
}
