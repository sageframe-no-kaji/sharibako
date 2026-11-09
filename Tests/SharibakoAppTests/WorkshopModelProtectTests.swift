import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// ho-06.10 AT-02 tests for the Protect intents (`WorkshopModel+Protect.swift`):
/// one line, a page's recommended lines, and every folder not yet protected,
/// each over `acceptIngest` behind one key handle — asserting the vault files,
/// the claim file, the pruned candidates, the moved selection, the cleared
/// flips, the announce, and the pane error on failure.
///
/// The commit fixtures encrypt, so they follow the encryption-test convention
/// (`AppAgeKeyFixture`, `age`/`age-keygen` on PATH, the file-key dev seam) —
/// no live user state, no Keychain. The commit-path coverage the retired
/// `WorkshopModelIngestCommitTests` carried (encrypt, claim file, select,
/// announce, an underlying `VaultError`, a missing key) lives here.
@MainActor
@Suite("WorkshopModel Protect")
struct WorkshopModelProtectTests {
    /// A temp root beside `vault` holding `name/.env` with `contents`.
    private static func folder(
        _ name: String, env contents: String, near vault: URL
    ) throws -> (root: URL, folder: URL) {
        let root = try ProjectsTestSupport.makeRoot(near: vault)
        let folder = root.appendingPathComponent(name)
        try ProjectsTestSupport.writeEnv(contents, in: folder)
        return (root, folder)
    }

    /// An open model over a vault with one root scanned and a file key.
    private static func scannedModel(
        vault: URL, root: URL, key: URL
    ) async -> WorkshopModel {
        let model = ProjectsTestSupport.model(vault: vault, ageKey: key)
        model.scanRoots = [root]
        await model.performLaunchScan()
        return model
    }

    // MARK: - Summaries (pure)

    @Test("the announces count secrets and settings in the user's words")
    func summaries() {
        let decisions: [KeyDecision] = [
            .importAsLocal(key: "A"), .linkToShared(key: "B", sharedID: "s"),
            .moveToShared(key: "C", newSharedID: "t"), .leaveAlone(key: "D"), .leaveAlone(key: "E"),
        ]
        #expect(
            WorkshopModel.protectSummary(name: "bento", decisions: decisions)
                == "Protected 3 secrets in bento; 2 settings left in .env.")
        #expect(
            WorkshopModel.protectSummary(name: "bento", decisions: [.importAsLocal(key: "A")])
                == "Protected 1 secret in bento.")
        #expect(
            WorkshopModel.protectAllSummary(projects: 3, decisions: decisions)
                == "Protected 3 projects: 3 secrets; 2 settings left in .env.")
        #expect(
            WorkshopModel.protectAllSummary(projects: 1, decisions: [.leaveAlone(key: "A"), .skip(key: "B")])
                == "Protected 1 project: 0 secrets; 2 settings left in .env.")
        #expect(WorkshopModel.nothingToProtect(in: "bento").hasPrefix("Nothing to protect in bento"))
        #expect(WorkshopModel.nothingToProtect(in: nil).hasPrefix("Nothing to protect"))
    }

    // MARK: - protectRecommended

    @Test("Protect on a folder creates the project, leaves settings in .env, prunes, selects, announces")
    func protectRecommendedCandidate() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                let (root, bento) = try Self.folder(
                    "bento", env: "API_KEY=sk-live\nDB_PASSWORD=hunter2\nPORT=3000\n", near: vault)
                defer { try? FileManager.default.removeItem(at: root) }
                let model = await Self.scannedModel(vault: vault, root: root, key: fixture.privateKeyURL)
                #expect(model.selection == .candidate(directory: model.candidates[0]))
                await model.loadContent(for: model.selection)
                model.setLineChoice(.leaveAsSetting, forKey: "DB_PASSWORD")
                #expect(!model.lineChoiceFlips.isEmpty)

                await model.protectRecommended()

                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                #expect(try core.inspect("bento").map(\.key) == ["API_KEY"])
                #expect(try core.getValue("API_KEY", inScope: "bento") == "sk-live")
                #expect(try core.listScopes().first?.type == .projectDev)
                let claim = try String(contentsOf: bento.appendingPathComponent(".sharibako"), encoding: .utf8)
                #expect(claim.contains("scope: bento"))
                // Settings and the flipped secret stay in .env, untouched.
                let env = try String(contentsOf: bento.appendingPathComponent(".env"), encoding: .utf8)
                #expect(env == "API_KEY=sk-live\nDB_PASSWORD=hunter2\nPORT=3000\n")
                #expect(model.candidates.isEmpty)
                #expect(model.selection == .project(scopeID: "bento"))
                #expect(model.projectStatus(forScope: "bento") == .protected)
                #expect(model.lineChoiceFlips.isEmpty)
                #expect(model.statusMessage == "Protected 1 secret in bento; 2 settings left in .env.")
                #expect(model.activity == nil)
                // The page reloaded as the project: the flip cleared, so the
                // classifier's default is back on the unprotected secret.
                #expect(
                    model.projectLines.map(\.status) == [.protected(kind: .value), .notProtected, .setting])
                #expect(model.headerState == .unprotected(count: 1))
            }
        }
    }

    @Test("Protect links a name-matched key and makes a new shared secret when chosen")
    func protectRecommendedShared() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                try core.addSharedEntry("ANTHROPIC_API_KEY", value: "sk-ant")
                let (root, _) = try Self.folder(
                    "nest", env: "ANTHROPIC_API_KEY=sk-ant\nOPENAI_API_KEY=sk-oai\n", near: vault)
                defer { try? FileManager.default.removeItem(at: root) }
                let model = await Self.scannedModel(vault: vault, root: root, key: fixture.privateKeyURL)
                await model.loadContent(for: model.selection)
                #expect(model.projectLines.first?.choice == .useShared(id: "ANTHROPIC_API_KEY"))
                model.setLineChoice(.makeShared(id: "openai"), forKey: "OPENAI_API_KEY")

                await model.protectRecommended()

                #expect(
                    try core.inspect("nest").map(\.kind) == [
                        .link(sharedID: "ANTHROPIC_API_KEY"), .link(sharedID: "openai"),
                    ])
                #expect(try core.listShared().contains("openai"))
                #expect(model.statusMessage == "Protected 2 secrets in nest.")
            }
        }
    }

    @Test("an explicit project ID is used, and a taken folder name is suffixed")
    func protectRecommendedScopeIDs() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("bento", type: .service, in: vault)
                let (root, _) = try Self.folder("bento", env: "API_KEY=sk-live\n", near: vault)
                defer { try? FileManager.default.removeItem(at: root) }
                let other = root.appendingPathComponent("other")
                try ProjectsTestSupport.writeEnv("TOKEN_SECRET=t\n", in: other)
                let model = await Self.scannedModel(vault: vault, root: root, key: fixture.privateKeyURL)

                model.selection = .candidate(directory: model.candidates[0])
                await model.protectRecommended()
                #expect(model.selection == .project(scopeID: "bento-2"))
                #expect(model.candidates.map(\.lastPathComponent) == ["other"])

                model.selection = .candidate(directory: model.candidates[0])
                await model.protectRecommended(scopeID: "chosen")
                #expect(model.selection == .project(scopeID: "chosen"))
                #expect(model.scopes.map(\.identity) == ["bento", "bento-2", "chosen"])
            }
        }
    }

    @Test("Protect on a project adds its new lines and keeps the claim file's target")
    func protectRecommendedExistingProject() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("nest", type: .service, displayName: "Nest Cam", in: vault)
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                try core.addSecret("API_KEY", value: "sk-old", inScope: "nest")
                let root = try ProjectsTestSupport.makeRoot(near: vault)
                defer { try? FileManager.default.removeItem(at: root) }
                let dir = try ProjectsTestSupport.seedMarker(scope: "nest", under: root, named: "nest")
                try ProjectsTestSupport.writeEnv("API_KEY=sk-file\nNEW_TOKEN=t-new\nDEBUG=true\n", in: dir)
                let model = await Self.scannedModel(vault: vault, root: root, key: fixture.privateKeyURL)
                #expect(model.selection == .project(scopeID: "nest"))

                await model.protectRecommended(scopeID: "ignored-for-a-project")

                #expect(try core.inspect("nest").map(\.key).sorted() == ["API_KEY", "NEW_TOKEN"])
                // The protected line was not re-imported over the vault's value.
                #expect(try core.getValue("API_KEY", inScope: "nest") == "sk-old")
                #expect(try core.listScopes().first?.type == .service)
                let claim = try String(contentsOf: dir.appendingPathComponent(".sharibako"), encoding: .utf8)
                #expect(claim.contains("materialize_to: .env"))
                #expect(model.statusMessage == "Protected 1 secret in Nest Cam; 1 setting left in .env.")
                #expect(model.headerState == .protected(upToDate: nil))
            }
        }
    }

    @Test("with nothing to protect it says so and asks for no key")
    func protectRecommendedNothing() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let (root, _) = try Self.folder("cfg", env: "PORT=3000\nLOG_LEVEL=info\n", near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            // A key path that cannot load: asking for it would set an error.
            let model = await Self.scannedModel(
                vault: vault, root: root, key: URL(fileURLWithPath: "/nonexistent/key.txt"))

            await model.protectRecommended()

            #expect(model.statusMessage == WorkshopModel.nothingToProtect(in: "cfg"))
            #expect(model.errorMessage == nil)
            #expect(model.scopes.isEmpty)
            #expect(model.candidates.count == 1)

            model.selection = .shared(id: "anthropic")
            await model.protectRecommended()
            #expect(model.statusMessage == WorkshopModel.nothingToProtect(in: nil))
        }
    }

    @Test("a key that cannot load lands in the pane with a next step, and nothing is written")
    func protectRecommendedMissingKey() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let (root, bento) = try Self.folder("bento", env: "API_KEY=sk-live\n", near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = await Self.scannedModel(
                vault: vault, root: root, key: URL(fileURLWithPath: "/nonexistent/key.txt"))
            let before = model.selection

            await model.protectRecommended()

            #expect(model.errorMessage?.hasPrefix("Could not load age key") == true)
            #expect(model.paneError?.message == model.errorMessage)
            #expect(model.paneError?.nextStep != nil)
            #expect(model.selection == before)
            #expect(model.scopes.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: bento.appendingPathComponent(".sharibako").path))
            #expect(model.activity == nil)
        }
    }

    @Test("a vault failure lands in the pane and the folder stays where it was")
    func protectRecommendedVaultFailure() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                try core.addSharedEntry("anthropic", value: "sk-ant")
                let (root, _) = try Self.folder("bento", env: "API_KEY=sk-live\n", near: vault)
                defer { try? FileManager.default.removeItem(at: root) }
                let model = await Self.scannedModel(vault: vault, root: root, key: fixture.privateKeyURL)
                await model.loadContent(for: model.selection)
                model.setLineChoice(.useShared(id: "anthropic"), forKey: "API_KEY")
                // The shared secret goes away between the choice and the Protect.
                try FileManager.default.removeItem(at: vault.appendingPathComponent("shared/anthropic.age"))

                await model.protectRecommended()

                #expect(model.paneError?.message.hasPrefix("Could not protect bento:") == true)
                #expect(model.errorMessage == model.paneError?.message)
                #expect(model.candidates.count == 1)
                #expect(model.selection == .candidate(directory: model.candidates[0]))
                #expect(!model.lineChoiceFlips.isEmpty)
            }
        }
    }

    // MARK: - protectLine

    @Test("Protect this line protects just that line and keeps it selected, now a vault secret")
    func protectLineOnFolder() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                let (root, _) = try Self.folder(
                    "bento", env: "API_KEY=sk-live\nDB_PASSWORD=hunter2\nPORT=3000\n", near: vault)
                defer { try? FileManager.default.removeItem(at: root) }
                let model = await Self.scannedModel(vault: vault, root: root, key: fixture.privateKeyURL)
                await model.loadContent(for: model.selection)
                model.setLineChoice(.leaveAsSetting, forKey: "DB_PASSWORD")
                model.selectedLineKey = "API_KEY"
                #expect(model.selectedSecretKey == nil)

                await model.protectLine(key: "API_KEY")

                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                #expect(try core.inspect("bento").map(\.key) == ["API_KEY"])
                #expect(model.selection == .project(scopeID: "bento"))
                #expect(model.selectedLineKey == "API_KEY")
                #expect(model.selectedSecretKey == "API_KEY")
                #expect(model.statusMessage == "Protected 1 secret in bento.")
                // The other line's flip is still remembered.
                #expect(model.projectLines.first { $0.key == "DB_PASSWORD" }?.choice == .leaveAsSetting)
                #expect(model.headerState == .unprotected(count: 1))
            }
        }
    }

    @Test("Protect this line does nothing for a setting or a line already in the vault")
    func protectLineNoOps() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let (root, _) = try Self.folder("bento", env: "PORT=3000\n", near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = await Self.scannedModel(
                vault: vault, root: root, key: URL(fileURLWithPath: "/nonexistent/key.txt"))

            await model.protectLine(key: "PORT")
            await model.protectLine(key: "MISSING")

            #expect(model.errorMessage == nil)
            #expect(model.scopes.isEmpty)
            #expect(model.activity == nil)
        }
    }

    // MARK: - protectAllCandidates

    @Test("Protect all protects every folder with secrets, skips the rest, reports what failed")
    func protectAll() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("acme", type: .other, in: vault)
                let root = try ProjectsTestSupport.makeRoot(near: vault)
                defer { try? FileManager.default.removeItem(at: root) }
                // Two folders named alike: one collides with the vault, the
                // other with the first folder's new name.
                try ProjectsTestSupport.writeEnv(
                    "API_KEY=a\nPORT=1\n", in: root.appendingPathComponent("acme"))
                try ProjectsTestSupport.writeEnv(
                    "API_KEY=b\n", in: root.appendingPathComponent("org/Acme"))
                try ProjectsTestSupport.writeEnv("PORT=2\n", in: root.appendingPathComponent("cfg"))
                let odd = root.appendingPathComponent("odd")
                try ProjectsTestSupport.writeEnv("X=1\n", in: odd)
                let model = await Self.scannedModel(vault: vault, root: root, key: fixture.privateKeyURL)
                #expect(model.candidates.count == 4)
                let acme = try #require(model.candidates.first { $0.lastPathComponent == "acme" })
                model.selection = .candidate(directory: acme)
                // Unreadable by the time Protect all reads it.
                try FileManager.default.removeItem(at: odd.appendingPathComponent(".env"))
                try FileManager.default.createDirectory(
                    at: odd.appendingPathComponent(".env"), withIntermediateDirectories: true)

                await model.protectAllCandidates()

                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                #expect(try core.getValue("API_KEY", inScope: "acme-2") == "a")
                #expect(try core.getValue("API_KEY", inScope: "acme-3") == "b")
                #expect(model.candidates.map(\.lastPathComponent).sorted() == ["cfg", "odd"])
                #expect(model.selection == .project(scopeID: "acme-2"))
                #expect(model.projectLines.map(\.key) == ["API_KEY", "PORT"])
                #expect(model.statusMessage == "Protected 2 projects: 2 secrets; 1 setting left in .env.")
                #expect(model.paneError?.message.hasPrefix("Could not protect odd:") == true)
                #expect(model.activity == nil)
            }
        }
    }

    @Test("Protect all with nothing waiting says so")
    func protectAllNothing() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let model = ProjectsTestSupport.model(vault: vault)

            await model.protectAllCandidates()

            #expect(model.statusMessage == WorkshopModel.nothingToProtect(in: nil))
            #expect(model.errorMessage == nil)
        }
    }

    @Test("Protect all keeps a selection it did not protect, and stops at a key that cannot load")
    func protectAllKeepsSelectionAndKeyFailure() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                let (root, _) = try Self.folder("bento", env: "API_KEY=sk\n", near: vault)
                defer { try? FileManager.default.removeItem(at: root) }
                let model = await Self.scannedModel(vault: vault, root: root, key: fixture.privateKeyURL)
                model.selection = .shared(id: "anthropic")

                await model.protectAllCandidates()

                #expect(model.selection == .shared(id: "anthropic"))
                #expect(model.statusMessage == "Protected 1 project: 1 secret.")
            }
        }
        try await WorkshopTestSupport.withTempVault { vault in
            let (root, _) = try Self.folder("bento", env: "API_KEY=sk\n", near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = await Self.scannedModel(
                vault: vault, root: root, key: URL(fileURLWithPath: "/nonexistent/key.txt"))

            await model.protectAllCandidates()

            #expect(model.paneError?.message.hasPrefix("Could not load age key") == true)
            #expect(model.candidates.count == 1)
        }
    }
}
