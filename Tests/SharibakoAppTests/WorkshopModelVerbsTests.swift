import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// Fixtures for the ho-06.10 AT-04 verb suites.
@MainActor
enum VerbsTestSupport {
    /// A project the vault protects — `bento`, owning `DB` and `API_KEY` —
    /// with its folder under a scan root, scanned, and its page selected and
    /// read.
    ///
    /// `env` is written to the folder's `.env` first when given; `shared`
    /// becomes shared secrets (ID → value) before the model loads. Hands
    /// `body` the model, the vault, the project folder, and the key.
    static func withProtectedProject(
        env: String? = nil,
        shared: [String: String] = [:],
        _ body: @MainActor (WorkshopModel, URL, URL, AppAgeKeyFixture.Fixture) async throws -> Void
    ) async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("bento", type: .projectDev, in: vault)
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                try core.addSecret("DB", value: "postgres://vault", inScope: "bento")
                try core.addSecret("API_KEY", value: "sk-live", inScope: "bento")
                for (id, value) in shared {
                    try core.addSharedEntry(id, value: value)
                }
                let root = try ProjectsTestSupport.makeRoot(near: vault)
                defer { try? FileManager.default.removeItem(at: root) }
                let folder = try ProjectsTestSupport.seedMarker(scope: "bento", under: root, named: "bento")
                if let env {
                    try ProjectsTestSupport.writeEnv(env, in: folder)
                }
                let model = ProjectsTestSupport.model(vault: vault, ageKey: fixture.privateKeyURL)
                model.scanRoots = [root]
                await model.performLaunchScan()
                model.selection = .project(scopeID: "bento")
                await model.loadContent(for: model.selection)
                try await body(model, vault, folder, fixture)
            }
        }
    }

    /// The standardized path of a `.candidate` selection, or `nil`.
    static func candidatePath(_ selection: WorkshopModel.Selection?) -> String? {
        guard case .candidate(let directory) = selection else { return nil }
        return directory.standardizedFileURL.path
    }
}

/// ho-06.10 AT-04 tests: Unprotect, the shared-secret verbs on a protected
/// line, and the next step every pane error carries.
///
/// Real temp vaults with the file-key dev path (no Keychain); asserting the
/// model's state and the files on disk, never rendering.
@MainActor
@Suite("WorkshopModel Verbs")
struct WorkshopModelVerbsTests {
    // MARK: - Errors in the pane

    @Test("each error gets its next step: a key that cannot read, a folder not found, nothing else")
    func nextSteps() {
        let mismatch = VaultError.ageInvocationFailed(
            exitCode: 1, stderr: "age: error: no identity matched any of the recipients")
        #expect(WorkshopModel.nextStep(for: mismatch) == WorkshopModel.keyMismatchNextStep)
        #expect(WorkshopModel.nextStep(for: VaultError.ageInvocationFailed(exitCode: 1, stderr: "boom")) == nil)
        let notFound = VaultError.markerNotFound(startingFrom: URL(fileURLWithPath: "/tmp"))
        #expect(WorkshopModel.nextStep(for: notFound) == WorkshopModel.folderNotFoundNextStep)
        #expect(WorkshopModel.nextStep(for: VaultError.scopeNotFound(id: "x")) == nil)
        #expect(WorkshopModel.nextStep(for: CocoaError(.fileNoSuchFile)) == nil)
        #expect(WorkshopModel.message(for: notFound) == "No folder for this project was found under the scan folders.")
        #expect(WorkshopModel.keyMismatchNextStep.hasPrefix("Unprotect is not possible without the key;"))
    }

    @Test("a pane error is set with its status-bar echo, and the next success clears both")
    func paneErrorClearsOnSuccess() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = ProjectsTestSupport.model(vault: vault)
            model.reportPaneError(for: VaultError.markerNotFound(startingFrom: vault))
            #expect(model.paneError?.nextStep == WorkshopModel.folderNotFoundNextStep)
            #expect(model.errorMessage == model.paneError?.message)
            model.errorMessage = nil
            #expect(model.paneError == nil)
        }
    }

    @Test("a page read that fails lands in that page's pane, never on a page selected since")
    func readFailureLandsOnItsPage() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let model = ProjectsTestSupport.model(vault: vault)
            let missing = WorkshopModel.Selection.project(scopeID: "missing")
            await model.loadContent(for: missing)
            #expect(model.errorMessage == "Scope 'missing' not found.")
            #expect(model.paneError == nil)

            model.selection = missing
            await model.loadContent(for: missing)
            #expect(model.paneError?.message == "Scope 'missing' not found.")
        }
    }

    // MARK: - Unprotect

    @Test("Unprotect's words: title, the consequence, and the announce, count-aware")
    func unprotectWords() {
        let plan = WorkshopModel.UnprotectPlan(
            scopeID: "bento", name: "bento", directory: URL(fileURLWithPath: "/tmp/bento"), secretCount: 3)
        #expect(WorkshopModel.unprotectDialogTitle(for: plan) == "Unprotect bento?")
        #expect(
            WorkshopModel.unprotectDialogMessage(for: plan)
                == "Its 3 secrets will be back in .env in plain text, in /tmp/bento, and no longer in the vault. "
                + "The folder goes back to Not protected.")
        let one = WorkshopModel.UnprotectPlan(
            scopeID: "bento", name: "bento", directory: URL(fileURLWithPath: "/tmp/bento"), secretCount: 1)
        #expect(WorkshopModel.unprotectDialogMessage(for: one).hasPrefix("Its 1 secret will be back"))
        #expect(
            WorkshopModel.unprotectSummary(name: "bento", secretCount: 3)
                == "Unprotected bento — 3 secrets are back in .env in plain text.")
        #expect(
            WorkshopModel.unprotectSummary(name: "bento", secretCount: 1)
                == "Unprotected bento — 1 secret is back in .env in plain text.")
        #expect(
            WorkshopModel.unprotectSummary(name: "bento", secretCount: 0)
                == "Unprotected bento — it had no secrets in the vault.")
    }

    @Test("Unprotect writes the values into .env, then removes the vault entry and the claim file")
    func unprotectReturnsFolderToNotProtected() async throws {
        try await VerbsTestSupport.withProtectedProject { model, vault, folder, _ in
            model.driftReports["bento"] = ProjectsTestSupport.driftReport(scopeID: "bento", drifted: 0)
            model.requestUnprotectSelectedProject()
            let plan = try #require(model.pendingUnprotect)
            #expect(plan.scopeID == "bento")
            #expect(plan.secretCount == 2)

            model.dismissUnprotect()
            #expect(model.pendingUnprotect == nil)
            await model.confirmUnprotect(plan)

            let env = try String(contentsOf: folder.appendingPathComponent(".env"), encoding: .utf8)
            #expect(env.contains("DB=postgres://vault"))
            #expect(env.contains("API_KEY=sk-live"))
            #expect(!FileManager.default.fileExists(atPath: vault.appendingPathComponent("scopes/bento").path))
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".sharibako").path))
            #expect(model.scopes.isEmpty)
            #expect(model.driftReports["bento"] == nil)
            #expect(VerbsTestSupport.candidatePath(model.selection) == folder.standardizedFileURL.path)
            #expect(model.statusMessage == "Unprotected bento — 2 secrets are back in .env in plain text.")
            #expect(model.errorMessage == nil)
            #expect(model.activity == nil)
        }
    }

    @Test("Unprotect lists a folder outside the scan folders under Not protected anyway")
    func unprotectOutsideRoots() async throws {
        try await VerbsTestSupport.withProtectedProject { model, _, folder, _ in
            model.scanRoots = []
            model.requestUnprotectSelectedProject()
            await model.confirmUnprotect()
            #expect(model.candidates.map(\.standardizedFileURL.path) == [folder.standardizedFileURL.path])
            #expect(VerbsTestSupport.candidatePath(model.selection) == folder.standardizedFileURL.path)
        }
    }

    @Test("a .env that differs from the vault stops Unprotect before anything is deleted")
    func unprotectStopsOnDifference() async throws {
        try await VerbsTestSupport.withProtectedProject(env: "DB=postgres://tampered\n") { model, vault, folder, _ in
            model.requestUnprotectSelectedProject()
            await model.confirmUnprotect()
            #expect(model.pendingDiff?.ownedKeysDiffering == ["DB"])
            #expect(FileManager.default.fileExists(atPath: vault.appendingPathComponent("scopes/bento").path))
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".sharibako").path))
            #expect(model.statusMessage?.hasPrefix("Unprotect stopped — bento's .env is out of date.") == true)
            #expect(model.selection == .project(scopeID: "bento"))
        }
    }

    @Test("Unprotect needs a folder on this Mac, says why not, and reports a key it cannot load in the pane")
    func unprotectGuards() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("chumon", type: .machine, in: vault)
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = ProjectsTestSupport.model(vault: vault, ageKey: URL(fileURLWithPath: "/nonexistent/key.txt"))
            #expect(model.unprotectDisabledReason(forScope: nil) == "Select a project first")
            #expect(model.unprotectDisabledReason(forScope: "chumon")?.hasPrefix("Not scanned yet") == true)
            model.scanRoots = [root]
            await model.performLaunchScan()
            model.selection = .project(scopeID: "chumon")
            #expect(model.disabledReason(for: .unprotect) == WorkshopModel.noFolderToUnprotectReason)
            model.requestUnprotectSelectedProject()
            #expect(model.pendingUnprotect == nil)

            let ghost = WorkshopModel.UnprotectPlan(scopeID: "ghost", name: "ghost", directory: root, secretCount: 0)
            await model.confirmUnprotect(ghost)
            #expect(model.paneError?.nextStep == WorkshopModel.folderNotFoundNextStep)

            try ProjectsTestSupport.seedMarker(scope: "chumon", under: root, named: "chumon")
            await model.rescan()
            #expect(model.disabledReason(for: .unprotect) == nil)
            let entry = try #require(model.selectedEntry)
            await model.perform(.unprotect, on: entry)
            let plan = try #require(model.pendingUnprotect)
            #expect(plan.secretCount == 0)
            await model.confirmUnprotect(plan)
            #expect(model.paneError?.message.hasPrefix("Could not load age key") == true)
            #expect(model.paneError?.nextStep == WorkshopModel.keyLoadNextStep)
            #expect(FileManager.default.fileExists(atPath: vault.appendingPathComponent("scopes/chumon").path))
        }
    }

    // MARK: - Shared secret on a protected line

    @Test("a protected line of its own offers the shared verbs; a matched one offers its match first")
    func sharedLineVerbs() async throws {
        try await VerbsTestSupport.withProtectedProject(
            env: "DB=postgres://vault\nAPI_KEY=sk-live\n", shared: ["openai": "sk-live"]
        ) { model, _, _, _ in
            let apiKey = try #require(model.projectLines.first { $0.key == "API_KEY" })
            #expect(
                model.lineVerbs(for: apiKey) == [.reveal, .copy, .useSharedSecret, .makeSharedSecret, .deleteSecret])
            #expect(model.lineCaptionText(for: apiKey) == "in the vault")
            #expect(model.sharedMatchNote(forKey: "API_KEY") == nil)

            await model.checkDrift()
            #expect(model.sharedMatches == ["bento": ["API_KEY": "openai"]])
            #expect(
                model.lineVerbs(for: apiKey) == [
                    .reveal, .copy, .useMatchedShared(id: "openai"), .useSharedSecret, .makeSharedSecret,
                    .deleteSecret,
                ])
            #expect(model.lineCaptionText(for: apiKey) == "in the vault · same value as shared openai")
            #expect(model.sharedMatchNote(forKey: "API_KEY") == "Same value as the shared secret openai.")
            let db = try #require(model.projectLines.first { $0.key == "DB" })
            #expect(model.lineCaptionText(for: db) == "in the vault")

            let verbs: [WorkshopModel.LineVerb] = [
                .useMatchedShared(id: "openai"), .useSharedSecret, .makeSharedSecret,
            ]
            #expect(
                verbs.map(\.title) == ["Use shared secret openai", "Use shared secret…", "Make it a shared secret"])
            #expect(verbs.map(\.systemImage) == ["link", "link", "link.badge.plus"])
            #expect(verbs.allSatisfy { !$0.isDestructive && !model.isLineVerbDisabled($0) })
            model.activity = .ingesting
            #expect(verbs.allSatisfy { model.isLineVerbDisabled($0) })
            #expect(!model.isLineVerbDisabled(.copy))
            model.activity = nil
        }
    }

    @Test("Use shared secret is confirmed, then the line uses it and its own value is gone")
    func useSharedSecret() async throws {
        try await VerbsTestSupport.withProtectedProject(shared: ["openai": "sk-other"]) { model, vault, _, _ in
            model.sharedMatches = ["bento": ["API_KEY": "openai"]]
            model.openLineShareForm(.useShared, forKey: "API_KEY")
            #expect(model.lineShareForm == .init(kind: .useShared, key: "API_KEY", sharedID: "openai"))
            #expect(model.selectedLineKey == "API_KEY")
            model.submitLineShareForm()
            let plan = try #require(model.pendingSharedLink)
            #expect(WorkshopModel.sharedLinkDialogTitle(for: plan) == "Use shared secret openai?")
            #expect(
                WorkshopModel.sharedLinkDialogMessage(for: plan)
                    == "API_KEY will use the shared secret openai from now on; its own value is discarded.")

            model.dismissSharedLink()
            model.confirmUseShared(plan)
            #expect(model.secrets.first { $0.key == "API_KEY" }?.kind == .link(sharedID: "openai"))
            #expect(
                !FileManager.default.fileExists(atPath: vault.appendingPathComponent("scopes/bento/API_KEY.age").path))
            #expect(model.usedBy(sharedID: "openai").map(\.key) == ["API_KEY"])
            #expect(model.sharedMatches["bento"]?["API_KEY"] == nil)
            #expect(model.lineShareForm == nil)
            #expect(model.statusMessage == "API_KEY in bento now uses the shared secret openai.")

            model.confirmUseShared(.init(scopeID: "bento", key: "DB", sharedID: "missing"))
            #expect(model.paneError?.message == "Shared entry 'missing' not found.")
        }
    }

    @Test("Make it a shared secret saves the value under the suggested name and links the line, one key load")
    func makeSharedSecret() async throws {
        try await VerbsTestSupport.withProtectedProject(shared: ["openai": "sk-other"]) { model, vault, _, fixture in
            model.openLineShareForm(.makeShared, forKey: "DB")
            #expect(model.lineShareForm == .init(kind: .makeShared, key: "DB", sharedID: "db"))
            #expect(WorkshopModel.lineShareFormAction(.makeShared) == "Make it a shared secret")
            #expect(WorkshopModel.lineShareFormAction(.useShared) == "Use this shared secret")
            model.submitLineShareForm()

            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            #expect(try core.getSharedValue("db") == "postgres://vault")
            #expect(model.secrets.first { $0.key == "DB" }?.kind == .link(sharedID: "db"))
            #expect(model.sharedIDs.contains("db"))
            #expect(model.statusMessage == "DB is now the shared secret db; bento uses it.")
            #expect(model.lineShareForm == nil)
        }
    }

    @Test("a shared-secret name outside the grammar, or taken, is refused in the pane before any key")
    func makeSharedRefusals() async throws {
        try await VerbsTestSupport.withProtectedProject(shared: ["openai": "sk-other"]) { model, _, _, _ in
            model.makeLineShared(key: "API_KEY", as: "Bad Name")
            #expect(model.paneError?.message == "\"Bad Name\" can't name a shared secret.")
            model.makeLineShared(key: "API_KEY", as: "openai")
            #expect(model.paneError?.message == "A shared secret named openai already exists.")
            #expect(model.secrets.first { $0.key == "API_KEY" }?.kind == .value)
        }
    }

    @Test("the forms open only on a protected line of its own, and close on cancel or a new line")
    func shareFormGuards() async throws {
        try await VerbsTestSupport.withProtectedProject { model, _, _, _ in
            model.openLineShareForm(.useShared, forKey: "API_KEY")
            #expect(model.lineShareForm == nil)  // no shared secrets to use
            model.openLineShareForm(.makeShared, forKey: "NOT_A_KEY")
            #expect(model.lineShareForm == nil)
            model.requestUseShared("anything", forKey: "API_KEY")
            #expect(model.pendingSharedLink == nil)

            model.openLineShareForm(.makeShared, forKey: "API_KEY")
            #expect(model.lineShareForm?.sharedID == "api-key")
            model.cancelLineShareForm()
            #expect(model.lineShareForm == nil)
            model.openLineShareForm(.makeShared, forKey: "API_KEY")
            model.selectedLineKey = "DB"
            #expect(model.lineShareForm == nil)
            model.submitLineShareForm()
            #expect(model.statusMessage == nil)
        }
    }

    @Test("the line verbs route to their forms and confirmation")
    func lineVerbIntents() async throws {
        try await VerbsTestSupport.withProtectedProject(shared: ["openai": "sk-live"]) { model, _, _, _ in
            model.openLineShareForm(.useShared, forKey: "API_KEY")
            #expect(model.lineShareForm?.sharedID == "openai")
            model.requestUseShared("openai", forKey: "DB")
            #expect(model.pendingSharedLink == .init(scopeID: "bento", key: "DB", sharedID: "openai"))
            #expect(model.selectedLineKey == "DB")
        }
    }
}
