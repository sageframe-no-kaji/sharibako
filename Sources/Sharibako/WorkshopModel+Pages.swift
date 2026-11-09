import Foundation
import SharibakoCore

/// The words and reads the project-first views render (ho-06.9 AT-02,
/// Decisions 8–9; ho-06.10 AT-03, Decisions 6–7).
///
/// `ProjectSidebar`, `ProjectPage`, `LineDetail`, and the two status pages
/// (`ProblemPage`, `SharedSecretPage`) are declarative and
/// coverage-excluded, so every count-aware phrase and every fallback lives
/// here, tested, rather than in a `View` body. Each string is built from
/// kamae-2.3 §2's ten words. What to load when the selection changes
/// (``loadContent(for:)``) moved to `WorkshopModel+Lines.swift` with the
/// lines it fills (ho-06.10 AT-02).
///
/// Pure reads over state `WorkshopModel.swift` already owns. Kept
/// in its own file, the `Conduit`/`Conduit+Remote.swift` split precedent, so
/// `WorkshopModel.swift` stays under SwiftLint's `file_length` ceiling.
extension WorkshopModel {
    // MARK: - The selected row

    /// The row behind ``selection``, or `nil` when nothing is selected or the
    /// selected thing has gone (protected, forgotten, or deleted since it was
    /// picked).
    ///
    /// The content column renders a page only while this is non-`nil`, so a
    /// row that vanishes under the selection never leaves its page behind.
    var selectedEntry: ProjectEntry? {
        selection.flatMap { projectEntry(for: $0) }
    }

    /// The content column's navigation title: the selected row's name, or
    /// "Projects" with nothing selected (Discovery: the title moves off the
    /// scope ID and onto the project's name, for every kind of row).
    var selectionTitle: String {
        selectedEntry?.name ?? "Projects"
    }

    // MARK: - The project page (ho-06.10 AT-03, Decision 6)

    /// What the detail column shows for the project page's selected line.
    enum DetailPane: Equatable {
        /// A line in the vault: `SecretDetail` (value behind Reveal).
        case secret
        /// A line not in the vault — not protected, or a setting: `LineDetail`.
        case line
        /// Nothing selected, a row that is not a project page, or a line the
        /// page has not read yet: the empty ground.
        case empty
    }

    /// Which pane renders ``paneError``, so one failure shows once.
    enum PaneErrorHost: Equatable {
        /// The project page's header, under its state row.
        case page
        /// The detail column — `SecretDetail` or `LineDetail`.
        case detail
    }

    /// `true` once the selected page's lines read has landed — the page says
    /// it is reading until then instead of flashing "No lines".
    var areLinesLoaded: Bool {
        selection != nil && loadedLinesSelection == selection
    }

    /// The detail column's pane for the selected line (Required Change 4):
    /// `SecretDetail` for a line in the vault, `LineDetail` for one that is
    /// not, empty otherwise — and always empty off a project page.
    var detailPane: DetailPane {
        switch selection {
        case .project, .candidate:
            guard let line = selectedLine else { return .empty }
            return line.status.isInVault ? .secret : .line
        case .problem, .shared, nil:
            return .empty
        }
    }

    /// The pane error for `host`: the detail column's while it shows a line,
    /// else the page header's — never both (ho-06.10 Decision 8).
    ///
    /// An action's own failure wins; otherwise a project the last Check all
    /// could not read shows why, with its next step (AT-04).
    func paneError(in host: PaneErrorHost) -> PaneError? {
        let error = paneError ?? selectedProjectCheckError
        let detailShowing = detailPane != .empty
        switch host {
        case .page: return detailShowing ? nil : error
        case .detail: return detailShowing ? error : nil
        }
    }

    /// A page's location line: `directory` abbreviated against home, or "No
    /// folder on this Mac" when the row has none.
    func pageLocation(for directory: URL?) -> String {
        guard let directory else { return ProjectStatus.noFolderHere.label }
        return abbreviatedPath(directory)
    }

    /// The header's one button: "Protect 3 secrets", count-aware, counting
    /// the lines Protect would put in the vault with the current choices.
    var protectButtonTitle: String {
        protectableLineCount == 1 ? "Protect 1 secret" : "Protect \(protectableLineCount) secrets"
    }

    /// Whether the header's button is off: while an operation runs, or when
    /// every line is set to stay in `.env`.
    var isProtectButtonDisabled: Bool {
        activity != nil || protectableLineCount == 0
    }

    /// The header button's tooltip.
    var protectButtonHelp: String {
        protectableLineCount == 0
            ? "Every line is set to stay in .env — choose a line and pick Protect first"
            : "Move the chosen secrets into the vault — one Touch ID; settings stay in .env"
    }

    /// The settings fold's row: "7 settings left in .env", count-aware.
    var settingsFoldLabel: String {
        settingLines.count == 1 ? "1 setting left in .env" : "\(settingLines.count) settings left in .env"
    }

    /// The page's empty state, when the project has no lines at all.
    static let noLinesDescription = "This project has no .env lines and nothing in the vault."

    /// What a protected line's value shows until Reveal (Do Not: never the
    /// value itself).
    static let maskedValue = "••••••••"

    // MARK: - One line (pure)

    /// The row's status mark (Decision 6): a closed lock in the vault, an
    /// open lock in plain text, a struck lock for a vault line missing from
    /// `.env`, and a dot for a setting.
    static func lineRowSymbol(for status: LineStatus) -> String {
        switch status {
        case .protected: return "lock.fill"
        case .notProtected: return "lock.open.fill"
        case .missingFromEnv: return "lock.slash"
        case .setting: return "circle.fill"
        }
    }

    /// The line's status in words — the detail pane's status line and the
    /// row's tooltip.
    static func lineStatusLabel(for line: ProjectLine) -> String {
        switch line.status {
        case .protected: return "Protected"
        case .notProtected: return "Not protected — in .env in plain text"
        case .setting: return "Setting — left in .env in plain text"
        case .missingFromEnv: return "Protected — not in .env"
        }
    }

    /// The value as the row and the detail pane show it: the `.env` value,
    /// "(empty)" for an empty one, or ``maskedValue`` for a line in the vault.
    static func lineValueText(for line: ProjectLine) -> String {
        guard !line.status.isInVault, let value = line.value else { return maskedValue }
        return value.isEmpty ? "(empty)" : value
    }

    /// The row's caption: the recommendation and its reason for a line not in
    /// the vault ("secret — key ends in KEY"), else where the vault holds it.
    static func lineCaption(for line: ProjectLine) -> String {
        switch line.status {
        case .protected(.value): return "in the vault"
        case .protected(.link(let sharedID)): return "in the vault · shared secret \(sharedID)"
        case .missingFromEnv: return "in the vault, not in .env"
        case .notProtected, .setting: return line.classLabel ?? ""
        }
    }

    // MARK: - The line's choice (Decision 7)

    /// The detail pane's question over the choice.
    static let lineChoiceQuestion = "What should Sharibako do?"

    /// `true` when the vault has more than three shared secrets: the choice
    /// offers one "Use a shared secret" option and a second picker of IDs.
    var usesSharedIDSubPicker: Bool {
        sharedIDs.count > 3
    }

    /// The choices offered for `line`, in the picker's order.
    ///
    /// Protect for this project; Use shared secret, one per ID (or one, with
    /// the sub-picker); Make it a shared secret, under the line's current or
    /// suggested name; Leave in `.env`. Empty for a line in the vault, which
    /// has no choice.
    ///
    /// The line's current choice is always among them, so the picker always
    /// has its selection.
    func lineChoiceOptions(for line: ProjectLine) -> [LineChoice] {
        guard let current = line.choice else { return [] }
        var shared: [LineChoice]
        if usesSharedIDSubPicker {
            if case .useShared = current {
                shared = [current]
            } else {
                shared = sharedIDs.prefix(1).map { .useShared(id: $0) }
            }
        } else {
            shared = sharedIDs.map { .useShared(id: $0) }
            if case .useShared = current, !shared.contains(current) {
                shared.insert(current, at: 0)
            }
        }
        return [.protectLocal] + shared + [makeSharedChoice(for: line), .leaveAsSetting]
    }

    /// The words for `choice` in the detail pane's picker: its label, or "Use
    /// a shared secret" when the sub-picker names the ID.
    func lineChoiceTitle(_ choice: LineChoice) -> String {
        if usesSharedIDSubPicker, case .useShared = choice { return "Use a shared secret" }
        return choice.label
    }

    /// The shared secret the sub-picker shows as chosen, or `nil` when there
    /// is no sub-picker or the line is not using a shared secret.
    func sharedSubPickerID(for line: ProjectLine) -> String? {
        guard usesSharedIDSubPicker, case .useShared(let id) = line.choice else { return nil }
        return id
    }

    /// A sentence under the choice saying what it will do, when the label
    /// alone does not.
    static func lineChoiceNote(for line: ProjectLine) -> String? {
        switch line.choice {
        case .makeShared(let id):
            return "Saved as the shared secret \(id), so other projects can use it."
        case .leaveAsSetting:
            return "Stays in .env in plain text. Sharibako leaves it alone."
        case .protectLocal, .useShared, nil:
            return nil
        }
    }

    /// `true` when the line's choice puts it in the vault — the detail pane
    /// offers Protect this line; otherwise it says the line stays.
    static func lineOffersProtect(_ line: ProjectLine) -> Bool {
        line.choice?.protects == true
    }

    /// The detail pane's action words: "Protect this line" when the choice
    /// protects, "Leave in .env" when it does not.
    static func lineActionTitle(for line: ProjectLine) -> String {
        lineOffersProtect(line) ? "Protect this line" : "Leave in .env"
    }

    /// The name a line becomes a shared secret under (Decision 7): its key
    /// lowercased, `_` to `-`, anything outside the identifier grammar to
    /// `-`; `shared` when nothing usable is left; `-2`, `-3`, … on a
    /// collision with `existing`.
    static func suggestedSharedID(forKey key: String, existing: Set<String>) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        let mapped = String(key.lowercased().map { allowed.contains($0) ? $0 : "-" })
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let base = VaultCore.isValidIdentifier(trimmed) ? trimmed : "shared"
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base)-\(suffix)") {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }

    /// Make it a shared secret, under the name the line already has chosen
    /// or the suggested one.
    private func makeSharedChoice(for line: ProjectLine) -> LineChoice {
        if case .makeShared = line.choice, let current = line.choice { return current }
        return .makeShared(id: Self.suggestedSharedID(forKey: line.key, existing: Set(sharedIDs)))
    }

    // MARK: - Right-click verbs on a line (Decision 8)

    /// One item of a line's right-click menu (ho-06.10 Decision 8, AT-03).
    ///
    /// A line not in the vault offers Protect this line and its choices; a
    /// line in the vault offers Reveal, Copy, and Delete secret. Titles,
    /// symbols, checks, and the destructive flag are reads here; the page
    /// routes each to its intent.
    enum LineVerb: Hashable, Identifiable {
        /// Commit the line now with its current choice — Protect for this
        /// project when the choice was to leave it.
        case protectLine
        /// Set the line's choice, without committing.
        case choose(LineChoice)
        /// Decrypt and show the value in the detail pane.
        case reveal
        /// Decrypt and put the value on the clipboard, without showing it.
        case copy
        /// Switch a protected line to the shared secret whose value it
        /// already has, as the last Check all found (confirmed; AT-04).
        case useMatchedShared(id: String)
        /// Open the form to switch a protected line to a shared secret.
        case useSharedSecret
        /// Open the form to make a protected line's value a shared secret.
        case makeSharedSecret
        /// Delete the secret from the vault (destructive; confirmed).
        case deleteSecret

        /// Stable identity for `ForEach`.
        var id: Self { self }

        /// The menu item's words.
        var title: String {
            switch self {
            case .protectLine: return "Protect this line"
            case .choose(let choice): return choice.label
            case .reveal: return "Reveal"
            case .copy: return "Copy"
            case .useMatchedShared(let id): return "Use shared secret \(id)"
            case .useSharedSecret: return "Use shared secret…"
            case .makeSharedSecret: return "Make it a shared secret"
            case .deleteSecret: return "Delete secret"
            }
        }

        /// The menu item's SF Symbol; `nil` for a choice, which shows a check
        /// instead.
        var systemImage: String? {
            switch self {
            case .protectLine: return "lock.shield"
            case .choose: return nil
            case .reveal: return "eye"
            case .copy: return "doc.on.doc"
            case .useMatchedShared, .useSharedSecret: return "link"
            case .makeSharedSecret: return "link.badge.plus"
            case .deleteSecret: return "trash"
            }
        }

        /// `true` for the one verb that removes something.
        var isDestructive: Bool {
            self == .deleteSecret
        }
    }

    /// The right-click menu for `line`, in order (Required Change 2).
    ///
    /// A protected line with its own value also offers the shared-secret
    /// verbs (AT-04): the match the last Check all found, Use shared secret…
    /// while any shared secret exists, and Make it a shared secret.
    func lineVerbs(for line: ProjectLine) -> [LineVerb] {
        if line.status.isInVault {
            guard isLocalSecret(line.key) else { return [.reveal, .copy, .deleteSecret] }
            let matched = sharedMatch(forKey: line.key).map { [LineVerb.useMatchedShared(id: $0)] } ?? []
            let use: [LineVerb] = sharedIDs.isEmpty ? [] : [.useSharedSecret]
            return [.reveal, .copy] + matched + use + [.makeSharedSecret, .deleteSecret]
        }
        let shared = sharedIDs.map { LineVerb.choose(.useShared(id: $0)) }
        return [.protectLine] + shared + [.choose(makeSharedChoice(for: line)), .choose(.leaveAsSetting)]
    }

    /// Whether `verb` shows a check for `line`: a choice that is the line's
    /// current one.
    static func isLineVerbChecked(_ verb: LineVerb, for line: ProjectLine) -> Bool {
        guard case .choose(let choice) = verb else { return false }
        return line.choice == choice
    }

    /// Whether `verb` is off: everything that changes the vault waits while
    /// an operation runs.
    func isLineVerbDisabled(_ verb: LineVerb) -> Bool {
        guard activity != nil else { return false }
        switch verb {
        case .protectLine, .deleteSecret, .useMatchedShared, .useSharedSecret, .makeSharedSecret: return true
        case .choose, .reveal, .copy: return false
        }
    }

    // MARK: - Line intents (right-click and detail pane)

    /// Protect this line from the right-click menu: selects the line, sets
    /// Protect for this project when its choice was to leave it, then commits
    /// it through ``protectLine(key:)``.
    func protectLineNow(key: String) async {
        guard let line = projectLines.first(where: { $0.key == key }), let choice = line.choice else { return }
        selectedLineKey = key
        if !choice.protects {
            setLineChoice(.protectLocal, forKey: key)
        }
        await protectLine(key: key)
    }

    /// Reveal from the right-click menu: selects the line, so the detail pane
    /// shows the value, then decrypts it.
    func revealLine(key: String) {
        guard let scopeID = selectedScopeID else { return }
        selectedLineKey = key
        reveal(key: key, inScope: scopeID)
    }

    /// Copy from the right-click menu: the selected line's value for the
    /// clipboard.
    ///
    /// Selects the line and decrypts its value — re-masked afterwards unless
    /// it was already revealed, so Copy never shows the value (Do Not).
    /// Announces; `nil` when nothing could be read (the failure is in
    /// ``errorMessage``).
    func copyableValue(forKey key: String) -> String? {
        guard let scopeID = selectedScopeID else { return nil }
        selectedLineKey = key
        let wasRevealed = revealedValue != nil
        if !wasRevealed {
            reveal(key: key, inScope: scopeID)
        }
        let value = revealedValue
        if !wasRevealed {
            maskValue()
        }
        if value != nil {
            statusMessage = "Copied \(key) to the clipboard."
        }
        return value
    }

    /// Delete secret from the right-click menu: selects the line and stages
    /// the deletion for the window's confirmation.
    func requestDeleteLine(key: String) {
        selectedLineKey = key
        requestDeleteSelectedSecret()
    }

    /// Loads the rotation history for the selected line when it is a secret
    /// in the vault.
    ///
    /// The detail pane's history list; run when the page's selected line
    /// changes.
    func loadSelectedLineHistory() {
        guard let scopeID = selectedScopeID, let key = selectedSecretKey,
            let info = cachedSecrets.first(where: { $0.key == key })
        else { return }
        loadHistory(for: key, inScope: scopeID, kind: info.kind)
    }

    // MARK: - Right-click verbs on a sidebar row (Decision 8)

    /// Runs a sidebar row's right-click verb: selects the row, then the same
    /// intent the action column runs for it.
    func perform(_ verb: SelectionVerb, on entry: ProjectEntry) async {
        selection = entry.id
        switch verb {
        case .protect:
            await protectRecommended()
        case .writeEnv:
            await materializeSelectedScope()
        case .previewEnv:
            await previewEnv()
        case .openInFinder:
            if let directory = entry.directory {
                openInFinder(directory)
            }
        case .unprotect:
            requestUnprotectSelectedProject()
        case .deleteProject:
            requestDeleteSelectedScope()
        case .protectFolder:
            if let marker = entry.problemMarker {
                await createScopeFromMarker(marker)
            }
        case .forgetFolder:
            if let marker = entry.problemMarker {
                requestRemoveStrayMarker(marker)
            }
        }
    }

    // MARK: - Problem page

    /// The Problem page's explanation for a folder claiming project `name`,
    /// as two paragraphs — verbatim from the ho-06.9 drawing.
    static func problemExplanation(projectName name: String) -> [String] {
        [
            "This folder says it belongs to a project called \(name), but the vault has no project "
                + "by that name. It may have been deleted, or the folder came from another machine.",
            "Protect this folder brings its .env into the vault as \(name). Forget this folder "
                + "removes the claim file and leaves everything else alone.",
        ]
    }

    /// The Problem page's title for an unreadable claim file.
    static let unreadableClaimTitle = "Unreadable claim file"

    /// The Problem page's lead-in for an unreadable claim file; the load
    /// failure's reason follows it in monospace.
    static let unreadableClaimLead = "Sharibako could not read the `.sharibako` file in this folder:"

    // MARK: - Shared-secret page

    /// The used-by heading for `sharedID`: "Used by N project(s):", or "Not
    /// used by any project yet." when nothing links to it.
    func usedByHeading(sharedID: String) -> String {
        let count = Set(usedBy(sharedID: sharedID).map(\.scopeID)).count
        switch count {
        case 0: return "Not used by any project yet."
        case 1: return "Used by 1 project:"
        default: return "Used by \(count) projects:"
        }
    }

    /// The used-by list for `sharedID`, one line per use.
    ///
    /// Each line reads "<project> (<KEY>)", in ``usedBy(sharedID:)``'s order.
    func usedByLines(sharedID: String) -> [String] {
        usedBy(sharedID: sharedID).map { "\($0.scopeID) (\($0.key))" }
    }

    /// The shared-secret page's closing note: what a shared secret is, and
    /// that editing it is not here yet.
    static let sharedSecretNote =
        "Changing a shared secret once changes it for every project that uses it. "
        + "Editing shared secrets arrives with linking."

    // MARK: - First-run finish page (Decision 5)

    /// The first-run finish page's preview line for `count` folders found
    /// with a `.env` — they wait under Not protected once the vault exists.
    static func firstRunCandidateSummary(count: Int) -> String {
        count == 1
            ? "Found 1 project with a .env — it'll be waiting under Not protected."
            : "Found \(count) projects with a .env — they'll be waiting under Not protected."
    }
}

extension WorkshopModel.ProjectEntry {
    /// `true` for a Shared-secrets row, whose ``status`` is a placeholder the
    /// views must never render.
    var isShared: Bool {
        if case .shared = id { return true }
        return false
    }

    /// The claim file behind a Needs-attention row.
    ///
    /// The `.problem` status's payload — the Problem page's input — or `nil`
    /// for every other row.
    var problemMarker: WorkshopModel.UnlinkedMarker? {
        if case .problem(let marker) = status { return marker }
        return nil
    }

    /// The row's leading SF Symbol (Decision 8): its status's shape, or
    /// `link` for a shared secret.
    var glyphSymbolName: String {
        isShared ? "link" : status.symbolName
    }

    /// The row's tooltip: its status in the ten words, or what a shared
    /// secret is — never the shared row's placeholder status.
    var glyphHelp: String {
        isShared
            ? "Shared secret — one secret used by several projects; change it once"
            : status.helpText
    }
}

extension WorkshopModel.ProjectHeaderState {
    /// `true` while secrets sit in `.env` in plain text — the header shows
    /// the red mark and its one Protect button exactly then (Decision 6).
    var offersProtect: Bool {
        if case .unprotected = self { return true }
        return false
    }

    /// The label without an out-of-date clause — "Protected" when lines
    /// differ, the whole ``label`` otherwise.
    var steadyLabel: String {
        alarmClause == nil ? label : "Protected"
    }

    /// The out-of-date clause the header shows in the alarm token — "2 lines
    /// differ" — or `nil` when nothing differs.
    var alarmClause: String? {
        guard case .protected(false?, let differing) = self else { return nil }
        return differing == 1 ? "1 line differs" : "\(differing) lines differ"
    }
}

extension WorkshopModel.ProjectSection {
    /// `true` for the Not-protected section while it has rows: its header
    /// offers Protect all (Decision 5).
    var offersProtectAll: Bool {
        id == .notProtected && !entries.isEmpty
    }
}
