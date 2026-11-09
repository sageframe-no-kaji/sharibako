import Foundation
import SharibakoCore

/// The Protect intents (ho-06.10 Decisions 5–7, AT-02): one line, a page's
/// recommended lines, or every folder not yet protected — each behind one
/// Touch ID, over `Materializer.acceptIngest`.
///
/// The project page is the review (Decision 6): what a Protect commits is
/// exactly what ``WorkshopModel/projectLines`` shows — each line's current
/// choice, the classifier's default unless the user flipped it. There is no
/// sheet and no prompt (Do Not): a new project takes its ID from the folder
/// name (``WorkshopModel/suggestedScopeID(for:existing:)``) and the
/// `project-dev` tag, which the page can change later (Decision 4); an
/// existing project keeps its own ID, and `acceptIngest` adds the new lines
/// to it. Settings are committed as `leaveAlone`, so they stay in `.env`
/// untouched and `skip` is never produced.
///
/// Every intent acquires the age key once on the main actor (user
/// interaction, not CPU work) and hands only its `Sendable` URL to
/// ``WorkshopModel/worker``; on success it splices the claim file into the
/// scan cache, prunes the folder from ``WorkshopModel/candidates``, forgets
/// its flips, selects the project, reloads its lines, and announces. A
/// failure lands in ``WorkshopModel/errorMessage`` and in
/// ``WorkshopModel/paneError`` for the pane to render (Decision 8).
///
/// Before committing, a folder whose lines to protect for this project hold
/// a value equal to a shared secret's is held back and asked about
/// (ho-06.10 AT-05) — the question and its answers live in
/// `WorkshopModel+SharedValues.swift`.
///
/// Split from `WorkshopModel+Lines.swift` (the reads) by read/write — the
/// `Conduit`/`Conduit+Remote.swift` precedent, and SwiftLint's `file_length`
/// ceiling.
extension WorkshopModel {
    /// One folder's Protect, planned on the main actor from its lines.
    struct ProtectPlan: Equatable, Sendable {
        /// The folder whose `.env` is read and whose claim file is written.
        let directory: URL
        /// The project the lines go into — created when the vault lacks it.
        let scopeID: String
        /// The project's name for the announce.
        let name: String
        /// One decision per line with a choice, settings included.
        let decisions: [KeyDecision]
    }

    /// Where a Protect of the selected page goes: the folder, the project
    /// ID, and the name the announce uses.
    struct ProtectTarget: Equatable {
        /// The folder whose `.env` is read and whose claim file is written.
        let directory: URL
        /// The project the lines go into.
        let scopeID: String
        /// The project's name for the announce.
        let name: String

        /// The plan that commits `decisions` here.
        func plan(_ decisions: [KeyDecision]) -> ProtectPlan {
            ProtectPlan(directory: directory, scopeID: scopeID, name: name, decisions: decisions)
        }
    }

    /// What a batch of plans did: the decisions each folder committed, each
    /// folder held back because a value equals a shared secret's, and each
    /// folder that failed with the message why.
    struct ProtectBatch {
        /// Plans that committed, with the decisions actually applied.
        var done: [(plan: ProtectPlan, applied: [KeyDecision])] = []
        /// Plans not committed because a line to protect has a shared
        /// secret's value, with those lines (ho-06.10 AT-05).
        var held: [(plan: ProtectPlan, matches: [SharedValueMatch])] = []
        /// Plans that failed, with the user-facing message.
        var failed: [(name: String, message: String)] = []
    }

    // MARK: - Intents

    /// Protects one line of the selected page with its current choice
    /// (Decision 6: **Protect this line**).
    ///
    /// A no-op for a line already in the vault and for one whose choice is to
    /// leave it as a setting. On a folder the vault does not know yet this
    /// creates the project with just that line; the rest stay on the page,
    /// not protected. The line stays selected afterwards — now a protected
    /// line, its detail pane the vault secret's. A value equal to a shared
    /// secret's is asked about first (ho-06.10 AT-05).
    func protectLine(key: String) async {
        guard activity == nil, case .open = vaultState else { return }
        activity = .ingesting
        defer { activity = nil }
        await ensureLinesLoaded()
        guard let choice = projectLines.first(where: { $0.key == key })?.choice, choice.protects,
            let target = protectTarget(scopeID: nil)
        else { return }
        let plan = target.plan([choice.decision(forKey: key)])
        guard let batch = await commitProtect([plan], reason: "Protect secrets in \(target.name)") else { return }
        guard !holdForSharedValues(batch, origin: .line(key: key)) else { return }
        await landProtect(batch, origin: .line(key: key))
    }

    /// Protects every line of the selected page whose choice puts it in the
    /// vault, and records the rest as settings left in `.env` (Decision 6:
    /// **Protect N secrets**).
    ///
    /// For a folder not yet protected the project ID is `scopeID`, or the
    /// folder name when `nil`; for a Problem folder it is `scopeID`, or the
    /// project its claim file names; an existing project always keeps its
    /// own. With nothing to protect it announces so and asks for no key. A
    /// value equal to a shared secret's is asked about first (ho-06.10
    /// AT-05).
    func protectRecommended(scopeID: String? = nil) async {
        guard activity == nil, case .open = vaultState else { return }
        activity = .ingesting
        defer { activity = nil }
        await ensureLinesLoaded()
        guard protectableLineCount > 0, let target = protectTarget(scopeID: scopeID) else {
            statusMessage = Self.nothingToProtect(in: selectedEntry?.name)
            errorMessage = nil
            return
        }
        let plan = target.plan(projectLines.compactMap { $0.choice?.decision(forKey: $0.key) })
        guard let batch = await commitProtect([plan], reason: "Protect secrets in \(target.name)") else { return }
        guard !holdForSharedValues(batch, origin: .page) else { return }
        await landProtect(batch, origin: .page)
    }

    /// Protects every folder under Not protected, each with its own lines and
    /// choices, inside one key handle (Decision 5: **Protect all**).
    ///
    /// Reads every folder first (keyless), names each new project from its
    /// folder — collision-suffixed against the vault and against the other
    /// folders in the same pass — and skips a folder with nothing to protect
    /// or with no secrets at all (only settings, ho-06.10 AT-05). Continues
    /// past a folder it cannot read or commit and reports it; the totals
    /// cover what was protected. A selected folder that was protected moves
    /// the selection to its new project. A folder with a value equal to a
    /// shared secret's is held back and asked about, one question per
    /// project, after the rest commit.
    func protectAllCandidates() async {
        guard activity == nil, case .open(let vaultURL) = vaultState else { return }
        activity = .ingesting
        defer { activity = nil }
        var failures: [(name: String, message: String)] = []
        var reads: [EnvRead] = []
        for folder in candidates {
            do {
                reads.append(try await worker.run { try EnvReader.read(directory: folder, vaultURL: vaultURL) })
            } catch {
                failures.append((folder.lastPathComponent, Self.message(for: error)))
            }
        }
        let plans = planAll(reads)
        var batch = ProtectBatch()
        if !plans.isEmpty {
            let projects = plans.count == 1 ? "1 project" : "\(plans.count) projects"
            guard let committed = await commitProtect(plans, reason: "Protect secrets in \(projects)") else { return }
            batch = committed
        }
        _ = holdForSharedValues(batch, origin: .all)
        batch.failed = failures + batch.failed
        await landProtect(batch, origin: .all)
    }

    // MARK: - Summaries (pure)

    /// The announce after one folder's Protect: "Protected 3 secrets in
    /// bento; 2 settings left in .env." — the settings clause only when some
    /// were left.
    static func protectSummary(name: String, decisions: [KeyDecision]) -> String {
        let (secrets, settings) = tally(decisions)
        return "Protected \(count(secrets, "secret")) in \(name)\(settingsClause(settings))."
    }

    /// The announce after Protect all.
    ///
    /// "Protected 3 projects: 7 secrets; 5 settings left in .env."
    static func protectAllSummary(projects: Int, decisions: [KeyDecision]) -> String {
        let (secrets, settings) = tally(decisions)
        return "Protected \(count(projects, "project")): \(count(secrets, "secret"))\(settingsClause(settings))."
    }

    /// The announce when there is nothing to protect — stated, never silent.
    static func nothingToProtect(in name: String?) -> String {
        guard let name else { return "Nothing to protect — no secrets are waiting in .env." }
        return "Nothing to protect in \(name) — every secret is in the vault or left as a setting."
    }

    /// Counts the decisions that put a line in the vault, and the settings.
    static func tally(_ decisions: [KeyDecision]) -> (secrets: Int, settings: Int) {
        decisions.reduce(into: (secrets: 0, settings: 0)) { counts, decision in
            switch decision {
            case .importAsLocal, .linkToShared, .moveToShared: counts.secrets += 1
            case .leaveAlone, .skip: counts.settings += 1
            }
        }
    }

    /// "1 secret", "3 secrets".
    private static func count(_ number: Int, _ noun: String) -> String {
        number == 1 ? "1 \(noun)" : "\(number) \(noun)s"
    }

    /// "; 2 settings left in .env", or nothing when none were left.
    private static func settingsClause(_ settings: Int) -> String {
        settings == 0 ? "" : "; \(count(settings, "setting")) left in .env"
    }

    // MARK: - Steps

    /// Reads the selected page's lines first when they have not been read —
    /// a Protect commits what the page shows, so the page must have been read.
    private func ensureLinesLoaded() async {
        guard let selection, envRead == nil else { return }
        await loadContent(for: selection)
    }

    /// Where a Protect of the selected page goes, or `nil` when the
    /// selection has no folder to protect.
    private func protectTarget(scopeID override: String?) -> ProtectTarget? {
        switch selection {
        case .project(let scopeID):
            guard let folder = envRead?.directory else { return nil }
            return ProtectTarget(directory: folder, scopeID: scopeID, name: selectedEntry?.name ?? scopeID)
        case .candidate(let directory):
            let scopeID =
                override ?? Self.suggestedScopeID(for: directory, existing: Set(scopes.map(\.identity)))
            return ProtectTarget(directory: directory, scopeID: scopeID, name: scopeID)
        case .problem(let markerPath):
            guard let claim = orphanedClaim(markerPath: markerPath) else { return nil }
            let scopeID = override ?? claim.scope
            return ProtectTarget(directory: claim.folder, scopeID: scopeID, name: scopeID)
        case .shared, nil:
            return nil
        }
    }

    /// One plan per read folder that has secrets and something to protect.
    ///
    /// Each is named from its folder and kept clear of every other name in
    /// the pass. A folder holding only settings is skipped even when a line was
    /// flipped — Protect all leaves it to its own page (ho-06.10 AT-05).
    private func planAll(_ reads: [EnvRead]) -> [ProtectPlan] {
        var taken = Set(scopes.map(\.identity))
        var plans: [ProtectPlan] = []
        for read in reads where read.lines.contains(where: \.lineClass.isSecret) {
            let lines = Self.deriveLines(vault: [], env: read, flips: lineChoiceFlips)
            guard lines.contains(where: { $0.choice?.protects == true }) else { continue }
            let scopeID = Self.suggestedScopeID(for: read.directory, existing: taken)
            taken.insert(scopeID)
            let target = ProtectTarget(directory: read.directory, scopeID: scopeID, name: scopeID)
            plans.append(target.plan(lines.compactMap { $0.choice?.decision(forKey: $0.key) }))
        }
        return plans
    }

    /// Commits `plans` inside one key handle; `nil` when the key could not be
    /// loaded (already reported).
    ///
    /// Each plan runs in its own worker hop so one folder's failure leaves the
    /// rest committed. Each success's claim file is spliced into the scan
    /// cache and its folder pruned from ``candidates`` at once; the project
    /// list reloads once at the end.
    ///
    /// With `checkSharedValues` and any shared secret in the vault, every
    /// shared secret's value is decrypted once, before the first plan, and a
    /// plan whose lines to protect for this project hold one of them is held
    /// back uncommitted in ``ProtectBatch/held`` (ho-06.10 AT-05).
    func commitProtect(
        _ plans: [ProtectPlan], reason: String, checkSharedValues: Bool = true
    ) async -> ProtectBatch? {
        guard case .open(let vaultURL) = vaultState else { return nil }
        let handle: AgeKeyHandle
        do {
            handle = try makeAgeKeyProvider().loadIdentity(reason: reason)
        } catch {
            reportPaneError(
                "Could not load age key: \(error)",
                nextStep: "Protect needs the vault key — unlock it with Touch ID and try again.")
            return nil
        }
        defer { handle.release() }
        let keyURL = handle.url
        var sharedValues: [String: String] = [:]
        if checkSharedValues, !sharedIDs.isEmpty {
            let ids = sharedIDs
            sharedValues = await worker.run {
                ProjectChecker.sharedValues(ids, vaultURL: vaultURL, keyURL: keyURL)
            }
        }
        var batch = ProtectBatch()
        for plan in plans {
            do {
                let values = sharedValues
                let outcome = try await worker.run {
                    try ProjectProtector.protect(plan, vaultURL: vaultURL, keyURL: keyURL, sharedValues: values)
                }
                guard case .committed(let applied) = outcome else {
                    if case .sharedValueMatches(let matches) = outcome {
                        batch.held.append((plan, matches))
                    }
                    continue
                }
                batch.done.append((plan, applied))
                await spliceMarkerIntoScanCache(markerURL: plan.directory.appendingPathComponent(".sharibako"))
                removeCandidate(plan.directory)
            } catch {
                batch.failed.append((plan.name, Self.message(for: error)))
            }
        }
        loadScopes()
        return batch
    }

    /// Lands a committed batch by where it was asked from.
    ///
    /// One line or one page selects the project and announces it; Protect
    /// all follows the selection and announces the totals. Forgets the committed flips —
    /// the line's own for one line, the folder's for the rest.
    func landProtect(_ batch: ProtectBatch, origin: ProtectOrigin) async {
        for done in batch.done {
            switch origin {
            case .line(let key):
                lineChoiceFlips[Self.lineChoiceKey(folder: done.plan.directory, key: key)] = nil
            case .page, .all:
                clearLineChoices(for: done.plan.directory)
            }
        }
        switch origin {
        case .line(let key):
            await finishSingleProtect(batch, keepSelectedLine: key)
        case .page:
            await finishSingleProtect(batch, keepSelectedLine: nil)
        case .all:
            await followSelectionAfterProtectAll(batch)
            if !batch.done.isEmpty {
                let applied = batch.done.flatMap(\.applied)
                statusMessage = Self.protectAllSummary(projects: batch.done.count, decisions: applied)
            } else {
                let quiet = batch.failed.isEmpty && batch.held.isEmpty
                statusMessage = quiet ? Self.nothingToProtect(in: nil) : nil
            }
            reportFailures(batch.failed)
        }
    }

    /// Lands a one-folder Protect: on success selects the project, reloads
    /// its lines, and announces; on failure reports it in the pane.
    private func finishSingleProtect(_ batch: ProtectBatch, keepSelectedLine key: String?) async {
        guard let done = batch.done.first else {
            reportFailures(batch.failed)
            return
        }
        let project = Selection.project(scopeID: done.plan.scopeID)
        selection = project
        await loadContent(for: project)
        if let key {
            selectedLineKey = key
        }
        statusMessage = Self.protectSummary(name: done.plan.name, decisions: done.applied)
        errorMessage = nil
        paneError = nil
    }

    /// After Protect all: a selected folder that was protected becomes its
    /// project; anything else stays selected.
    private func followSelectionAfterProtectAll(_ batch: ProtectBatch) async {
        guard case .candidate(let directory) = selection else { return }
        let path = directory.standardizedFileURL.path
        guard let done = batch.done.first(where: { $0.plan.directory.standardizedFileURL.path == path }) else {
            return
        }
        let project = Selection.project(scopeID: done.plan.scopeID)
        selection = project
        await loadContent(for: project)
    }

    /// Reports every failure in one line, in the status bar and the pane; a
    /// no-op with none (and then clears both).
    private func reportFailures(_ failures: [(name: String, message: String)]) {
        guard !failures.isEmpty else {
            errorMessage = nil
            paneError = nil
            return
        }
        let message = failures.map { "Could not protect \($0.name): \($0.message)" }.joined(separator: " ")
        reportPaneError(message, nextStep: nil)
    }

    /// Sets a pane-local error and its status-bar echo together (Decision 8).
    func reportPaneError(_ message: String, nextStep: String?) {
        errorMessage = message
        paneError = PaneError(message: message, nextStep: nextStep)
    }

    /// Splices the claim file a Protect just wrote into the cached scan
    /// report so the sidebar is right immediately.
    ///
    /// One file read instead of re-running `Materializer.scan` over every
    /// root (the ho-06.3 gate's "why is import SO SLOW": an unbounded walk
    /// per commit). Failures are swallowed — the Protect already succeeded
    /// and the next Rescan or launch scan self-corrects the cache.
    private func spliceMarkerIntoScanCache(markerURL: URL) async {
        guard case .open(let vaultURL) = vaultState else { return }
        let marker = try? await worker.run {
            let core = try VaultCore(vaultURL: vaultURL)
            return try Materializer(vaultCore: core, vaultURL: vaultURL).loadMarker(at: markerURL)
        }
        guard let marker else { return }
        let existing = scanReport ?? ScanReport(markers: [], failures: [])
        var markers = existing.markers.filter {
            $0.markerURL.standardizedFileURL.path != markerURL.standardizedFileURL.path
        }
        markers.append(marker)
        updateScanReport(ScanReport(markers: markers, failures: existing.failures))
    }
}

// MARK: - Committing a folder (pure, off-main-actor-safe)

/// The worker half of a Protect: a fresh `.env` read and one `acceptIngest`.
///
/// A plain `enum` (never instantiated) for the same off-main-actor reason as
/// ``EnvReader``.
enum ProjectProtector {
    /// What one folder's Protect did.
    enum Outcome: Sendable, Equatable {
        /// The decisions actually applied.
        case committed([KeyDecision])
        /// Nothing was committed: these lines to protect for this project
        /// hold a shared secret's value (ho-06.10 AT-05).
        case sharedValueMatches([WorkshopModel.SharedValueMatch])
    }

    /// Re-reads a plan's folder and commits its decisions.
    ///
    /// Before committing, each line to protect for this project
    /// (`importAsLocal`) is compared with `sharedValues` (ID → decrypted
    /// value) by Check all's own comparison
    /// (``ProjectChecker/sharedID(matching:in:)``); any match returns
    /// ``Outcome/sharedValueMatches(_:)`` and commits nothing. Empty
    /// `sharedValues` skips the comparison.
    ///
    /// The decisions go into the plan's project.
    /// The fresh read means the values encrypted are the ones on disk now, and
    /// a decision for a line removed from the file since the page was read is
    /// dropped rather than failing the whole folder. `acceptIngest` creates
    /// the project when the vault lacks it and adds to it when it does.
    ///
    /// `acceptIngest` rewrites the claim file with no `materialize_to`; an
    /// existing claim file for the same project that named one gets it back,
    /// so adding lines to a project never moves where Write .env writes. No
    /// Core change: `writeMarker` is public, and the CLI's `init` is untouched.
    ///
    /// - Returns: What was done.
    static func protect(
        _ plan: WorkshopModel.ProtectPlan, vaultURL: URL, keyURL: URL, sharedValues: [String: String] = [:]
    ) throws -> Outcome {
        let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
        let materializer = Materializer(vaultCore: core, vaultURL: vaultURL)
        let proposal = try materializer.ingest(directory: plan.directory)
        let present = Set(proposal.detectedKeys.map(\.key))
        let decisions = plan.decisions.filter { present.contains(key(of: $0)) }
        let matches = sharedValueMatches(decisions, detected: proposal.detectedKeys, sharedValues: sharedValues)
        guard matches.isEmpty else { return .sharedValueMatches(matches) }
        let markerURL = plan.directory.appendingPathComponent(".sharibako")
        let previous = try? materializer.loadMarker(at: markerURL)
        try materializer.acceptIngest(
            proposal, decisions: decisions, scopeID: plan.scopeID, scopeType: .projectDev)
        if let previous, previous.scope == plan.scopeID, let target = previous.materializeTo {
            let restored = ScopeMarker(scope: plan.scopeID, materializeTo: target, markerURL: markerURL)
            try materializer.writeMarker(restored, at: markerURL)
        }
        return .committed(decisions)
    }

    /// The lines to protect for this project whose value equals a shared
    /// secret's, in decision order.
    static func sharedValueMatches(
        _ decisions: [KeyDecision], detected: [DetectedKey], sharedValues: [String: String]
    ) -> [WorkshopModel.SharedValueMatch] {
        guard !sharedValues.isEmpty else { return [] }
        var values: [String: String] = [:]
        for line in detected where values[line.key] == nil {
            values[line.key] = line.value
        }
        return decisions.compactMap { decision in
            guard case .importAsLocal(let key) = decision, let value = values[key],
                let id = ProjectChecker.sharedID(matching: value, in: sharedValues)
            else { return nil }
            return WorkshopModel.SharedValueMatch(key: key, sharedID: id)
        }
    }

    /// The key a decision is for.
    static func key(of decision: KeyDecision) -> String {
        switch decision {
        case .importAsLocal(let key), .linkToShared(let key, _), .moveToShared(let key, _),
            .leaveAlone(let key), .skip(let key):
            return key
        }
    }
}
