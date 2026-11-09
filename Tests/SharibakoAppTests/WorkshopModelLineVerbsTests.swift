import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// ho-06.10 AT-03 tests for the right-click verbs (`WorkshopModel+Pages.swift`,
/// `WorkshopModel+Projects.swift`): a line's menu, its checks, and the
/// intents it routes to — Protect this line, Reveal, Copy, Delete secret, the
/// selected line's history — and a sidebar row's menu, its disabled reasons,
/// and ``WorkshopModel/perform(_:on:)``.
///
/// The commit and decrypt fixtures follow the encryption-test convention
/// (`AppAgeKeyFixture`, `age`/`age-keygen` on PATH, the file-key dev seam);
/// the rest are keyless. Open in Finder is not driven: it opens a real Finder
/// window. No live user state, no Keychain.
@MainActor
@Suite("WorkshopModel Line verbs")
struct WorkshopModelLineVerbsTests {
    /// A project `nest` holding `API_KEY` and `OTHER_KEY` (encrypted with
    /// `key`), with no folder on this Mac, selected and read.
    private static func protectedProject(vault: URL, key: URL) async throws -> WorkshopModel {
        try WorkshopTestSupport.writeScope("nest", type: .other, in: vault)
        let core = try VaultCore(vaultURL: vault, ageKeyURL: key)
        try core.addSecret("API_KEY", value: "sk-live", inScope: "nest")
        try core.addSecret("OTHER_KEY", value: "other", inScope: "nest")
        let model = ProjectsTestSupport.model(vault: vault, ageKey: key)
        model.loadScopes()
        model.selection = .project(scopeID: "nest")
        await model.loadContent(for: model.selection)
        return model
    }

    // MARK: - A line's menu (pure)

    @Test("each line verb has its words, its symbol or a check, and only Delete is destructive")
    func lineVerbWords() {
        let verbs: [WorkshopModel.LineVerb] = [
            .protectLine, .choose(.useShared(id: "openai")), .choose(.leaveAsSetting), .reveal, .copy,
            .deleteSecret,
        ]
        #expect(
            verbs.map(\.title) == [
                "Protect this line", "Use shared secret openai", "Leave in .env as a setting", "Reveal", "Copy",
                "Delete secret",
            ])
        #expect(verbs.map(\.systemImage) == ["lock.shield", nil, nil, "eye", "doc.on.doc", "trash"])
        #expect(verbs.map(\.isDestructive) == [false, false, false, false, false, true])
        #expect(verbs.map(\.id) == verbs)

        let left = WorkshopModelProjectPageTests.line("PORT", .setting)
        #expect(WorkshopModel.isLineVerbChecked(.choose(.leaveAsSetting), for: left))
        #expect(!WorkshopModel.isLineVerbChecked(.choose(.protectLocal), for: left))
        #expect(!WorkshopModel.isLineVerbChecked(.protectLine, for: left))
    }

    @Test("a line off the vault offers Protect and its choices; one in the vault offers Reveal, Copy, Delete")
    func lineVerbLists() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let (model, root) = try await WorkshopModelProjectPageTests.candidatePage(
                vault: vault, env: "API_KEY=sk\nPORT=3000\n", sharedIDs: ["anthropic"])
            defer { try? FileManager.default.removeItem(at: root) }
            let secret = try #require(model.projectLines.first { $0.key == "API_KEY" })
            #expect(
                model.lineVerbs(for: secret) == [
                    .protectLine, .choose(.useShared(id: "anthropic")), .choose(.makeShared(id: "api-key")),
                    .choose(.leaveAsSetting),
                ])
            let setting = try #require(model.projectLines.first { $0.key == "PORT" })
            #expect(
                model.lineVerbs(for: setting).filter { WorkshopModel.isLineVerbChecked($0, for: setting) } == [
                    .choose(.leaveAsSetting)
                ])
            let vaultLine = WorkshopModelProjectPageTests.line("K", .missingFromEnv)
            #expect(model.lineVerbs(for: vaultLine) == [.reveal, .copy, .deleteSecret])

            #expect(!model.isLineVerbDisabled(.protectLine))
            model.activity = .ingesting
            #expect(model.isLineVerbDisabled(.protectLine))
            #expect(model.isLineVerbDisabled(.deleteSecret))
            #expect(!model.isLineVerbDisabled(.reveal))
            #expect(!model.isLineVerbDisabled(.choose(.leaveAsSetting)))
            model.activity = nil
        }
    }

    // MARK: - Line intents

    @Test("Protect this line on a setting chooses Protect for this project, commits it, and keeps it selected")
    func protectLineNowFromSetting() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                let root = try ProjectsTestSupport.makeRoot(near: vault)
                defer { try? FileManager.default.removeItem(at: root) }
                let bento = root.appendingPathComponent("bento")
                try ProjectsTestSupport.writeEnv("API_KEY=sk-live\nPORT=3000\n", in: bento)
                let model = ProjectsTestSupport.model(vault: vault, ageKey: fixture.privateKeyURL)
                model.scanRoots = [root]
                await model.performLaunchScan()
                await model.loadContent(for: model.selection)

                await model.protectLineNow(key: "PORT")

                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                #expect(try core.getValue("PORT", inScope: "bento") == "3000")
                #expect(model.selection == .project(scopeID: "bento"))
                #expect(model.selectedLineKey == "PORT")
                #expect(model.selectedLine?.status == .protected(kind: .value))
                #expect(model.detailPane == .secret)
                // The rest of the page keeps its shape: the other secret is
                // still there, still not protected.
                #expect(model.projectLines.first { $0.key == "API_KEY" }?.status == .notProtected)

                // Nothing to do for a key with no line.
                await model.protectLineNow(key: "NOT_A_LINE")
                #expect(model.selectedLineKey == "PORT")
            }
        }
    }

    @Test("Reveal selects the line and shows its value; Copy returns it without showing it")
    func revealAndCopy() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                let model = try await Self.protectedProject(vault: vault, key: fixture.privateKeyURL)

                model.revealLine(key: "API_KEY")
                #expect(model.selectedLineKey == "API_KEY")
                #expect(model.revealedValue == "sk-live")

                // Copying the revealed line leaves it revealed.
                #expect(model.copyableValue(forKey: "API_KEY") == "sk-live")
                #expect(model.revealedValue == "sk-live")
                #expect(model.statusMessage == "Copied API_KEY to the clipboard.")

                // Copying another line selects it but never shows its value.
                #expect(model.copyableValue(forKey: "OTHER_KEY") == "other")
                #expect(model.selectedLineKey == "OTHER_KEY")
                #expect(model.revealedValue == nil)

                // A key the vault does not hold reads nothing and says so.
                model.statusMessage = nil
                #expect(model.copyableValue(forKey: "GHOST") == nil)
                #expect(model.statusMessage == nil)
                #expect(model.errorMessage != nil)
            }
        }
    }

    @Test("Reveal and Copy need a project selected")
    func revealAndCopyNeedProject() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let (model, root) = try await WorkshopModelProjectPageTests.candidatePage(vault: vault, env: "API_KEY=sk\n")
            defer { try? FileManager.default.removeItem(at: root) }
            model.revealLine(key: "API_KEY")
            #expect(model.selectedLineKey == nil)
            #expect(model.copyableValue(forKey: "API_KEY") == nil)
            #expect(model.revealedValue == nil)
        }
    }

    @Test("Delete secret selects the line and stages the deletion; a plaintext line stages nothing")
    func deleteLine() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("nest", type: .other, in: vault)
            try LinesTestSupport.writeVaultKey("API_KEY", scope: "nest", in: vault)
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let dir = try ProjectsTestSupport.seedMarker(scope: "nest", under: root, named: "nest")
            try ProjectsTestSupport.writeEnv("API_KEY=sk\nNEW_TOKEN=t-1\n", in: dir)
            let model = ProjectsTestSupport.model(vault: vault)
            model.scanRoots = [root]
            await model.performLaunchScan()
            model.selection = .project(scopeID: "nest")
            await model.loadContent(for: model.selection)

            model.requestDeleteLine(key: "NEW_TOKEN")
            #expect(model.selectedLineKey == "NEW_TOKEN")
            #expect(model.pendingSecretDeletion == nil)

            model.requestDeleteLine(key: "API_KEY")
            #expect(model.pendingSecretDeletion == WorkshopModel.SecretDeletion(scopeID: "nest", key: "API_KEY"))
        }
    }

    @Test("the selected line's history loads only for a line in the vault")
    func selectedLineHistory() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("nest", type: .other, in: vault)
            try LinesTestSupport.writeVaultKey("API_KEY", scope: "nest", in: vault)
            let model = ProjectsTestSupport.model(vault: vault)
            model.loadSecrets(for: "nest")
            model.loadSelectedLineHistory()
            #expect(model.history.isEmpty)

            model.selection = .project(scopeID: "nest")
            await model.loadContent(for: model.selection)
            model.selectedLineKey = "API_KEY"
            model.loadSelectedLineHistory()
            // A vault with no git repository has no history and no error.
            #expect(model.history.isEmpty)
            #expect(model.errorMessage == nil)
        }
    }

    // MARK: - A sidebar row's menu

    @Test("a row's menu is its action-column verbs, with disabled reasons for that row")
    func entryVerbsAndReasons() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("chumon", type: .machine, in: vault)
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            try ProjectsTestSupport.writeEnv("API_KEY=sk\n", in: root.appendingPathComponent("acme"))
            try ProjectsTestSupport.seedMarker(scope: "ghost", under: root, named: "ghost")
            let model = ProjectsTestSupport.model(vault: vault)
            model.loadScopes()
            let unscanned = try #require(model.projectEntry(for: .project(scopeID: "chumon")))
            #expect(model.disabledReason(for: .writeEnv, on: unscanned)?.hasPrefix("Not scanned yet") == true)

            model.scanRoots = [root]
            await model.performLaunchScan()
            let candidate = try #require(model.projectSections.first { $0.id == .notProtected }?.entries.first)
            let project = try #require(model.projectEntry(for: .project(scopeID: "chumon")))
            let problem = try #require(model.projectSections.first { $0.id == .needsAttention }?.entries.first)

            #expect(model.entryVerbs(for: candidate) == [.protect, .openInFinder])
            #expect(model.entryVerbs(for: project) == [.writeEnv, .previewEnv, .openInFinder, .deleteProject])
            #expect(model.entryVerbs(for: problem) == [.protectFolder, .forgetFolder, .openInFinder])
            // The menu speaks for its own row, not for the selection.
            model.selection = .candidate(directory: try #require(candidate.directory))
            #expect(model.disabledReason(for: .writeEnv, on: project) == WorkshopModel.noFolderHereReason)
            #expect(model.disabledReason(for: .openInFinder, on: project) == WorkshopModel.noFolderHereReason)
            #expect(model.disabledReason(for: .openInFinder, on: candidate) == nil)
            #expect(model.disabledReason(for: .deleteProject, on: project) == nil)
            #expect(model.disabledReason(for: .writeEnv) == "Select a project first")
        }
    }

    @Test("a row's verb selects the row and runs the action column's intent")
    func performOnEntry() async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("chumon", type: .machine, in: vault)
                let root = try ProjectsTestSupport.makeRoot(near: vault)
                defer { try? FileManager.default.removeItem(at: root) }
                try ProjectsTestSupport.writeEnv("API_KEY=sk\n", in: root.appendingPathComponent("acme"))
                let ghost = try ProjectsTestSupport.seedMarker(scope: "ghost", under: root, named: "ghost")
                try ProjectsTestSupport.writeEnv("TOKEN=t-1\n", in: ghost)
                let model = ProjectsTestSupport.model(vault: vault, ageKey: fixture.privateKeyURL)
                model.scanRoots = [root]
                await model.performLaunchScan()
                let project = try #require(model.projectEntry(for: .project(scopeID: "chumon")))
                let problem = try #require(model.projectSections.first { $0.id == .needsAttention }?.entries.first)
                let candidate = try #require(model.projectSections.first { $0.id == .notProtected }?.entries.first)

                await model.perform(.deleteProject, on: project)
                #expect(model.selection == project.id)
                #expect(model.pendingScopeDeletion?.scopeID == "chumon")
                model.dismissScopeDeletion()

                await model.perform(.writeEnv, on: project)
                await model.perform(.previewEnv, on: project)
                #expect(model.envPreview == nil)
                #expect(model.activity == nil)

                await model.perform(.forgetFolder, on: problem)
                #expect(model.selection == problem.id)
                #expect(model.pendingStrayMarkerRemoval?.scope == "ghost")
                model.dismissStrayMarkerRemoval()

                await model.perform(.protect, on: candidate)
                #expect(model.selection == .project(scopeID: "acme"))

                await model.perform(.protectFolder, on: problem)
                #expect(model.selection == .project(scopeID: "ghost"))
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                #expect(try core.getValue("TOKEN", inScope: "ghost") == "t-1")
            }
        }
    }
}
