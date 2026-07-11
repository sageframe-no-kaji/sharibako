import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// ho-06.1 AT-03 tests: the "Preview .env" intent (`WorkshopModel+Preview.swift`).
///
/// All fixtures inject temp homes/roots/vaults and the file-key dev path —
/// no live user state, no Keychain, no signing, matching the `WorkshopModel
/// Concurrency` suite's fixture discipline.
@MainActor
@Suite("WorkshopModel Preview")
struct WorkshopModelPreviewTests {
    /// Seeds a project directory holding a `.sharibako` marker for `scope`.
    ///
    /// Returns the project directory. Mirrors the helper in
    /// `WorkshopModelConcurrencyTests`.
    private static func seedMarker(
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

    @Test("previewEnv renders the composed .env and stores it in envPreview without writing")
    func previewEnvRendersWithoutWriting() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                try core.addSecret("DB", value: "postgres://x", inScope: "kanyo-dev")

                let root = vault.deletingLastPathComponent().appendingPathComponent(
                    "roots-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let projectDir = try Self.seedMarker(scope: "kanyo-dev", under: root)

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.scanRoots = [root]
                model.selectedScopeID = "kanyo-dev"
                await model.performLaunchScan()

                await model.previewEnv()

                #expect(model.envPreview?.scopeID == "kanyo-dev")
                #expect(model.envPreview?.content.contains("DB=postgres://x") == true)
                #expect(
                    model.envPreview?.targetURL.standardizedFileURL.path
                        == projectDir.appendingPathComponent(".env").standardizedFileURL.path)
                #expect(model.errorMessage == nil)
                #expect(model.activity == nil)
                // No write — the file must not exist on disk.
                #expect(
                    !FileManager.default.fileExists(
                        atPath: projectDir.appendingPathComponent(".env").path))
            }
        }
    }

    @Test("previewEnv on a cold cache falls back to one fresh scan (miss-fallback)")
    func previewEnvMissFallbackScansOnce() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                try core.addSecret("DB", value: "postgres://x", inScope: "kanyo-dev")

                let root = vault.deletingLastPathComponent().appendingPathComponent(
                    "roots-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                _ = try Self.seedMarker(scope: "kanyo-dev", under: root)

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.scanRoots = [root]
                model.selectedScopeID = "kanyo-dev"

                #expect(model.scanReport == nil)
                await model.previewEnv()

                #expect(model.errorMessage == nil)
                #expect(model.scanReport != nil)
                #expect(model.envPreview?.content.contains("DB=postgres://x") == true)
            }
        }
    }

    @Test("previewEnv surfaces marker-not-found when the fallback scan finds none")
    func previewEnvMissFallbackErrorsWhenAbsent() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
                let root = vault.deletingLastPathComponent().appendingPathComponent(
                    "roots-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                // No marker under the root at all.

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.scanRoots = [root]
                model.selectedScopeID = "kanyo-dev"

                await model.previewEnv()

                #expect(model.errorMessage != nil)
                #expect(model.envPreview == nil)
                #expect(model.activity == nil)
            }
        }
    }

    @Test("previewEnv is a no-op with no scope selected")
    func previewEnvNoOpWithoutSelection() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            #expect(model.selectedScopeID == nil)
            await model.previewEnv()
            #expect(model.envPreview == nil)
            #expect(model.errorMessage == nil)
        }
    }

    @Test("previewEnv surfaces 'Could not load age key' when the dev key file is missing")
    func previewEnvMissingAgeKey() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let model = WorkshopModel(
                environment: [
                    "SHARIBAKO_VAULT": vault.path,
                    "SHARIBAKO_AGE_KEY": "/nonexistent/dev-key.txt",
                ],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.selectedScopeID = "kanyo-dev"
            await model.previewEnv()
            #expect(model.errorMessage?.hasPrefix("Could not load age key") == true)
            #expect(model.envPreview == nil)
            #expect(model.activity == nil)
        }
    }

    @Test("the re-entry guard no-ops previewEnv while activity is non-nil")
    func reEntryGuardNoOpsPreview() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                try core.addSecret("DB", value: "postgres://x", inScope: "kanyo-dev")

                let root = vault.deletingLastPathComponent().appendingPathComponent(
                    "roots-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                _ = try Self.seedMarker(scope: "kanyo-dev", under: root)

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.scanRoots = [root]
                model.selectedScopeID = "kanyo-dev"
                await model.performLaunchScan()

                // A gate the worker's first submitted closure blocks on, so the
                // first preview is provably in flight when the second call runs.
                let gate = DispatchSemaphore(value: 0)
                let entered = DispatchSemaphore(value: 0)
                let blocker = model.worker
                let hold = Task.detached {
                    await blocker.run {
                        entered.signal()
                        gate.wait()
                    }
                }
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        entered.wait()
                        continuation.resume()
                    }
                }

                let first = Task { await model.previewEnv() }
                while model.activity == nil { await Task.yield() }
                #expect(model.activity == .materializing)

                // Second call while activity is non-nil: the guard no-ops it.
                await model.previewEnv()
                #expect(model.envPreview == nil)

                gate.signal()
                _ = await hold.value
                await first.value
                #expect(model.activity == nil)
                #expect(model.envPreview != nil)
            }
        }
    }

    @Test("dismissEnvPreview clears envPreview")
    func dismissEnvPreviewClears() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                try core.addSecret("DB", value: "postgres://x", inScope: "kanyo-dev")

                let root = vault.deletingLastPathComponent().appendingPathComponent(
                    "roots-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                _ = try Self.seedMarker(scope: "kanyo-dev", under: root)

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.scanRoots = [root]
                model.selectedScopeID = "kanyo-dev"
                await model.performLaunchScan()
                await model.previewEnv()
                #expect(model.envPreview != nil)

                model.dismissEnvPreview()
                #expect(model.envPreview == nil)
            }
        }
    }

    // MARK: - previewDisabledReason

    @Test("previewDisabledReason names 'select a scope' with no selection")
    func previewDisabledReasonNoSelection() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            #expect(model.previewDisabledReason?.contains("Select a scope") == true)
        }
    }

    @Test("previewDisabledReason names 'not scanned yet' before any scan")
    func previewDisabledReasonNotScanned() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.selectedScopeID = "kanyo-dev"
            #expect(model.previewDisabledReason?.contains("Not scanned yet") == true)
        }
    }

    @Test("previewDisabledReason names 'no marker found' on a warm-cache miss")
    func previewDisabledReasonNotFound() async throws {
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
            #expect(model.previewDisabledReason?.contains("No marker found") == true)
        }
    }

    @Test("previewDisabledReason is nil on a cache hit — the button is enabled")
    func previewDisabledReasonNilOnHit() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let root = vault.deletingLastPathComponent().appendingPathComponent(
                "roots-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try Self.seedMarker(scope: "kanyo-dev", under: root)

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.scanRoots = [root]
            model.selectedScopeID = "kanyo-dev"
            await model.performLaunchScan()
            #expect(model.previewDisabledReason == nil)
        }
    }
}
