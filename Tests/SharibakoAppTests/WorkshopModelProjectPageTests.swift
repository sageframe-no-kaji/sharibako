import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// ho-06.10 AT-03 tests for the one project page's reads
/// (`WorkshopModel+Pages.swift`, `Color+Theme.swift`): the header's mark,
/// words, and button; a line's mark, value, caption, and status words; the
/// settings fold; which detail pane shows and where a pane error renders; and
/// the plain-words choice with its options, sub-picker, and note.
///
/// `ProjectPage` and `LineDetail` are coverage-excluded declarative bodies;
/// everything they branch on is specified here. The right-click verbs and the
/// line intents are in `WorkshopModelLineVerbsTests.swift` (the split is
/// SwiftLint's `type_body_length` ceiling). Keyless temp vaults and roots
/// only — no live user state, no Keychain.
@MainActor
@Suite("WorkshopModel Project page")
struct WorkshopModelProjectPageTests {
    /// A line with `status`, a value, and — off the vault — a class and choice.
    static func line(
        _ key: String,
        _ status: WorkshopModel.LineStatus,
        value: String? = "v",
        choice: WorkshopModel.LineChoice? = nil
    ) -> WorkshopModel.ProjectLine {
        let inVault = status.isInVault
        let lineClass: LineClass? = inVault ? nil : (status == .setting ? .setting(.number) : .secret(.keyEndsInKey))
        return WorkshopModel.ProjectLine(
            key: key,
            value: inVault ? nil : value,
            status: status,
            lineClass: lineClass,
            reason: lineClass?.reason.explanation,
            choice: inVault ? nil : (choice ?? (status == .setting ? .leaveAsSetting : .protectLocal)),
            recommended: inVault ? nil : (status == .setting ? .leaveAsSetting : .protectLocal)
        )
    }

    /// A folder not yet protected under a fresh root beside `vault`, selected
    /// and read.
    static func candidatePage(
        vault: URL, env: String, sharedIDs: [String] = []
    ) async throws -> (model: WorkshopModel, root: URL) {
        for id in sharedIDs {
            try "ciphertext".write(
                to: vault.appendingPathComponent("shared/\(id).age"), atomically: true, encoding: .utf8)
        }
        let root = try ProjectsTestSupport.makeRoot(near: vault)
        let acme = root.appendingPathComponent("acme")
        try ProjectsTestSupport.writeEnv(env, in: acme)
        let model = ProjectsTestSupport.model(vault: vault)
        model.loadScopes()
        model.selection = .candidate(directory: acme)
        await model.loadContent(for: model.selection)
        return (model, root)
    }

    // MARK: - Header (pure)

    @Test("the header offers Protect only while secrets are exposed, and splits out the out-of-date clause")
    func headerStateParts() {
        let states: [WorkshopModel.ProjectHeaderState] = [
            .unprotected(count: 2), .protected(upToDate: nil), .protected(upToDate: true),
            .protected(upToDate: false, differing: 1), .protected(upToDate: false, differing: 3), .empty,
            .notProtected(count: 3), .nothingToProtect(settings: 4),
        ]
        #expect(states.map(\.offersProtect) == [true, false, false, false, false, false, true, false])
        #expect(states.map(\.alarmClause) == [nil, nil, nil, "1 line differs", "3 lines differ", nil, nil, nil])
        #expect(
            states.map(\.steadyLabel) == [
                "2 secrets not protected", "Protected", "Protected · up to date", "Protected", "Protected",
                "No lines", "Project not protected — 3 secrets in plain text",
                "No secrets to protect — 4 settings in .env",
            ])
        // The two parts always rebuild the whole label.
        for state in states {
            let rebuilt = state.steadyLabel + (state.alarmClause.map { " · \($0)" } ?? "")
            #expect(rebuilt == state.label)
        }
        #expect(
            states.map(\.markPalette) == [
                Theme.alarm, Theme.inSync, Theme.inSync, Theme.inSync, Theme.inSync, Theme.inkTertiary,
                Theme.alarm, Theme.inkTertiary,
            ])
        #expect(
            states.map(\.labelPalette) == [
                Theme.ink, Theme.ink, Theme.ink, Theme.ink, Theme.ink, Theme.inkTertiary, Theme.ink, Theme.ink,
            ])
        #expect(
            states.map(\.symbolName) == [
                "xmark.octagon.fill", "checkmark.circle.fill", "checkmark.circle.fill", "checkmark.circle.fill",
                "checkmark.circle.fill", "circle.dashed", "xmark.octagon.fill", "minus.circle",
            ])
    }

    // MARK: - One line (pure)

    @Test("each status has its mark, its tints, and its words")
    func lineMarksAndWords() {
        let statuses: [WorkshopModel.LineStatus] = [
            .protected(kind: .value), .notProtected, .missingFromEnv, .setting,
        ]
        #expect(
            statuses.map { WorkshopModel.lineRowSymbol(for: $0) } == [
                "lock.fill", "lock.open.fill", "lock.slash", "circle.fill",
            ])
        #expect(statuses.map(\.rowPalette) == [Theme.inSync, Theme.alarm, Theme.inkTertiary, Theme.inkTertiary])
        #expect(statuses.map(\.keyPalette) == [Theme.ink, Theme.ink, Theme.ink, Theme.inkSecondary])
        #expect(
            statuses.map(\.captionPalette) == [
                Theme.inkSecondary, Theme.inkSecondary, Theme.inkSecondary, Theme.inkTertiary,
            ])
        #expect(
            statuses.map { WorkshopModel.lineStatusLabel(for: Self.line("K", $0)) } == [
                "Protected", "Not protected — in .env in plain text", "Protected — not in .env",
                "Setting — left in .env in plain text",
            ])
    }

    @Test("a value shows in plain text off the vault, (empty) when empty, and masked in the vault")
    func lineValues() {
        #expect(WorkshopModel.lineValueText(for: Self.line("K", .notProtected, value: "sk-live")) == "sk-live")
        #expect(WorkshopModel.lineValueText(for: Self.line("K", .setting, value: "")) == "(empty)")
        #expect(WorkshopModel.lineValueText(for: Self.line("K", .protected(kind: .value))) == "••••••••")
        #expect(WorkshopModel.lineValueText(for: Self.line("K", .missingFromEnv)) == WorkshopModel.maskedValue)
    }

    @Test("a caption tags the recommendation and its reason off the vault, and where the vault holds it otherwise")
    func lineCaptions() {
        #expect(
            WorkshopModel.lineCaption(for: Self.line("API_KEY", .notProtected))
                == "Recommended: protect — key ends in KEY")
        #expect(
            WorkshopModel.lineCaption(for: Self.line("PORT", .setting))
                == "Recommended: leave as setting — \(LineClass.setting(.number).reason.explanation)")
        #expect(WorkshopModel.recommendationTag(for: Self.line("K", .protected(kind: .value))) == nil)
        #expect(WorkshopModel.lineCaption(for: Self.line("K", .protected(kind: .value))) == "in the vault")
        #expect(
            WorkshopModel.lineCaption(for: Self.line("K", .protected(kind: .link(sharedID: "anthropic"))))
                == "in the vault · shared secret anthropic")
        #expect(WorkshopModel.lineCaption(for: Self.line("K", .missingFromEnv)) == "in the vault, not in .env")
    }

    @Test("the choice's note and action words follow whether it protects")
    func choiceNoteAndAction() {
        let local = Self.line("K", .notProtected, choice: .protectLocal)
        let shared = Self.line("K", .notProtected, choice: .useShared(id: "openai"))
        let made = Self.line("K", .notProtected, choice: .makeShared(id: "k"))
        let left = Self.line("K", .notProtected, choice: .leaveAsSetting)
        #expect(WorkshopModel.lineChoiceNote(for: local) == nil)
        #expect(WorkshopModel.lineChoiceNote(for: shared) == nil)
        #expect(
            WorkshopModel.lineChoiceNote(for: made) == "Saved as the shared secret k, so other projects can use it.")
        #expect(WorkshopModel.lineChoiceNote(for: left) == "Stays in .env in plain text. Sharibako leaves it alone.")
        #expect(WorkshopModel.lineChoiceNote(for: Self.line("K", .protected(kind: .value))) == nil)
        #expect([local, shared, made, left].map { WorkshopModel.lineOffersProtect($0) } == [true, true, true, false])
        #expect(WorkshopModel.lineActionTitle(for: local) == "Protect this line")
        #expect(WorkshopModel.lineActionTitle(for: left) == "Leave in .env")
    }

    @Test("a shared secret's suggested name is the key in the identifier grammar, suffixed on collision")
    func suggestedSharedIDs() {
        #expect(WorkshopModel.suggestedSharedID(forKey: "OPENAI_API_KEY", existing: []) == "openai-api-key")
        #expect(WorkshopModel.suggestedSharedID(forKey: "_X", existing: []) == "x")
        #expect(WorkshopModel.suggestedSharedID(forKey: "___", existing: []) == "shared")
        #expect(WorkshopModel.suggestedSharedID(forKey: "A_B", existing: ["a-b"]) == "a-b-2")
        #expect(WorkshopModel.suggestedSharedID(forKey: "A_B", existing: ["a-b", "a-b-2"]) == "a-b-3")
    }

    @Test("only a Not-protected section with rows offers Protect all")
    func protectAllOffer() {
        let folder = URL(fileURLWithPath: "/tmp/a")
        let entry = WorkshopModel.ProjectEntry(
            id: .candidate(directory: folder), name: "a", directory: folder, scopeID: nil, status: .notProtected)
        #expect(WorkshopModel.ProjectSection(id: .notProtected, entries: [entry]).offersProtectAll)
        #expect(!WorkshopModel.ProjectSection(id: .notProtected, entries: []).offersProtectAll)
        #expect(!WorkshopModel.ProjectSection(id: .projects, entries: [entry]).offersProtectAll)
    }

    // MARK: - The page, loaded

    @Test("a folder's page: reading until loaded, then the Protect button, the fold, and the panes")
    func candidatePageReads() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let acme = root.appendingPathComponent("acme")
            try ProjectsTestSupport.writeEnv(
                "API_KEY=sk\nDB_PASSWORD=hunter2\nPORT=3000\nDEBUG=true\n", in: acme)
            let model = ProjectsTestSupport.model(vault: vault)
            #expect(!model.areLinesLoaded)
            model.selection = .candidate(directory: acme)
            #expect(!model.areLinesLoaded)

            await model.loadContent(for: model.selection)

            #expect(model.areLinesLoaded)
            #expect(model.headerState.offersProtect)
            #expect(model.protectButtonTitle == "Protect 2 secrets")
            #expect(!model.isProtectButtonDisabled)
            #expect(model.protectButtonHelp.hasPrefix("Move the chosen secrets"))
            #expect(model.settingsFoldLabel == "2 settings left in .env")
            #expect(model.detailPane == .empty)

            model.setLineChoice(.leaveAsSetting, forKey: "DB_PASSWORD")
            #expect(model.protectButtonTitle == "Protect 1 secret")
            model.setLineChoice(.leaveAsSetting, forKey: "API_KEY")
            #expect(model.protectButtonTitle == "Protect 0 secrets")
            #expect(model.isProtectButtonDisabled)
            #expect(model.protectButtonHelp.hasPrefix("Every line is set to stay in .env"))
            model.setLineChoice(.protectLocal, forKey: "API_KEY")
            model.activity = .scanning
            #expect(model.isProtectButtonDisabled)
            model.activity = nil

            model.selectedLineKey = "API_KEY"
            #expect(model.detailPane == .line)
            model.selectedLineKey = "PORT"
            #expect(model.detailPane == .line)

            // A new selection is not loaded until its own read lands.
            model.selection = nil
            #expect(!model.areLinesLoaded)
        }
    }

    @Test("one setting reads singular; a protected line shows the secret pane; off a page, nothing")
    func detailPanes() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("nest", type: .other, in: vault)
            try LinesTestSupport.writeVaultKey("API_KEY", scope: "nest", in: vault)
            try LinesTestSupport.writeVaultKey("GONE_TOKEN", scope: "nest", in: vault)
            let root = try ProjectsTestSupport.makeRoot(near: vault)
            defer { try? FileManager.default.removeItem(at: root) }
            let dir = try ProjectsTestSupport.seedMarker(scope: "nest", under: root, named: "nest")
            try ProjectsTestSupport.writeEnv("API_KEY=sk\nPORT=3000\n", in: dir)
            let model = ProjectsTestSupport.model(vault: vault)
            model.scanRoots = [root]
            await model.performLaunchScan()
            model.selection = .project(scopeID: "nest")
            await model.loadContent(for: model.selection)

            #expect(model.settingsFoldLabel == "1 setting left in .env")
            #expect(!model.headerState.offersProtect)
            model.selectedLineKey = "API_KEY"
            #expect(model.detailPane == .secret)
            model.selectedLineKey = "GONE_TOKEN"
            #expect(model.detailPane == .secret)
            model.selectedLineKey = "NOT_A_LINE"
            #expect(model.detailPane == .empty)

            model.selection = .shared(id: "anthropic")
            #expect(model.detailPane == .empty)
        }
    }

    @Test("a pane error renders once: in the detail pane while it shows a line, else in the page header")
    func paneErrorPlacement() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let (model, root) = try await Self.candidatePage(vault: vault, env: "API_KEY=sk\n")
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(model.paneError(in: .page) == nil)
            #expect(model.paneError(in: .detail) == nil)

            model.reportPaneError("Could not protect acme: boom", nextStep: "Try again")
            let error = WorkshopModel.PaneError(message: "Could not protect acme: boom", nextStep: "Try again")
            #expect(model.paneError(in: .page) == error)
            #expect(model.paneError(in: .detail) == nil)

            model.selectedLineKey = "API_KEY"
            #expect(model.paneError(in: .page) == nil)
            #expect(model.paneError(in: .detail) == error)
        }
    }

    // MARK: - The choice

    @Test("with up to three shared secrets the choice lists each; Make shared carries a free name")
    func choiceOptionsFewShared() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let (model, root) = try await Self.candidatePage(
                vault: vault, env: "OPENAI_API_KEY=sk\nPORT=3000\n", sharedIDs: ["anthropic", "openai-api-key"])
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(!model.usesSharedIDSubPicker)
            let secret = try #require(model.projectLines.first { $0.key == "OPENAI_API_KEY" })
            #expect(
                model.lineChoiceOptions(for: secret) == [
                    .protectLocal, .useShared(id: "anthropic"), .useShared(id: "openai-api-key"),
                    .makeShared(id: "openai-api-key-2"), .leaveAsSetting,
                ])
            #expect(model.lineChoiceTitle(.useShared(id: "anthropic"), for: secret) == "Use shared secret anthropic")
            // The classifier's default is the one marked.
            #expect(secret.recommended == .protectLocal)
            #expect(
                model.lineChoiceTitle(.protectLocal, for: secret) == "Protect for this project (recommended)")
            let setting = try #require(model.projectLines.first { $0.key == "PORT" })
            #expect(
                model.lineChoiceTitle(.leaveAsSetting, for: setting) == "Leave in .env as a setting (recommended)")
            #expect(model.sharedSubPickerID(for: secret) == nil)

            // A chosen name stays the option's name.
            model.setLineChoice(.makeShared(id: "openai"), forKey: "OPENAI_API_KEY")
            let flipped = try #require(model.projectLines.first { $0.key == "OPENAI_API_KEY" })
            #expect(model.lineChoiceOptions(for: flipped)[3] == .makeShared(id: "openai"))

            // A line in the vault has no choice to offer.
            #expect(model.lineChoiceOptions(for: Self.line("K", .protected(kind: .value))).isEmpty)
        }
    }

    @Test("a current shared choice the vault no longer lists is still offered")
    func choiceOptionsKeepCurrent() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let (model, root) = try await Self.candidatePage(vault: vault, env: "TOKEN=t-1\n")
            defer { try? FileManager.default.removeItem(at: root) }
            let line = Self.line("TOKEN", .notProtected, choice: .useShared(id: "gone"))
            #expect(
                model.lineChoiceOptions(for: line) == [
                    .protectLocal, .useShared(id: "gone"), .makeShared(id: "token"), .leaveAsSetting,
                ])
        }
    }

    @Test("with more than three shared secrets the choice offers one shared option and a picker of names")
    func choiceOptionsManyShared() async throws {
        try await WorkshopTestSupport.withTempVault { vault in
            let (model, root) = try await Self.candidatePage(
                vault: vault, env: "TOKEN=t-1\n", sharedIDs: ["a1", "b2", "c3", "d4"])
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(model.usesSharedIDSubPicker)
            let line = try #require(model.projectLines.first)
            #expect(
                model.lineChoiceOptions(for: line) == [
                    .protectLocal, .useShared(id: "a1"), .makeShared(id: "token"), .leaveAsSetting,
                ])
            #expect(model.lineChoiceTitle(.useShared(id: "a1"), for: line) == "Use a shared secret")
            #expect(model.lineChoiceTitle(.protectLocal, for: line) == "Protect for this project (recommended)")
            #expect(model.sharedSubPickerID(for: line) == nil)

            model.setLineChoice(.useShared(id: "c3"), forKey: "TOKEN")
            let chosen = try #require(model.projectLines.first)
            #expect(model.sharedSubPickerID(for: chosen) == "c3")
            #expect(model.lineChoiceOptions(for: chosen)[1] == .useShared(id: "c3"))
        }
    }
}
