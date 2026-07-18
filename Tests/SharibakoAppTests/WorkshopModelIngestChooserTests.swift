import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// Tests for the ingest candidate chooser and its chaining (ho-06.3
/// gate-fix round) — `presentIngestChooser`/`selectIngestCandidate`/
/// `dismissIngestChooser`, `IngestCandidateScanner.findUnboundCandidates`,
/// and the revised multi-candidate wizard hand-off.
///
/// Split from `WorkshopModelIngestCommitTests.swift` for SwiftLint's
/// `type_body_length` ceiling, the established suite-split precedent.
/// Chain-commit fixtures encrypt, so they follow the encryption-test
/// convention (`AppAgeKeyFixture`, `age`/`age-keygen` on PATH) — no live
/// user state, no Keychain.
@MainActor
@Suite("WorkshopModel+Ingest Chooser")
struct WorkshopModelIngestChooserTests {
    /// Writes `contents` to `<directory>/<name>`, creating `directory`
    /// first — mirrors `WorkshopModelIngestTests.writeEnv`.
    private static func writeEnv(
        _ contents: String, in directory: URL, named name: String = ".env"
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(
            to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Creates a scratch scan root beside `vault`, removed by the caller's
    /// defer via the returned URL.
    private static func makeRoot(near vault: URL) throws -> URL {
        let root = vault.deletingLastPathComponent().appendingPathComponent(
            "roots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - findUnboundCandidates

    @Test("findUnboundCandidates skips marker-bearing directories and dedupes overlapping roots")
    func findUnboundCandidatesFiltersAndDedupes() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chooser-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let fresh = base.appendingPathComponent("fresh")
        try Self.writeEnv("A=1\n", in: fresh)
        let bound = base.appendingPathComponent("bound")
        try Self.writeEnv("B=2\n", in: bound)
        try "scope: bound\n".write(
            to: bound.appendingPathComponent(".sharibako"), atomically: true, encoding: .utf8)

        // The same root twice: overlap must not double-list `fresh`.
        let found = IngestCandidateScanner.findUnboundCandidates(under: [base, base])

        #expect(found.map(\.lastPathComponent) == ["fresh"])
    }

    // MARK: - Chooser intents

    @Test("presentIngestChooser lists unbound candidates from every scan root")
    func presentIngestChooserPopulates() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try Self.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            try Self.writeEnv("A=1\n", in: root.appendingPathComponent("bento"))
            try Self.writeEnv("B=2\n", in: root.appendingPathComponent("obento"))

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.scanRoots = [root]

            await model.presentIngestChooser()

            #expect(model.ingest.candidates?.map(\.lastPathComponent) == ["bento", "obento"])
            #expect(model.activity == nil)
        }
    }

    @Test("presentIngestChooser presents the empty state when nothing is unbound")
    func presentIngestChooserEmptyState() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try Self.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.scanRoots = [root]

            await model.presentIngestChooser()

            // Non-nil empty: the chooser presents with Choose Other… available.
            #expect(model.ingest.candidates?.isEmpty == true)
        }
    }

    @Test("selectIngestCandidate closes the chooser and opens a chaining session")
    func selectIngestCandidateOpensSession() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try Self.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let project = root.appendingPathComponent("bento")
            try Self.writeEnv("A=1\n", in: project)

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.scanRoots = [root]
            await model.presentIngestChooser()

            await model.selectIngestCandidate(project)

            #expect(model.ingest.candidates == nil)
            #expect(model.ingest.session?.directory.lastPathComponent == "bento")
            #expect(model.ingest.session?.chainOnCommit == true)
        }
    }

    @Test("dismissIngestChooser clears the candidate list")
    func dismissIngestChooserClears() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try Self.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            try Self.writeEnv("A=1\n", in: root.appendingPathComponent("bento"))

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.scanRoots = [root]
            await model.presentIngestChooser()

            model.dismissIngestChooser()

            #expect(model.ingest.candidates == nil)
        }
    }

    @Test("presentIngestChooser picks up roots added to config.yaml after launch")
    func presentIngestChooserReloadsConfigRoots() async throws {
        try await WorkshopTestSupport.withTempDirectory { home in
            try await WorkshopTestSupport.withTempVault { vault in
                let root = try Self.makeRoot(near: vault)
                defer { try? FileManager.default.removeItem(at: root) }
                try Self.writeEnv("A=1\n", in: root.appendingPathComponent("bento"))

                // Model launches with NO roots; the config gains one later —
                // the ho-06.3 gate's hand-edited-while-running scenario.
                let model = WorkshopModel(
                    environment: ["SHARIBAKO_VAULT": vault.path], home: home)
                #expect(model.scanRoots.isEmpty)
                try WorkshopConfig.persistScanRoot(root, configURL: model.configURL)

                await model.presentIngestChooser()

                #expect(model.scanRoots.map(\.path) == [root.path])
                #expect(model.ingest.candidates?.map(\.lastPathComponent) == ["bento"])
            }
        }
    }

    @Test("rescan picks up roots added to config.yaml after launch")
    func rescanReloadsConfigRoots() async throws {
        try await WorkshopTestSupport.withTempDirectory { home in
            try await WorkshopTestSupport.withTempVault { vault in
                let root = try Self.makeRoot(near: vault)
                defer { try? FileManager.default.removeItem(at: root) }

                let model = WorkshopModel(
                    environment: ["SHARIBAKO_VAULT": vault.path], home: home)
                #expect(model.scanRoots.isEmpty)
                try WorkshopConfig.persistScanRoot(root, configURL: model.configURL)

                await model.rescan()

                #expect(model.scanRoots.map(\.path) == [root.path])
                #expect(model.statusMessage?.contains("in 1 root") == true)
            }
        }
    }

    // MARK: - Chaining

    @Test("a chained commit re-presents the chooser with the remaining candidates")
    func chainedCommitRepresentsChooser() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                let root = try Self.makeRoot(near: vault)
                defer { try? FileManager.default.removeItem(at: root) }
                let first = root.appendingPathComponent("bento")
                try Self.writeEnv("A=1\n", in: first)
                let second = root.appendingPathComponent("obento")
                try Self.writeEnv("B=2\n", in: second)

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.scanRoots = [root]
                await model.selectIngestCandidate(first)

                await model.commitIngest()

                // The fresh marker drops `bento` from the walk by itself.
                #expect(model.ingest.session == nil)
                #expect(model.ingest.candidates?.map(\.lastPathComponent) == ["obento"])
                #expect(model.scopes.map(\.identity).contains("bento"))
            }
        }
    }

    @Test("a non-chained commit does not re-present the chooser")
    func plainCommitDoesNotChain() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                let root = try Self.makeRoot(near: vault)
                defer { try? FileManager.default.removeItem(at: root) }
                let first = root.appendingPathComponent("bento")
                try Self.writeEnv("A=1\n", in: first)
                let second = root.appendingPathComponent("obento")
                try Self.writeEnv("B=2\n", in: second)

                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.scanRoots = [root]
                await model.beginIngest(directory: first)

                await model.commitIngest()

                #expect(model.ingest.session == nil)
                #expect(model.ingest.candidates == nil)
            }
        }
    }

    // MARK: - Wizard hand-off (revised)

    @Test("offerFirstRunIngestInvite presents the chooser when several candidates exist")
    func offerFirstRunIngestInviteMultipleCandidates() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try Self.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            try Self.writeEnv("A=1\n", in: root.appendingPathComponent("bento"))
            try Self.writeEnv("B=2\n", in: root.appendingPathComponent("obento"))

            let model = WorkshopModel(
                environment: ["SHARIBAKO_VAULT": vault.path],
                home: URL(fileURLWithPath: "/Users/nobody")
            )

            await model.offerFirstRunIngestInvite(under: root)

            #expect(model.ingest.session == nil)
            #expect(model.ingest.candidates?.map(\.lastPathComponent) == ["bento", "obento"])
        }
    }
}
