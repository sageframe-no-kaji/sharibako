import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// Fixtures for the ho-06.10 AT-05 gate-fix suite.
@MainActor
enum GateFixesTestSupport {
    /// An open model with a file key over a vault whose `shared` secrets
    /// (ID → value) exist, with `folders` (name → `.env` contents) under one
    /// scanned root and the first folder (by path) selected and read.
    ///
    /// Hands `body` the model, the vault, the root, and the key.
    static func withCandidates(
        _ folders: [String: String],
        shared: [String: String] = [:],
        _ body: @MainActor (WorkshopModel, URL, URL, AppAgeKeyFixture.Fixture) async throws -> Void
    ) async throws {
        try await AppAgeKeyFixture.withEphemeralKey { fixture in
            try await WorkshopTestSupport.withTempVault { vault in
                let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
                for (id, value) in shared {
                    try core.addSharedEntry(id, value: value)
                }
                let root = try ProjectsTestSupport.makeRoot(near: vault)
                defer { try? FileManager.default.removeItem(at: root) }
                for (name, env) in folders {
                    try ProjectsTestSupport.writeEnv(env, in: root.appendingPathComponent(name))
                }
                let model = ProjectsTestSupport.model(vault: vault, ageKey: fixture.privateKeyURL)
                model.loadScopes()
                model.scanRoots = [root]
                await model.performLaunchScan()
                await model.loadContent(for: model.selection)
                try await body(model, vault, root, fixture)
            }
        }
    }

    /// The candidate folder named `name`, or `nil`.
    static func candidate(_ name: String, in model: WorkshopModel) -> URL? {
        model.candidates.first { $0.lastPathComponent == name }
    }
}

/// ho-06.10 AT-05 tests: the gate's first round of findings.
///
/// The header's words, settings-only folders, the visible recommendation,
/// the shared-secret popover's state, and the blank-page sequence. The
/// shared-value question at Protect time is `WorkshopModelSharedValuesTests`.
///
/// Real temp vaults with the file-key dev path (no Keychain); asserting the
/// model's state and the files on disk, never rendering.
@MainActor
@Suite("WorkshopModel Gate fixes")
struct WorkshopModelGateFixesTests {
    // MARK: - Header words

    @Test("the header says not protected, nothing to protect, or how many are left, singular handled")
    func headerWords() async throws {
        #expect(
            WorkshopModel.ProjectHeaderState.notProtected(count: 1).label
                == "Project not protected — 1 secret in plain text")
        #expect(
            WorkshopModel.ProjectHeaderState.nothingToProtect(settings: 1).label
                == "No secrets to protect — 1 setting in .env")
        #expect(WorkshopModel.ProjectHeaderState.unprotected(count: 1).label == "1 secret not protected")
        try await GateFixesTestSupport.withCandidates(["cfg": "PORT=3000\nDEBUG=true\n"]) { model, _, _, _ in
            #expect(model.headerState == .nothingToProtect(settings: 2))
            #expect(model.headerState.label == "No secrets to protect — 2 settings in .env")
            #expect(!model.headerState.offersProtect)
            #expect(model.headerState.symbolName == "minus.circle")
            #expect(model.headerState.markPalette == Theme.inkTertiary)
        }
    }

    // MARK: - Settings-only folders

    @Test("a folder holding only settings reads No secrets in the sidebar, and its Protect is off")
    func settingsOnlyFolder() async throws {
        try await GateFixesTestSupport.withCandidates(
            ["cfg": "PORT=3000\nDEBUG=true\n", "app": "API_KEY=sk-1\nPORT=1\n"]
        ) { model, _, _, _ in
            let cfg = try #require(GateFixesTestSupport.candidate("cfg", in: model))
            let app = try #require(GateFixesTestSupport.candidate("app", in: model))
            #expect(model.candidateSummary(for: cfg)?.secrets == 0)
            #expect(model.candidateSummary(for: cfg)?.settings == 2)
            #expect(model.candidateSummary(for: app)?.secrets == 1)

            let section = try #require(model.projectSections.first { $0.id == .notProtected })
            let cfgRow = try #require(section.entries.first { $0.name == "cfg" })
            let appRow = try #require(section.entries.first { $0.name == "app" })
            #expect(cfgRow.status == .noSecrets)
            #expect(appRow.status == .notProtected)
            #expect(cfgRow.status.label == "No secrets")
            #expect(cfgRow.status.helpText == "No secrets to protect — only settings in .env")
            #expect(cfgRow.status.symbolName == "minus.circle")
            #expect(cfgRow.status.glyphPalette == Theme.inkTertiary)
            #expect(section.offersProtectAll)

            #expect(model.disabledReason(for: .protect, on: cfgRow) == "No secrets to protect")
            #expect(model.disabledReason(for: .protect, on: appRow) == nil)
            model.selection = cfgRow.id
            #expect(model.help(for: .protect) == WorkshopModel.noSecretsToProtectReason)

            model.removeCandidate(cfg)
            #expect(model.candidateSummary(for: cfg) == nil)
            model.clearScanCaches()
            #expect(model.candidateSummaries.isEmpty)
        }
    }

    @Test("a Not-protected section of settings-only folders offers no Protect all, and Protect all skips them")
    func protectAllSkipsSettingsOnly() async throws {
        try await GateFixesTestSupport.withCandidates(["cfg": "PORT=3000\n"]) { model, vault, _, _ in
            let section = try #require(model.projectSections.first { $0.id == .notProtected })
            #expect(!section.offersProtectAll)
            // Even a line flipped to protect leaves the folder to its own page.
            model.setLineChoice(.protectLocal, forKey: "PORT")
            #expect(model.protectableLineCount == 1)

            await model.protectAllCandidates()

            #expect(model.statusMessage == WorkshopModel.nothingToProtect(in: nil))
            #expect(try VaultCore(vaultURL: vault).listScopes().isEmpty)
            #expect(model.candidates.count == 1)
        }
    }

    @Test("a folder that cannot be read is left out of the summaries")
    func summariesSkipUnreadable() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let odd = root.appendingPathComponent("odd")
            try FileManager.default.createDirectory(
                at: odd.appendingPathComponent(".env"), withIntermediateDirectories: true)
            let ok = root.appendingPathComponent("ok")
            try ProjectsTestSupport.writeEnv("TOKEN=t-1\nTOKEN=t-2\nPORT=2\n", in: ok)
            let summaries = EnvReader.summaries(of: [odd, ok], vaultURL: vault)
            #expect(summaries[odd.standardizedFileURL] == nil)
            #expect(summaries[ok.standardizedFileURL]?.secrets == 1)
            #expect(summaries[ok.standardizedFileURL]?.settings == 1)
        }
    }

    // MARK: - The recommendation

    @Test("every line not in the vault shows its recommendation in its caption")
    func recommendationCaptions() async throws {
        try await GateFixesTestSupport.withCandidates(["app": "API_KEY=sk-1\nPORT=3000\n"]) { model, _, _, _ in
            let captions = model.projectLines.map { model.lineCaptionText(for: $0) }
            #expect(captions.count == 2)
            #expect(captions[0] == "Recommended: protect — key ends in KEY")
            #expect(captions[1].hasPrefix("Recommended: leave as setting — "))
            let setting = try #require(model.settingLines.first)
            #expect(
                model.lineChoiceTitle(.leaveAsSetting, for: setting) == "Leave in .env as a setting (recommended)")
            #expect(model.lineChoiceTitle(.protectLocal, for: setting) == "Protect for this project")
        }
    }

    /// A line not in the vault, with `recommended` as the classifier's default.
    private static func line(
        _ key: String,
        lineClass: LineClass?,
        reason: String? = nil,
        recommended: WorkshopModel.LineChoice?
    ) -> WorkshopModel.ProjectLine {
        WorkshopModel.ProjectLine(
            key: key,
            value: "v",
            status: lineClass?.isSecret == false ? .setting : .notProtected,
            lineClass: lineClass,
            reason: reason,
            choice: recommended,
            recommended: recommended
        )
    }

    @Test("a caption without a reason is the bare tag; the mark follows the default, sub-picker included")
    func recommendationEdges() async throws {
        let bare = Self.line("K", lineClass: .secret(.keyEndsInKey), recommended: .protectLocal)
        #expect(WorkshopModel.lineCaption(for: bare) == "Recommended: protect")
        let unclassed = Self.line("K", lineClass: nil, recommended: nil)
        #expect(WorkshopModel.lineCaption(for: unclassed).isEmpty)
        try await WorkshopTestSupport.withTempVault { vault in
            let model = ProjectsTestSupport.model(vault: vault)
            let named = Self.line(
                "openai-api-key", lineClass: .secret(.sharedNameMatch), recommended: .useShared(id: "openai-api-key"))
            #expect(
                model.lineChoiceTitle(.useShared(id: "openai-api-key"), for: named)
                    == "Use shared secret openai-api-key (recommended)")
            #expect(model.lineChoiceTitle(.protectLocal, for: named) == "Protect for this project")
            for id in ["a1", "b2", "c3", "d4"] {
                try "ciphertext".write(
                    to: vault.appendingPathComponent("shared/\(id).age"), atomically: true, encoding: .utf8)
            }
            model.loadScopes()
            #expect(model.usesSharedIDSubPicker)
            let matched = Self.line("A1", lineClass: .secret(.keyEndsInKey), recommended: .useShared(id: "a1"))
            #expect(model.lineChoiceTitle(.useShared(id: "b2"), for: matched) == "Use a shared secret (recommended)")
            #expect(model.lineChoiceTitle(.useShared(id: "b2"), for: bare) == "Use a shared secret")
        }
    }

    // MARK: - The shared-secret popover

    @Test("the form opens at its anchor, and its note says what is wrong with the name")
    func lineSharePopoverState() async throws {
        try await VerbsTestSupport.withProtectedProject(shared: ["openai": "sk-other"]) { model, _, _, _ in
            model.openLineShareForm(.makeShared, forKey: "DB", anchor: .line)
            #expect(model.lineShareForm == .init(kind: .makeShared, key: "DB", sharedID: "db", anchor: .line))
            #expect(model.isLineShareFormOpen(at: .line, forKey: "DB"))
            #expect(!model.isLineShareFormOpen(at: .detail, forKey: "DB"))
            #expect(!model.isLineShareFormOpen(at: .line, forKey: "API_KEY"))
            #expect(model.lineShareFormProblem == nil)
            #expect(
                WorkshopModel.lineShareFormHint(.makeShared)
                    == "Saved as a shared secret other projects can use — one Touch ID.")

            model.lineShareForm?.sharedID = " "
            #expect(model.lineShareFormProblem == "Name the shared secret.")
            model.lineShareForm?.sharedID = "Bad Name"
            #expect(model.lineShareFormProblem == "Use lowercase letters, digits, dots, and dashes.")
            model.lineShareForm?.sharedID = "openai"
            #expect(model.lineShareFormProblem == "A shared secret named openai already exists.")

            model.openLineShareForm(.useShared, forKey: "API_KEY")
            #expect(model.isLineShareFormOpen(at: .detail, forKey: "API_KEY", kind: .useShared))
            #expect(!model.isLineShareFormOpen(at: .detail, forKey: "API_KEY", kind: .makeShared))
            #expect(model.lineShareFormProblem == nil)
            #expect(
                WorkshopModel.lineShareFormHint(.useShared)
                    == "This line uses it from now on; its own value is discarded.")
            model.lineShareForm?.sharedID = "gone"
            #expect(model.lineShareFormProblem == "Pick one of the vault's shared secrets.")

            model.cancelLineShareForm()
            #expect(model.lineShareFormProblem == nil)
            #expect(!model.isLineShareFormOpen(at: .detail, forKey: "API_KEY"))
        }
    }

    // MARK: - The blank page

    @Test("make a line a shared secret, then deselect it: the page stays read")
    func blankPageSequence() async throws {
        let env = "DB=postgres://vault\nAPI_KEY=sk-live\nPORT=3000\n"
        try await VerbsTestSupport.withProtectedProject(env: env) { model, _, _, _ in
            #expect(model.areLinesLoaded)
            model.openLineShareForm(.makeShared, forKey: "DB", anchor: .line)
            model.submitLineShareForm()
            #expect(model.secrets.first { $0.key == "DB" }?.kind == .link(sharedID: "db"))
            model.selectedLineKey = nil

            #expect(model.areLinesLoaded)
            #expect(model.selectedEntry?.name == "bento")
            #expect(model.detailPane == .empty)
            #expect(model.projectLines.map(\.key) == ["DB", "API_KEY", "PORT"])
            #expect(model.headerState == .protected(upToDate: nil))
        }
    }

    @Test("a selection that leaves and comes back clears the lines and changes the load key, so they load again")
    func selectionRoundTripReloads() async throws {
        try await VerbsTestSupport.withProtectedProject(env: "DB=postgres://vault\n") { model, _, _, _ in
            let before = model.linesLoadID
            #expect(model.areLinesLoaded)
            // A List re-asserting its binding through nil inside one update.
            let row = model.selection
            model.selection = nil
            model.selection = row

            #expect(!model.areLinesLoaded)
            #expect(model.linesLoadID != before)
            #expect(model.linesLoadID.selection == row)
            // What the window's `.task(id: linesLoadID)` runs on the change.
            await model.loadContent(for: model.selection)
            #expect(model.areLinesLoaded)
            #expect(model.projectLines.map(\.key) == ["DB", "API_KEY"])
        }
    }
}
