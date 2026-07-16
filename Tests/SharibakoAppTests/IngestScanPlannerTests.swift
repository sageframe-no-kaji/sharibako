import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// Tests for `IngestScanPlanner.plan` (`WorkshopModel+Ingest.swift`) — the
/// pure, off-main-actor-safe scan/reconcile logic `beginIngest` hands to
/// `VaultWorker`.
///
/// Entirely keyless (mirrors `Materializer.ingest` — no age key, no Touch
/// ID) so every fixture here is a plain temp vault + temp project
/// directory, no `AppAgeKeyFixture` needed.
@Suite("IngestScanPlanner")
struct IngestScanPlannerTests {
    /// Writes `contents` to `<directory>/<name>`, creating `directory` first.
    private static func writeEnv(
        _ contents: String, in directory: URL, named name: String = ".env"
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(
            to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Marks `key` as already owned by `scopeID` — a dummy `.age` file is
    /// enough, since `VaultCore.inspect` only reads filenames (keyless), the
    /// same shortcut `MaterializerAcceptIngestTests` and friends don't need
    /// because they go through `acceptIngest`; here we want an "already
    /// owned" fixture without spending a real encrypt.
    private static func markOwned(_ key: String, scopeID: String, vault: URL) throws {
        let scopeDir = vault.appendingPathComponent("scopes").appendingPathComponent(scopeID)
        try FileManager.default.createDirectory(at: scopeDir, withIntermediateDirectories: true)
        try "ciphertext".write(
            to: scopeDir.appendingPathComponent("\(key).age"), atomically: true, encoding: .utf8)
    }

    /// Marks `sharedID` as an existing shared entry — same keyless shortcut
    /// as ``markOwned(_:scopeID:vault:)``; `VaultCore.listShared` only reads
    /// filename stems.
    private static func markShared(_ sharedID: String, vault: URL) throws {
        let sharedDir = vault.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        try "ciphertext".write(
            to: sharedDir.appendingPathComponent("\(sharedID).age"), atomically: true, encoding: .utf8)
    }

    private static func writeMarker(scope: String, in project: URL) throws {
        try "scope: \(scope)\n".write(
            to: project.appendingPathComponent(".sharibako"), atomically: true, encoding: .utf8)
    }

    // MARK: - Fresh ingest

    @Test("plan proposes a fresh session for a directory with a real .env value")
    func planFreshDirectory() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.withTempDirectory { root in
                let project = root.appendingPathComponent("bento")
                try Self.writeEnv("API_KEY=sk-live\n", in: project)
                let core = try VaultCore(vaultURL: vault)
                let materializer = Materializer(vaultCore: core, vaultURL: vault)

                let outcome = try IngestScanPlanner.plan(
                    materializer: materializer, vault: core, directory: project)

                guard case .session(let payload) = outcome else {
                    Issue.record("expected .session, got \(outcome)")
                    return
                }
                #expect(payload.proposal.detectedKeys.map(\.key) == ["API_KEY"])
                #expect(payload.scopeID == "bento")
                #expect(payload.isReconcile == false)
                #expect(payload.existingScopeIDs.isEmpty)
            }
        }
    }

    @Test("plan returns nothingToImport for a directory with no importable secrets")
    func planNothingToImport() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.withTempDirectory { root in
                let project = root.appendingPathComponent("empty-dir")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                let core = try VaultCore(vaultURL: vault)
                let materializer = Materializer(vaultCore: core, vaultURL: vault)

                let outcome = try IngestScanPlanner.plan(
                    materializer: materializer, vault: core, directory: project)

                #expect(outcome == .nothingToImport)
            }
        }
    }

    @Test("plan surfaces existing scope IDs for the collision banner")
    func planCapturesExistingScopeIDs() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.withTempDirectory { root in
                try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
                let project = root.appendingPathComponent("kanyo")
                try Self.writeEnv("DEBUG=true\n", in: project)
                let core = try VaultCore(vaultURL: vault)
                let materializer = Materializer(vaultCore: core, vaultURL: vault)

                let outcome = try IngestScanPlanner.plan(
                    materializer: materializer, vault: core, directory: project)

                guard case .session(let payload) = outcome else {
                    Issue.record("expected .session, got \(outcome)")
                    return
                }
                #expect(payload.existingScopeIDs.contains("kanyo-dev"))
            }
        }
    }

    @Test("plan surfaces existing shared entry IDs and the name-match hint")
    func planCapturesSharedIDs() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.withTempDirectory { root in
                // The name-match hint fires on an EXACT key/shared-ID string
                // match (`Materializer.ingest`'s own rule, confirmed by
                // `MaterializerIngestTests`) — "openai-personal" would not
                // match a detected key named "OPENAI_API_KEY".
                try Self.markShared("OPENAI_API_KEY", vault: vault)
                let project = root.appendingPathComponent("bento")
                try Self.writeEnv("OPENAI_API_KEY=sk-live\n", in: project)
                let core = try VaultCore(vaultURL: vault)
                let materializer = Materializer(vaultCore: core, vaultURL: vault)

                let outcome = try IngestScanPlanner.plan(
                    materializer: materializer, vault: core, directory: project)

                guard case .session(let payload) = outcome else {
                    Issue.record("expected .session, got \(outcome)")
                    return
                }
                #expect(payload.sharedIDs == ["OPENAI_API_KEY"])
                #expect(payload.proposal.detectedKeys.first?.nameMatchedSharedID == "OPENAI_API_KEY")
            }
        }
    }

    // MARK: - Reconcile

    @Test("plan filters to unowned keys on reconcile, fixing the scope ID to the marker's own")
    func planReconcileFiltersOwnedKeys() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.withTempDirectory { root in
                let project = root.appendingPathComponent("bento")
                try Self.writeEnv("API_KEY=sk-live\nNEW_KEY=fresh\n", in: project)
                try WorkshopTestSupport.writeScope("bento", type: .projectDev, in: vault)
                try Self.markOwned("API_KEY", scopeID: "bento", vault: vault)
                try Self.writeMarker(scope: "bento", in: project)
                let core = try VaultCore(vaultURL: vault)
                let materializer = Materializer(vaultCore: core, vaultURL: vault)

                let outcome = try IngestScanPlanner.plan(
                    materializer: materializer, vault: core, directory: project)

                guard case .session(let payload) = outcome else {
                    Issue.record("expected .session, got \(outcome)")
                    return
                }
                #expect(payload.proposal.detectedKeys.map(\.key) == ["NEW_KEY"])
                #expect(payload.scopeID == "bento")
                #expect(payload.isReconcile == true)
            }
        }
    }

    @Test("plan reports alreadyReconciled when every detected key is already owned")
    func planAlreadyReconciled() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.withTempDirectory { root in
                let project = root.appendingPathComponent("bento")
                try Self.writeEnv("API_KEY=sk-live\n", in: project)
                try WorkshopTestSupport.writeScope("bento", type: .projectDev, in: vault)
                try Self.markOwned("API_KEY", scopeID: "bento", vault: vault)
                try Self.writeMarker(scope: "bento", in: project)
                let core = try VaultCore(vaultURL: vault)
                let materializer = Materializer(vaultCore: core, vaultURL: vault)

                let outcome = try IngestScanPlanner.plan(
                    materializer: materializer, vault: core, directory: project)

                #expect(outcome == .alreadyReconciled(scopeID: "bento"))
            }
        }
    }

    @Test("plan falls back to the full proposal when a marker names a scope the vault has lost")
    func planReconcileFallsBackOnOrphanedMarker() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.withTempDirectory { root in
                let project = root.appendingPathComponent("bento")
                try Self.writeEnv("API_KEY=sk-live\n", in: project)
                // Marker names a scope the vault never created.
                try Self.writeMarker(scope: "bento", in: project)
                let core = try VaultCore(vaultURL: vault)
                let materializer = Materializer(vaultCore: core, vaultURL: vault)

                let outcome = try IngestScanPlanner.plan(
                    materializer: materializer, vault: core, directory: project)

                guard case .session(let payload) = outcome else {
                    Issue.record("expected .session, got \(outcome)")
                    return
                }
                #expect(payload.proposal.detectedKeys.map(\.key) == ["API_KEY"])
                #expect(payload.scopeID == "bento")
                #expect(payload.isReconcile == true)
            }
        }
    }
}
