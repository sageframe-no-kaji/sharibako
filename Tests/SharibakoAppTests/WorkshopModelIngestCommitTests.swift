import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// Tests for `commitIngest()` and the first-run wizard's hand-off
/// (`offerFirstRunIngestInvite`/`findFirstRunIngestCandidates`) — ho-06.3
/// AT-02, `WorkshopModel+Ingest.swift`.
///
/// See `WorkshopModelIngestTests.swift` for `beginIngest`, the
/// decision/scope-editing intents, and `cancelIngest` (the split is
/// SwiftLint's `type_body_length` ceiling, not a change in ownership).
/// Commit-path fixtures encrypt, so they follow the existing
/// encryption-test convention (`AppAgeKeyFixture`, `age`/`age-keygen` on
/// PATH) — no live user state, no Keychain, no signing.
@MainActor
@Suite("WorkshopModel+Ingest Commit")
struct WorkshopModelIngestCommitTests {
    /// Writes `contents` to `<directory>/<name>`, creating `directory`
    /// first — mirrors `WorkshopModelIngestTests.writeEnv`.
    private static func writeEnv(
        _ contents: String, in directory: URL, named name: String = ".env"
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(
            to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // MARK: - commitIngest

    @Test("commitIngest encrypts, writes the marker, selects the scope, and announces the summary")
    func commitIngestSucceeds() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                let root = vault.deletingLastPathComponent().appendingPathComponent(
                    "roots-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let project = root.appendingPathComponent("bento")
                try Self.writeEnv("API_KEY=sk-live\nDEBUG=true\n", in: project)

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.scanRoots = [root]
                await model.beginIngest(directory: project)
                model.setIngestDecision(.leaveAlone(key: "DEBUG"), forKey: "DEBUG")

                await model.commitIngest()

                #expect(model.ingest.session == nil)
                #expect(model.ingest.errorMessage == nil)
                #expect(model.selectedScopeID == "bento")
                #expect(model.scopes.map(\.identity).contains("bento"))
                #expect(
                    FileManager.default.fileExists(
                        atPath: project.appendingPathComponent(".sharibako").path))
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                #expect(try core.getValue("API_KEY", inScope: "bento") == "sk-live")
                #expect(try core.inspect("bento").map(\.key) == ["API_KEY"])
                #expect(model.statusMessage?.contains("Imported 1") == true)
                #expect(model.statusMessage?.contains("left alone 1") == true)
                #expect(model.scanReport?.markers.contains { $0.scope == "bento" } == true)
            }
        }
    }

    @Test("commitIngest rejects an invalid scope ID and keeps the session")
    func commitIngestRejectsInvalidScopeID() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                let root = vault.deletingLastPathComponent().appendingPathComponent(
                    "roots-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let project = root.appendingPathComponent("bento")
                try Self.writeEnv("API_KEY=sk-live\n", in: project)

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                await model.beginIngest(directory: project)
                model.setIngestScopeID("has a space")

                await model.commitIngest()

                #expect(model.ingest.session != nil)
                #expect(model.ingest.errorMessage?.contains("Invalid scope ID") == true)
            }
        }
    }

    @Test("commitIngest surfaces an underlying VaultError and keeps the session")
    func commitIngestSurfacesVaultError() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                let root = vault.deletingLastPathComponent().appendingPathComponent(
                    "roots-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let project = root.appendingPathComponent("bento")
                try Self.writeEnv("API_KEY=sk-live\n", in: project)

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                await model.beginIngest(directory: project)
                // Points at a shared entry the vault does not have.
                model.setIngestDecision(
                    .linkToShared(key: "API_KEY", sharedID: "ghost"), forKey: "API_KEY")

                await model.commitIngest()

                #expect(model.ingest.session != nil)
                #expect(model.ingest.errorMessage != nil)
                #expect(model.selectedScopeID == nil)
            }
        }
    }

    @Test("commitIngest surfaces a missing dev age key without losing the session")
    func commitIngestMissingAgeKey() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = vault.deletingLastPathComponent().appendingPathComponent(
                "roots-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let project = root.appendingPathComponent("bento")
            try Self.writeEnv("API_KEY=sk-live\n", in: project)

            let model = WorkshopModel(
                environment: [
                    "SHARIBAKO_VAULT": vault.path,
                    "SHARIBAKO_AGE_KEY": "/nonexistent/dev-key.txt",
                ],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            await model.beginIngest(directory: project)

            await model.commitIngest()

            #expect(model.ingest.session != nil)
            #expect(model.ingest.errorMessage?.hasPrefix("Could not load age key") == true)
        }
    }

    @Test("commitIngest is a no-op without an active session")
    func commitIngestNoOpWithoutSession() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )

                await model.commitIngest()

                #expect(model.activity == nil)
                #expect(model.ingest.errorMessage == nil)
            }
        }
    }

    // MARK: - Wizard hand-off

    @Test("findFirstRunIngestCandidates returns .env-bearing directories under root")
    func findFirstRunIngestCandidatesFindsDirectories() async throws {
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

            let found = await model.findFirstRunIngestCandidates(under: root)

            #expect(found.map(\.lastPathComponent) == ["bento"])
        }
    }

    @Test("offerFirstRunIngestInvite opens the ingest sheet on the first candidate")
    func offerFirstRunIngestInviteOpensSheet() async throws {
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

            await model.offerFirstRunIngestInvite(under: root)

            #expect(
                model.ingest.session?.directory.standardizedFileURL.path
                    == project.standardizedFileURL.path)
        }
    }

    @Test("offerFirstRunIngestInvite does nothing when no candidates exist")
    func offerFirstRunIngestInviteNoCandidates() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = vault.deletingLastPathComponent().appendingPathComponent(
                "roots-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )

            await model.offerFirstRunIngestInvite(under: root)

            #expect(model.ingest.session == nil)
            #expect(model.statusMessage == nil)
        }
    }
}
