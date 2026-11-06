import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// Tests for the GUI ingest flow's session lifecycle (ho-06.3 AT-02,
/// `WorkshopModel+Ingest.swift`) — `beginIngest`, the decision/scope-editing
/// intents, `cancelIngest`, and `IngestSession.isScopeCollision`.
///
/// See `WorkshopModelIngestCommitTests.swift` for `commitIngest` and the
/// first-run wizard's hand-off (split the way the first-run suite is split
/// across `WorkshopModelFirstRunTests`/`WorkshopModelFirstRunBackupRootTests`/
/// `WorkshopModelFirstRunCompletionTests` — SwiftLint's `type_body_length`
/// ceiling, not a change in ownership). All fixtures inject temp
/// vaults/roots — no live user state, no Keychain, no signing.
@MainActor
@Suite("WorkshopModel+Ingest")
struct WorkshopModelIngestTests {
    /// Writes `contents` to `<directory>/<name>`, creating `directory` first.
    ///
    /// Mirrored in `WorkshopModelIngestCommitTests.swift` — the
    /// `WorkshopModelPreviewTests`/`WorkshopModelConcurrencyTests`
    /// per-file-helper precedent.
    private static func writeEnv(
        _ contents: String, in directory: URL, named name: String = ".env"
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(
            to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // MARK: - IngestSession.isScopeCollision (pure)

    @Test("isScopeCollision fires only for a fresh ingest whose scope ID already exists")
    func isScopeCollisionRules() {
        let base = WorkshopModel.IngestSession(
            directory: URL(fileURLWithPath: "/tmp/project"),
            proposal: ProposedScope(
                directory: URL(fileURLWithPath: "/tmp/project"),
                suggestedScopeID: "bento",
                suggestedScopeType: .projectDev,
                detectedKeys: [],
                suggestedKeysNeedingValues: [],
                parseWarnings: []
            ),
            decisions: [:],
            scopeID: "bento",
            scopeType: .projectDev,
            isReconcile: false,
            sharedIDs: [],
            existingScopeIDs: ["bento"]
        )
        #expect(base.isScopeCollision == true)

        let reconcileSession = WorkshopModel.IngestSession(
            directory: base.directory,
            proposal: base.proposal,
            decisions: [:],
            scopeID: "bento",
            scopeType: .projectDev,
            isReconcile: true,
            sharedIDs: [],
            existingScopeIDs: ["bento"]
        )
        #expect(reconcileSession.isScopeCollision == false)

        var noCollision = base
        noCollision.scopeID = "brand-new"
        #expect(noCollision.isScopeCollision == false)
    }

    // MARK: - beginIngest

    @Test("beginIngest opens a session with every key defaulted to importAsLocal")
    func beginIngestOpensSession() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = vault.deletingLastPathComponent().appendingPathComponent(
                "roots-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let project = root.appendingPathComponent("bento")
            try Self.writeEnv("API_KEY=sk-live\n", in: project)

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )

            await model.beginIngest(directory: project)

            #expect(model.ingest.session?.scopeID == "bento")
            #expect(model.ingest.session?.decisions["API_KEY"] == .importAsLocal(key: "API_KEY"))
            #expect(model.ingest.session?.isReconcile == false)
            #expect(model.activity == nil)
            #expect(model.errorMessage == nil)
        }
    }

    @Test("beginIngest announces plainly and opens no sheet for a directory with nothing to import")
    func beginIngestNothingToImport() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = vault.deletingLastPathComponent().appendingPathComponent(
                "roots-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let project = root.appendingPathComponent("empty")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )

            await model.beginIngest(directory: project)

            #expect(model.ingest.session == nil)
            #expect(model.statusMessage?.contains("No secrets found to import") == true)
        }
    }

    @Test("beginIngest announces already-reconciled and opens no sheet when nothing new")
    func beginIngestAlreadyReconciled() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("bento", type: .projectDev, in: vault)
            let scopeDir = vault.appendingPathComponent("scopes").appendingPathComponent("bento")
            try "ciphertext".write(
                to: scopeDir.appendingPathComponent("API_KEY.age"), atomically: true, encoding: .utf8)

            let root = vault.deletingLastPathComponent().appendingPathComponent(
                "roots-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let project = root.appendingPathComponent("bento")
            try Self.writeEnv("API_KEY=sk-live\n", in: project)
            try "scope: bento\n".write(
                to: project.appendingPathComponent(".sharibako"), atomically: true, encoding: .utf8)

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )

            await model.beginIngest(directory: project)

            #expect(model.ingest.session == nil)
            #expect(model.statusMessage?.contains("No new secrets to reconcile") == true)
        }
    }

    @Test("beginIngest is a no-op while another activity is in flight")
    func beginIngestReentryGuard() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = vault.deletingLastPathComponent().appendingPathComponent(
                "roots-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let project = root.appendingPathComponent("bento")
            try Self.writeEnv("API_KEY=sk-live\n", in: project)

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.activity = .syncing

            await model.beginIngest(directory: project)

            #expect(model.ingest.session == nil)
        }
    }

    @Test("beginIngest is a no-op in the .noVault state")
    func beginIngestNoOpWithoutVault() async throws {
        try await WorkshopTestSupport.withTempDirectory { tempDir in
            let absent = tempDir.appendingPathComponent("nope")
            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": absent.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )

            await model.beginIngest(directory: tempDir)

            #expect(model.ingest.session == nil)
        }
    }

    // MARK: - Decision + scope editing

    @Test("setIngestDecision/setIngestScopeID/setIngestScopeType mutate the active session")
    func decisionAndScopeEditingIntents() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = vault.deletingLastPathComponent().appendingPathComponent(
                "roots-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let project = root.appendingPathComponent("bento")
            try Self.writeEnv("API_KEY=sk-live\n", in: project)

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            await model.beginIngest(directory: project)

            model.setIngestDecision(.skip(key: "API_KEY"), forKey: "API_KEY")
            #expect(model.ingest.session?.decisions["API_KEY"] == .skip(key: "API_KEY"))

            model.setIngestScopeID("renamed-scope")
            #expect(model.ingest.session?.scopeID == "renamed-scope")

            model.setIngestScopeType(.service)
            #expect(model.ingest.session?.scopeType == .service)
        }
    }

    @Test("cancelIngest discards the session and any pending error")
    func cancelIngestDiscards() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = vault.deletingLastPathComponent().appendingPathComponent(
                "roots-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let project = root.appendingPathComponent("bento")
            try Self.writeEnv("API_KEY=sk-live\n", in: project)

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            await model.beginIngest(directory: project)
            model.ingest.errorMessage = "stale error"

            model.cancelIngest()

            #expect(model.ingest.session == nil)
            #expect(model.ingest.errorMessage == nil)
        }
    }
}
