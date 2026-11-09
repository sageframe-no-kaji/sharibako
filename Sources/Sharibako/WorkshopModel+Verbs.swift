import Foundation
import SharibakoCore

/// The verbs the ho-06.9 gate asked for (ho-06.10 Decision 8, AT-04):
/// **Unprotect** a project; **Use shared secret…** and **Make it a shared
/// secret** on a line already protected for its project; and the next step
/// every pane error carries. **Remote…** and **Scan folders…** live in
/// `WorkshopModel+VaultSettings.swift`; the resilient Check all and its value
/// match in `WorkshopModel+Heal.swift`.
///
/// Every destructive verb stages a plan on the model (``pendingUnprotect``,
/// ``pendingSharedLink``) for a system-rendered confirmation in
/// `WorkshopWindow.swift`, then runs from the confirmation with the plan
/// passed in — read synchronously at the tap, because the dialog's dismissal
/// clears the pending value before the button's `Task` body runs (the
/// ho-06.9 Forget-this-folder lesson). Every failure lands in the pane it
/// came from with a next step (``reportPaneError(for:)``).
///
/// Kept in its own file, the `Conduit`/`Conduit+Remote.swift` split
/// precedent, under SwiftLint's `file_length` ceiling.
extension WorkshopModel {
    // MARK: - Types

    /// A staged Unprotect: the project, its folder, and how many secrets go
    /// back into `.env`.
    struct UnprotectPlan: Equatable {
        /// The project to unprotect.
        let scopeID: String
        /// The project's name, for the confirmation and the announce.
        let name: String
        /// The folder whose `.env` gets the values back.
        let directory: URL
        /// How many secrets the vault holds for the project.
        let secretCount: Int
    }

    /// A staged switch of a protected line to a shared secret.
    struct SharedLinkPlan: Equatable {
        /// The project holding the line.
        let scopeID: String
        /// The line's key.
        let key: String
        /// The shared secret the line will use.
        let sharedID: String
    }

    /// Which of the two shared-secret forms is open on a protected line.
    enum LineShareKind: Equatable {
        /// Pick an existing shared secret for the line to use.
        case useShared
        /// Name a new shared secret made from the line's value.
        case makeShared
    }

    /// The open shared-secret form on a protected line: which form, which
    /// line, and the shared secret's ID as picked or typed so far.
    ///
    /// One form, one presentation: the window's sheet, whichever door opened
    /// it — the line's right-click menu or the detail pane's button (the
    /// ho-06.10 gate's blank-split-view finding; see ``isLineShareFormPresented``).
    struct LineShareForm: Equatable {
        /// Which form is open.
        let kind: LineShareKind
        /// The line the form is for.
        let key: String
        /// The picked shared secret, or the typed name for a new one.
        var sharedID: String
    }

    // MARK: - Errors in the pane (Required Change 6)

    /// The next step for a key that cannot read a project's secrets.
    static let keyMismatchNextStep =
        "If you switched keys, switch back; otherwise Delete project and protect the folder again."

    /// The next step when a project's folder cannot be found.
    static let folderNotFoundNextStep = "Attach a folder with Scan folders… or protect the folder again."

    /// The next step when Sync's push is rejected.
    static let pushRejectedNextStep = "Pull on the other machine, then Sync again."

    /// The next step when the vault key cannot be loaded.
    static let keyLoadNextStep = "Unlock the vault key with Touch ID and try again."

    /// The next step for `error`, where there is one to give: a key that
    /// cannot read the secrets, or a project whose folder was not found.
    static func nextStep(for error: Error) -> String? {
        guard let vaultError = error as? VaultError else { return nil }
        switch vaultError {
        case .ageInvocationFailed(_, let stderr):
            return stderr.lowercased().contains("no identity matched") ? keyMismatchNextStep : nil
        case .markerNotFound:
            return folderNotFoundNextStep
        default:
            return nil
        }
    }

    /// Reports `error` in the pane its action came from, with its next step,
    /// and echoes it in the status bar.
    func reportPaneError(for error: Error) {
        reportPaneError(Self.message(for: error), nextStep: Self.nextStep(for: error))
    }

    /// Reports a failure to load the vault key, in the pane and the status bar.
    func reportKeyLoadFailure(_ error: Error) {
        reportPaneError("Could not load age key: \(error)", nextStep: Self.keyLoadNextStep)
    }

    /// The selected project's Check-all failure, when the last Check all
    /// could not read it — rendered in its pane like an action's error.
    var selectedProjectCheckError: PaneError? {
        selectedScopeID.flatMap { unreadableProjects[$0] }
    }

    /// Forgets everything the last Check all learned about `scopeID` — run
    /// when the project leaves the vault.
    func forgetCheckResults(forScope scopeID: String) {
        driftReports.removeValue(forKey: scopeID)
        unreadableProjects.removeValue(forKey: scopeID)
        sharedMatches.removeValue(forKey: scopeID)
    }

    // MARK: - Unprotect (Required Change 1)

    /// Why Unprotect cannot run for `scopeID`, or `nil` when it can: it needs
    /// the project's folder on this Mac to write the values into.
    func unprotectDisabledReason(forScope scopeID: String?) -> String? {
        guard let scopeID else { return "Select a project first" }
        guard cachedMarker(forScope: scopeID) != nil else {
            return scanReport == nil
                ? "Not scanned yet — rescan to find this project's folder"
                : Self.noFolderToUnprotectReason
        }
        return nil
    }

    /// Unprotect's disabled reason for a project with no folder on this Mac.
    static let noFolderToUnprotectReason = "No folder on this Mac to write the values into"

    /// The Unprotect confirmation's title.
    static func unprotectDialogTitle(for plan: UnprotectPlan) -> String {
        "Unprotect \(plan.name)?"
    }

    /// The Unprotect confirmation's message: exactly what happens to the
    /// secrets.
    static func unprotectDialogMessage(for plan: UnprotectPlan) -> String {
        let secrets = plan.secretCount == 1 ? "Its 1 secret" : "Its \(plan.secretCount) secrets"
        return "\(secrets) will be back in .env in plain text, in \(plan.directory.path), "
            + "and no longer in the vault. The folder goes back to Not protected."
    }

    /// The announce after an Unprotect.
    ///
    /// "Unprotected bento — 3 secrets are back in .env in plain text."
    static func unprotectSummary(name: String, secretCount: Int) -> String {
        switch secretCount {
        case 0: return "Unprotected \(name) — it had no secrets in the vault."
        case 1: return "Unprotected \(name) — 1 secret is back in .env in plain text."
        default: return "Unprotected \(name) — \(secretCount) secrets are back in .env in plain text."
        }
    }

    /// Stages an Unprotect of the selected project for the window's
    /// confirmation.
    ///
    /// Keyless: the count is the vault's file listing. A no-op while an
    /// operation runs, with no project selected, or when the project has no
    /// folder on this Mac (the verb is disabled then).
    func requestUnprotectSelectedProject() {
        guard activity == nil, case .open(let vaultURL) = vaultState,
            let scopeID = selectedScopeID, let marker = cachedMarker(forScope: scopeID)
        else { return }
        statusMessage = nil
        let count = (try? VaultCore(vaultURL: vaultURL).inspect(scopeID).count) ?? 0
        pendingUnprotect = UnprotectPlan(
            scopeID: scopeID,
            name: selectedEntry?.name ?? scopeID,
            directory: marker.markerURL.deletingLastPathComponent(),
            secretCount: count
        )
    }

    /// Dismisses the pending Unprotect (user cancelled).
    func dismissUnprotect() {
        pendingUnprotect = nil
    }

    /// Unprotects the staged project behind one key acquisition.
    ///
    /// On the worker, in order: Write .env without overwriting a difference
    /// — when the file differs from the vault it stops there and raises the
    /// same confirmation Write .env does (the user resolves, then Unprotects
    /// again); only then the vault entry is deleted and the claim file
    /// removed (Do Not: never delete before the write succeeded). Then the
    /// project list, the scan, and the Not-protected list refresh, and the
    /// folder is selected under Not protected. `plan` is passed in by the
    /// confirmation button (see the file header); falls back to the pending
    /// plan.
    func confirmUnprotect(_ plan: UnprotectPlan? = nil) async {
        guard activity == nil, case .open(let vaultURL) = vaultState,
            let plan = plan ?? pendingUnprotect
        else { return }
        pendingUnprotect = nil
        guard let marker = cachedMarker(forScope: plan.scopeID) else {
            reportPaneError(for: VaultError.markerNotFound(startingFrom: plan.directory))
            return
        }
        statusMessage = nil
        activity = .unprotecting
        defer { activity = nil }
        let handle: AgeKeyHandle
        do {
            handle = try makeAgeKeyProvider().loadIdentity(reason: "Unprotect \(plan.name)")
        } catch {
            reportKeyLoadFailure(error)
            return
        }
        defer { handle.release() }
        let keyURL = handle.url
        let outcome: ProjectUnprotector.Outcome
        do {
            outcome = try await worker.run {
                try ProjectUnprotector.unprotect(marker: marker, vaultURL: vaultURL, keyURL: keyURL)
            }
        } catch {
            reportPaneError(for: error)
            return
        }
        switch outcome {
        case .differs(let diff):
            pendingDiff = diff
            statusMessage = "Unprotect stopped — \(plan.name)'s .env is out of date. Resolve it, then Unprotect again."
        case .unprotected(let count):
            await landUnprotect(plan, marker: marker, vaultURL: vaultURL)
            statusMessage = Self.unprotectSummary(name: plan.name, secretCount: count)
            errorMessage = nil
        }
    }

    /// After an Unprotect: the project leaves the list and every check
    /// result, the scan re-reads the claim files and the Not-protected
    /// folders, and the folder is selected there.
    private func landUnprotect(_ plan: UnprotectPlan, marker: ScopeMarker, vaultURL: URL) async {
        forgetCheckResults(forScope: plan.scopeID)
        loadScopes()
        if let report = scanReport {
            updateScanReport(
                ScanReport(
                    markers: report.markers.filter { $0.markerURL != marker.markerURL }, failures: report.failures))
        }
        if !scanRoots.isEmpty {
            _ = try? await scanMarkersAndCandidates(vaultURL: vaultURL, roots: scanRoots)
        }
        addCandidate(plan.directory)
        let path = plan.directory.standardizedFileURL.path
        if let folder = candidates.first(where: { $0.standardizedFileURL.path == path }) {
            let row = Selection.candidate(directory: folder)
            selection = row
            await loadContent(for: row)
        }
    }

    // MARK: - Shared secret, after the fact (Required Change 2)

    /// `true` when `key` is a secret the selected project holds with its own
    /// value — the lines that can switch to a shared secret or become one.
    func isLocalSecret(_ key: String) -> Bool {
        guard selectedScopeID != nil else { return false }
        return cachedSecrets.first { $0.key == key }?.kind == .value
    }

    /// The shared secret with the same value as the line `key`, or `nil`.
    ///
    /// As the last Check all found it.
    func sharedMatch(forKey key: String) -> String? {
        guard isLocalSecret(key), let scopeID = selectedScopeID,
            let id = sharedMatches[scopeID]?[key], sharedIDs.contains(id)
        else { return nil }
        return id
    }

    /// The row's caption with what the last Check all noticed: a protected
    /// line whose value equals a shared secret's adds "same value as shared
    /// openai-key" to ``lineCaption(for:)``; every other line reads it as is.
    func lineCaptionText(for line: ProjectLine) -> String {
        let caption = Self.lineCaption(for: line)
        guard line.status.isInVault, let id = sharedMatch(forKey: line.key) else { return caption }
        return "\(caption) · same value as shared \(id)"
    }

    /// The match's sentence in the detail pane, or `nil` with no match.
    func sharedMatchNote(forKey key: String) -> String? {
        sharedMatch(forKey: key).map { "Same value as the shared secret \($0)." }
    }

    /// Opens a shared-secret form on the protected line `key`, selecting it.
    ///
    /// **Use shared secret…** starts on the matching shared secret, else the
    /// first; **Make it a shared secret** starts on the key lowercased, `_`
    /// to `-`, clear of existing names. A no-op for a line that is not a
    /// protected secret of its own, and for Use with no shared secrets.
    /// Both doors — the line's right-click menu and the detail pane's
    /// button — open the same form in the window's sheet.
    func openLineShareForm(_ kind: LineShareKind, forKey key: String) {
        guard isLocalSecret(key) else { return }
        let start: String
        switch kind {
        case .useShared:
            guard let first = sharedMatch(forKey: key) ?? sharedIDs.first else { return }
            start = first
        case .makeShared:
            start = Self.suggestedSharedID(forKey: key, existing: Set(sharedIDs))
        }
        selectedLineKey = key
        lineShareForm = LineShareForm(kind: kind, key: key, sharedID: start)
    }

    /// Whether the window's shared-secret sheet is up — exactly while a form
    /// is open.
    ///
    /// The form is presented by the window, outside the split view, never as
    /// a popover anchored to a `List` row or a detail-pane button: the
    /// ho-06.10 gate saw the whole split view go blank after a failed Make it
    /// a shared secret from a row-anchored popover. Every way the form ends —
    /// cancel, a new line or selection, a submit that lands or fails —
    /// clears ``lineShareForm`` and so takes the sheet down.
    var isLineShareFormPresented: Bool {
        lineShareForm != nil
    }

    /// The open form's validation note, or `nil` when it can be submitted.
    ///
    /// Set for an empty name, one outside the identifier grammar, or one
    /// already a shared secret; for Use, a pick the vault does not have
    /// (ho-06.10 AT-05). The sheet disables its button while this is set.
    var lineShareFormProblem: String? {
        guard let form = lineShareForm else { return nil }
        let name = form.sharedID.trimmingCharacters(in: .whitespaces)
        switch form.kind {
        case .useShared:
            return sharedIDs.contains(name) ? nil : "Pick one of the vault's shared secrets."
        case .makeShared:
            guard !name.isEmpty else { return "Name the shared secret." }
            guard VaultCore.isValidIdentifier(name) else { return "Use lowercase letters, digits, dots, and dashes." }
            guard !sharedIDs.contains(name) else { return "A shared secret named \(name) already exists." }
            return nil
        }
    }

    /// The sheet's quiet note under a valid entry: what the one button
    /// will do.
    static func lineShareFormHint(_ kind: LineShareKind) -> String {
        switch kind {
        case .useShared: return "This line uses it from now on; its own value is discarded."
        case .makeShared: return "Saved as a shared secret other projects can use — one Touch ID."
        }
    }

    /// Closes the shared-secret form without doing anything.
    func cancelLineShareForm() {
        lineShareForm = nil
    }

    /// The form's action words.
    static func lineShareFormAction(_ kind: LineShareKind) -> String {
        switch kind {
        case .useShared: return "Use this shared secret"
        case .makeShared: return "Make it a shared secret"
        }
    }

    /// Submits the open form: Use stages the confirmation (its own value is
    /// discarded); Make runs at once, behind one Touch ID.
    func submitLineShareForm() {
        guard let form = lineShareForm else { return }
        switch form.kind {
        case .useShared:
            requestUseShared(form.sharedID, forKey: form.key)
        case .makeShared:
            makeLineShared(key: form.key, as: form.sharedID.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Stages switching the protected line `key` to shared secret `sharedID`
    /// for the window's confirmation, selecting the line.
    ///
    /// Closes the form first, so its sheet is down before the confirmation
    /// asks — the window never holds both at once.
    func requestUseShared(_ sharedID: String, forKey key: String) {
        guard activity == nil, let scopeID = selectedScopeID, isLocalSecret(key),
            sharedIDs.contains(sharedID)
        else { return }
        lineShareForm = nil
        statusMessage = nil
        selectedLineKey = key
        pendingSharedLink = SharedLinkPlan(scopeID: scopeID, key: key, sharedID: sharedID)
    }

    /// Dismisses the pending switch (user cancelled).
    func dismissSharedLink() {
        pendingSharedLink = nil
    }

    /// The switch's confirmation title.
    static func sharedLinkDialogTitle(for plan: SharedLinkPlan) -> String {
        "Use shared secret \(plan.sharedID)?"
    }

    /// The switch's confirmation message: what is discarded.
    static func sharedLinkDialogMessage(for plan: SharedLinkPlan) -> String {
        "\(plan.key) will use the shared secret \(plan.sharedID) from now on; its own value is discarded."
    }

    /// Switches the staged line to its shared secret.
    ///
    /// Keyless — `VaultCore.link` writes the link and removes the line's own
    /// value; nothing is decrypted. Refreshes the line, the shared secrets'
    /// used-by lists, and the match. `plan` is passed in by the confirmation
    /// button (see the file header); falls back to the pending plan.
    func confirmUseShared(_ plan: SharedLinkPlan? = nil) {
        guard case .open(let vaultURL) = vaultState, let plan = plan ?? pendingSharedLink else { return }
        pendingSharedLink = nil
        do {
            try VaultCore(vaultURL: vaultURL).link(plan.key, inScope: plan.scopeID, toShared: plan.sharedID)
        } catch {
            reportPaneError(for: error)
            return
        }
        landSharedChange(scopeID: plan.scopeID, key: plan.key)
        statusMessage = "\(plan.key) in \(plan.scopeID) now uses the shared secret \(plan.sharedID)."
        errorMessage = nil
    }

    /// Makes the protected line `key` a new shared secret named `sharedID`
    /// and has the line use it — one Touch ID.
    ///
    /// Decrypts the line's own value and notes, saves them as the shared
    /// secret, then links the line to it. A name outside the identifier
    /// grammar, or one already taken, is refused in the pane before any key
    /// is asked for.
    ///
    /// The form closes on every outcome, so a failure lands in the pane with
    /// nothing presented over it. A failure leaves the selection, the
    /// selected line, the scopes, and the page's lines as they were: nothing
    /// is reloaded unless the shared secret was written before the link
    /// failed, and then only the shared side (the ho-06.10 gate's
    /// blank-split-view finding, where the key in use could not read the
    /// project's secrets).
    func makeLineShared(key: String, as sharedID: String) {
        guard activity == nil, case .open(let vaultURL) = vaultState,
            let scopeID = selectedScopeID, isLocalSecret(key)
        else { return }
        lineShareForm = nil
        guard VaultCore.isValidIdentifier(sharedID) else {
            reportPaneError(
                "\"\(sharedID)\" can't name a shared secret.",
                nextStep: "Use lowercase letters, digits, dots, and dashes.")
            return
        }
        guard !sharedIDs.contains(sharedID) else {
            reportPaneError(
                "A shared secret named \(sharedID) already exists.",
                nextStep: "Pick another name — or choose Use shared secret… to use that one.")
            return
        }
        let handle: AgeKeyHandle
        do {
            handle = try makeAgeKeyProvider().loadIdentity(reason: "Make \(key) a shared secret")
        } catch {
            reportKeyLoadFailure(error)
            return
        }
        defer { handle.release() }
        var savedShared = false
        do {
            let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: handle.url)
            let content = try core.getSecretContent(key, inScope: scopeID)
            try core.addSharedEntry(sharedID, value: content.value, notes: content.notes)
            savedShared = true
            try core.link(key, inScope: scopeID, toShared: sharedID)
        } catch {
            if savedShared {
                loadSharedSecrets()
            }
            reportPaneError(for: error)
            return
        }
        landSharedChange(scopeID: scopeID, key: key)
        statusMessage = "\(key) is now the shared secret \(sharedID); \(scopeID) uses it."
        errorMessage = nil
    }

    /// After a line starts using a shared secret: the form closes, its match
    /// drops, and the shared section, used-by lists, and lines reload.
    private func landSharedChange(scopeID: String, key: String) {
        lineShareForm = nil
        sharedMatches[scopeID]?[key] = nil
        loadScopes()
        if selectedScopeID == scopeID {
            loadSecrets(for: scopeID)
        }
    }
}

// MARK: - Unprotecting a project (pure, off-main-actor-safe)

/// The worker half of an Unprotect: Write .env, then the vault entry and the
/// claim file go.
///
/// A plain `enum` (never instantiated) for the same off-main-actor reason as
/// ``EnvReader``.
enum ProjectUnprotector {
    /// What an Unprotect did.
    enum Outcome: Sendable, Equatable {
        /// The `.env` differs from the vault; nothing was written or deleted.
        case differs(MaterializeDiff)
        /// The values are in `.env`; the vault entry and claim file are gone.
        case unprotected(secretCount: Int)
    }

    /// Writes the project's values into its `.env` without overwriting a
    /// difference, and only then deletes its vault entry and claim file.
    static func unprotect(marker: ScopeMarker, vaultURL: URL, keyURL: URL) throws -> Outcome {
        let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
        let count = try core.inspect(marker.scope).count
        let result = try Materializer(vaultCore: core, vaultURL: vaultURL)
            .materialize(marker: marker, overwriteDrift: false)
        if case .diffPending(let diff) = result {
            return .differs(diff)
        }
        try core.deleteScope(marker.scope)
        do {
            try FileManager.default.removeItem(at: marker.markerURL)
        } catch {
            throw VaultError.fileSystemError(path: marker.markerURL, underlying: error)
        }
        return .unprotected(secretCount: count)
    }
}
