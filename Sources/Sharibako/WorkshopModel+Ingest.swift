import Foundation
import SharibakoCore

/// The GUI ingest flow's state machine and intents (ho-06.3 Decision 6) —
/// bringing a `.env`-bearing project directory into the vault as a scope.
/// `IngestSheet` (`Views/IngestSheet.swift`) reads ``WorkshopModel/ingest``
/// and calls the intents below; no branching logic lives in the view
/// (Required Change 4, Do Not §4).
///
/// Three entry points share this one surface (Decision 6): the action
/// panel's **Ingest Project…** verb, the first-run wizard's finish hand-off
/// (``offerFirstRunIngestInvite(under:)``), and — AT-03 — orphaned-marker
/// rows. Every semantic here mirrors `SharibakoCLI`'s `InitCommand` /
/// `Materializer+Ingest.swift` without importing CLI code (Do Not §1): the
/// reconcile filter, the nothing-to-import rejection, and the scope-ID
/// collision confirmation are re-derived from the same `SharibakoCore`
/// primitives the CLI walks.
///
/// Split out the way every other feature's intents are
/// (`WorkshopModel+Mutations.swift`, `+Heal.swift`, `+FirstRun.swift`) — the
/// `Conduit`/`Conduit+Remote.swift` precedent.
extension WorkshopModel {
    // MARK: - Nested state

    /// The active ingest session: one scan's proposal plus the operator's
    /// per-key decisions and scope choice, live until commit or cancel.
    struct IngestSession: Equatable {
        /// The directory scanned.
        let directory: URL

        /// The (possibly reconcile-filtered) proposal from
        /// ``IngestScanPlanner/plan(materializer:vault:directory:)``.
        let proposal: ProposedScope

        /// Per-key routing decision, keyed by ``DetectedKey/key``.
        ///
        /// Populated with `.importAsLocal` for every detected key when the
        /// session opens (Required Change 1's default);
        /// ``WorkshopModel/setIngestDecision(_:forKey:)`` overrides
        /// individual entries.
        var decisions: [String: KeyDecision]

        /// The scope ID the commit will use — the suggestion on a fresh
        /// ingest, the marker's own scope (fixed) on reconcile.
        var scopeID: String

        /// The scope type the commit will use.
        ///
        /// Fixed on reconcile, mirroring the CLI (`InitCommand._run`'s
        /// reconcile branch never prompts for type either).
        var scopeType: ScopeType

        /// `true` when `directory` already carried a `.sharibako` marker at
        /// scan time — reconcile mode: the scope ID/type fields are fixed,
        /// only unowned keys are listed (Required Change 1).
        let isReconcile: Bool

        /// Existing shared-entry IDs, for the link-to-shared verdict's
        /// picker (Required Change 2 — link is offered only when non-empty).
        let sharedIDs: [String]

        /// Vault scope identities that existed at scan time, for the
        /// scope-ID collision banner (Required Change 1).
        let existingScopeIDs: Set<String>

        /// `true` when the (possibly user-edited) ``scopeID`` names a scope
        /// that already exists — the CLI's collision confirmation (Decision 6).
        ///
        /// Rendered inline instead of a blocking prompt. Never fires on
        /// reconcile, where the ID always already names the marker's own
        /// scope by construction.
        var isScopeCollision: Bool {
            !isReconcile && existingScopeIDs.contains(scopeID)
        }
    }

    /// The ingest sheet's own observable state — a nested `@Observable`
    /// object (the ``WorkshopModel/firstRun`` precedent) rather than more
    /// top-level `WorkshopModel` properties.
    @Observable
    @MainActor
    final class IngestState {
        // `internal var`, not `private(set)`: the mutating intents live in
        // `extension WorkshopModel` below — a different TYPE from
        // `IngestState` even though declared in this same file, so Swift's
        // `private`/`private(set)` can't reach across (the identical reason
        // `FirstRunState`'s fields are plain `var`). Views only ever read
        // these; the intents are the only writers by convention.

        /// The active session, or `nil` when the sheet is not presented.
        var session: IngestSession?

        /// Human-facing failure from the last ``WorkshopModel/commitIngest()``
        /// attempt, or `nil`.
        ///
        /// Kept separate from ``WorkshopModel/errorMessage`` so a failed
        /// commit's message renders inside the still-open sheet rather than
        /// the main window's status surface (Acceptance: "commit failure
        /// keeps the session").
        var errorMessage: String?

        init() {}
    }

    // MARK: - Begin (Required Change 1)

    /// Scans `directory` for ingestible secrets and opens the ingest sheet
    /// when there is real work to do.
    ///
    /// Keyless — the scan only parses `.env`-family files and reads the
    /// vault's filesystem, so this hops to ``worker`` for the tree walk
    /// without ever touching the age key. Three outcomes, mirroring
    /// `InitCommand`'s own three gates:
    /// - Nothing importable (no `.env`-family file, or every detected key
    ///   already reconciled) announces plainly through
    ///   ``WorkshopModel/statusMessage`` — never an empty scope, never a sheet.
    /// - An existing marker with nothing new to reconcile announces the same way.
    /// - Otherwise a session opens, every key defaulted to `.importAsLocal`.
    ///
    /// A no-op while another activity is in flight or the vault is closed
    /// (the panel button is already disabled in that state — this is the
    /// defensive guard, the `materializeSelectedScope`/`sync` precedent).
    func beginIngest(directory: URL) async {
        guard activity == nil else { return }
        guard case .open(let vaultURL) = vaultState else { return }
        statusMessage = nil
        activity = .scanning
        defer { activity = nil }
        do {
            let outcome = try await worker.run {
                let core = try VaultCore(vaultURL: vaultURL)
                let materializer = Materializer(vaultCore: core, vaultURL: vaultURL)
                return try IngestScanPlanner.plan(
                    materializer: materializer, vault: core, directory: directory)
            }
            applyIngestScanOutcome(outcome, directory: directory)
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Applies a completed scan's outcome to published state (main-actor).
    ///
    /// Split from ``beginIngest(directory:)`` so the awaited worker call
    /// stays a single expression (the `applyMaterializeResult` precedent).
    private func applyIngestScanOutcome(_ outcome: IngestScanPlanner.Outcome, directory: URL) {
        switch outcome {
        case .nothingToImport:
            statusMessage = "No secrets found to import in \(directory.lastPathComponent)."
        case .alreadyReconciled(let scopeID):
            statusMessage = "Directory already initialized as scope '\(scopeID)'. No new secrets to reconcile."
        case .session(let payload):
            var decisions: [String: KeyDecision] = [:]
            for key in payload.proposal.detectedKeys {
                decisions[key.key] = .importAsLocal(key: key.key)
            }
            ingest.session = IngestSession(
                directory: directory,
                proposal: payload.proposal,
                decisions: decisions,
                scopeID: payload.scopeID,
                scopeType: payload.scopeType,
                isReconcile: payload.isReconcile,
                sharedIDs: payload.sharedIDs,
                existingScopeIDs: payload.existingScopeIDs
            )
            ingest.errorMessage = nil
        }
    }

    // MARK: - Decision + scope editing (Required Change 2)

    /// Sets the routing decision for `key` in the active session.
    ///
    /// A no-op when no session is open — defensive, the sheet that calls
    /// this only exists while ``IngestState/session`` is non-nil.
    func setIngestDecision(_ decision: KeyDecision, forKey key: String) {
        ingest.session?.decisions[key] = decision
    }

    /// Updates the session's scope ID.
    ///
    /// Grammar validation (`VaultCore.isValidIdentifier`) and the collision
    /// banner both read the live value from ``IngestSession/scopeID`` — this
    /// just records the text; ``commitIngest()`` re-validates at the gate.
    func setIngestScopeID(_ scopeID: String) {
        ingest.session?.scopeID = scopeID
    }

    /// Updates the session's scope type.
    func setIngestScopeType(_ scopeType: ScopeType) {
        ingest.session?.scopeType = scopeType
    }

    // MARK: - Cancel

    /// Discards the active session without writing anything (Required
    /// Change 3 — Cancel discards).
    func cancelIngest() {
        ingest.session = nil
        ingest.errorMessage = nil
    }

    // MARK: - Commit (Required Change 3)

    /// Commits the active session through `Materializer.acceptIngest`
    /// behind one Touch ID.
    ///
    /// The age key is acquired on the main actor first (user interaction,
    /// not CPU work — every other mutating intent's rule), then only its
    /// `Sendable` handle URL crosses into ``worker``. On success: reloads
    /// scopes, refreshes the scan cache when roots are configured (06.2's
    /// glyphs must be right immediately — the marker `acceptIngest` just
    /// wrote needs a fresh scan to be found), selects the new/reconciled
    /// scope in the sidebar, closes the sheet, and announces the CLI's
    /// summary shape. On failure the session stays open with every decision
    /// intact (Acceptance: "commit failure keeps the session"); Cancel
    /// discards, this never does.
    func commitIngest() async {
        guard activity == nil else { return }
        guard case .open(let vaultURL) = vaultState,
            let session = ingest.session
        else { return }
        guard VaultCore.isValidIdentifier(session.scopeID) else {
            ingest.errorMessage = "Invalid scope ID — use letters, digits, and ._- (no path separators)."
            return
        }
        ingest.errorMessage = nil
        activity = .materializing
        defer { activity = nil }
        let provider = makeAgeKeyProvider()
        let handle: AgeKeyHandle
        do {
            handle = try provider.loadIdentity(reason: "Encrypt secrets during ingest")
        } catch {
            ingest.errorMessage = "Could not load age key: \(error)"
            return
        }
        let keyURL = handle.url
        let decisions = Array(session.decisions.values)
        let proposal = session.proposal
        let scopeID = session.scopeID
        let scopeType = session.scopeType
        do {
            try await worker.run {
                let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
                let materializer = Materializer(vaultCore: core, vaultURL: vaultURL)
                try materializer.acceptIngest(
                    proposal, decisions: decisions, scopeID: scopeID, scopeType: scopeType)
            }
            handle.release()
            await refreshScanCacheAfterIngestCommit()
            loadScopes()
            selectedScopeID = scopeID
            ingest.session = nil
            ingest.errorMessage = nil
            let markerURL = proposal.directory.appendingPathComponent(".sharibako")
            statusMessage = Self.ingestSummary(decisions: decisions, markerURL: markerURL)
            errorMessage = nil
        } catch {
            handle.release()
            ingest.errorMessage = Self.message(for: error)
        }
    }

    /// Re-scans the configured roots after a commit so the sidebar glyphs
    /// reflect the marker `acceptIngest` just wrote (Required Change 3).
    ///
    /// A no-op with no configured roots — the `performLaunchScan` precedent.
    /// Failures are swallowed here: the ingest itself already succeeded, and
    /// the next Rescan (or launch) will pick up the fresh marker; there is
    /// nothing actionable a scan failure at this point would tell the user
    /// that a later scan wouldn't also surface.
    private func refreshScanCacheAfterIngestCommit() async {
        guard case .open(let vaultURL) = vaultState else { return }
        let roots = scanRoots
        guard !roots.isEmpty else { return }
        let report = try? await worker.run {
            let core = try VaultCore(vaultURL: vaultURL)
            return try Materializer(vaultCore: core, vaultURL: vaultURL).scan(roots: roots)
        }
        guard let report else { return }
        updateScanReport(report)
    }

    /// Mirrors `InitCommand.reportResult`'s summary line without importing
    /// it — "imported N, linked N, moved N, left alone N, skipped N".
    private static func ingestSummary(decisions: [KeyDecision], markerURL: URL) -> String {
        var imported = 0
        var linked = 0
        var moved = 0
        var leftAlone = 0
        var skipped = 0
        for decision in decisions {
            switch decision {
            case .importAsLocal: imported += 1
            case .linkToShared: linked += 1
            case .moveToShared: moved += 1
            case .leaveAlone: leftAlone += 1
            case .skip: skipped += 1
            }
        }
        return
            "Imported \(imported), linked \(linked), moved \(moved), "
            + "left alone \(leftAlone), skipped \(skipped) — marker at \(markerURL.path)"
    }

    // MARK: - Wizard hand-off (Required Change 5)

    /// Worker-routed shallow walk of `root` for `.env`-bearing directories —
    /// the finish page's own read of the seam AT-01 left (``firstRunCompleted``).
    ///
    /// Pure logic (``IngestCandidateScanner``) hops to ``worker`` since it
    /// walks the filesystem; never touches the age key — finding `.env`
    /// files needs no decryption. Non-throwing: an unreadable subdirectory
    /// mid-walk is skipped by the scanner itself rather than aborting the
    /// whole probe (the wizard's finish page treats "found nothing" and "hit
    /// something unreadable" the same way — a plain close, never a blocker
    /// for a user who already has a vault).
    func findFirstRunIngestCandidates(under root: URL) async -> [URL] {
        await worker.run { IngestCandidateScanner.findCandidates(under: root) }
    }

    /// Opens the ingest sheet on the first (sorted) `.env`-bearing candidate
    /// found under `root`, or does nothing when none exist (Decision 1 step
    /// 6, Required Change 5).
    ///
    /// Called from `FirstRunWizard`'s "Create Vault" flow once
    /// ``completeFirstRun()`` has flipped ``vaultState`` to `.open` — by
    /// design the wizard's own view may already be off-screen by the time
    /// this resolves (the vault-state flip mid-`completeFirstRun()` swaps
    /// `WorkshopWindow` to its `.open` arm before this async chain finishes),
    /// so the result lands on ``ingest`` — model state `WorkshopWindow`
    /// reads reliably regardless of that timing — rather than on any
    /// `FirstRunWizard`-local `@State` (a judgment call recorded in the ho's
    /// Reflect: multiple candidates fall back to the panel verb for the
    /// rest rather than a second picker layered over the vanishing wizard).
    func offerFirstRunIngestInvite(under root: URL) async {
        let candidates = await findFirstRunIngestCandidates(under: root)
        guard let first = candidates.first else { return }
        await beginIngest(directory: first)
    }
}

// MARK: - Scan planning (pure, off-main-actor-safe)

/// Pure planning logic for a keyless ingest scan.
///
/// A plain `enum` (never instantiated), NOT a `WorkshopModel` static method:
/// ``WorkshopModel/beginIngest(directory:)`` calls this from inside
/// `VaultWorker.run`'s `@Sendable` closure, off the main actor — a method on
/// the `@MainActor`-isolated `WorkshopModel` type would carry that isolation
/// into the closure and fight `@Sendable`. Mirrors `InitCommand`'s
/// `filterProposal` gate (Required Change 1) without importing CLI code (Do
/// Not §1) — re-derived from the same `SharibakoCore` primitives the CLI
/// walks (`Materializer.ingest`, `VaultCore.inspect`).
enum IngestScanPlanner {
    /// The payload for `Outcome.session` — bundled into one `Sendable` type
    /// rather than a six-way associated-value case (SwiftLint's
    /// `enum_case_associated_values_count` ceiling).
    struct SessionOutcome: Sendable, Equatable {
        /// The (possibly reconcile-filtered) proposal.
        let proposal: ProposedScope
        /// The suggestion on a fresh ingest, the marker's own scope (fixed) on reconcile.
        let scopeID: String
        /// Fixed on reconcile, mirroring the CLI.
        let scopeType: ScopeType
        /// `true` when `directory` already carried a `.sharibako` marker at scan time.
        let isReconcile: Bool
        /// Existing shared-entry IDs, for the link-to-shared verdict's picker.
        let sharedIDs: [String]
        /// Vault scope identities that existed at scan time, for the collision banner.
        let existingScopeIDs: Set<String>
    }

    /// The scan's outcome — `Sendable` so it can cross back to the main
    /// actor from `VaultWorker.run`.
    enum Outcome: Sendable, Equatable {
        /// A session should open, keys defaulted to `.importAsLocal`.
        case session(SessionOutcome)
        /// An existing marker's scope already owns every key the scan found.
        case alreadyReconciled(scopeID: String)
        /// No `.env`-family file, or nothing in it worth importing.
        case nothingToImport
    }

    /// Scans `directory`, applies the reconcile filter when a `.sharibako`
    /// marker already binds it to a scope, and classifies the result.
    static func plan(
        materializer: Materializer,
        vault: VaultCore,
        directory: URL
    ) throws -> Outcome {
        let markerURL = directory.appendingPathComponent(".sharibako")
        let existingMarker = try loadExistingMarker(at: markerURL, materializer: materializer)
        let fullProposal = try materializer.ingest(directory: directory)

        let proposal: ProposedScope
        let isReconcile: Bool
        if let marker = existingMarker {
            proposal = filterProposal(fullProposal, existingScope: marker.scope, vault: vault)
            isReconcile = true
        } else {
            proposal = fullProposal
            isReconcile = false
        }

        guard !proposal.detectedKeys.isEmpty else {
            if let marker = existingMarker {
                return .alreadyReconciled(scopeID: marker.scope)
            }
            return .nothingToImport
        }

        let sharedIDs = try vault.listShared()
        let existingScopeIDs = Set(try vault.listScopes().map(\.identity))
        let scopeID = existingMarker?.scope ?? proposal.suggestedScopeID
        return .session(
            SessionOutcome(
                proposal: proposal,
                scopeID: scopeID,
                scopeType: proposal.suggestedScopeType,
                isReconcile: isReconcile,
                sharedIDs: sharedIDs,
                existingScopeIDs: existingScopeIDs
            )
        )
    }

    /// Loads the `.sharibako` marker at `markerURL`, or `nil` when none
    /// exists — direct `fileExists` detection, the CLI's own approach
    /// (`InitCommand.loadExistingMarker`, Decision 7 there).
    private static func loadExistingMarker(
        at markerURL: URL, materializer: Materializer
    ) throws -> ScopeMarker? {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return nil }
        return try materializer.loadMarker(at: markerURL)
    }

    /// Mirrors `InitCommand.filterProposal` — only keys the scope does not
    /// yet own are presented on reconcile.
    ///
    /// Already-owned keys are silently excluded. A vault read failure
    /// (orphaned marker naming a scope the vault has lost) falls back to
    /// treating nothing as owned, so the operator can re-ingest everything
    /// rather than being stuck.
    private static func filterProposal(
        _ full: ProposedScope,
        existingScope: String,
        vault: VaultCore
    ) -> ProposedScope {
        let ownedKeys: Set<String>
        if let infos = try? vault.inspect(existingScope) {
            ownedKeys = Set(infos.map(\.key))
        } else {
            ownedKeys = []
        }
        let newKeys = full.detectedKeys.filter { !ownedKeys.contains($0.key) }
        return ProposedScope(
            directory: full.directory,
            suggestedScopeID: existingScope,
            suggestedScopeType: full.suggestedScopeType,
            detectedKeys: newKeys,
            suggestedKeysNeedingValues: full.suggestedKeysNeedingValues,
            parseWarnings: full.parseWarnings
        )
    }
}

// MARK: - Candidate scanning (pure, off-main-actor-safe)

/// Pure directory-walk logic for the first-run finish page's ingest invite
/// (Required Change 5).
///
/// A plain `enum` for the same off-main-actor-safety reason as
/// ``IngestScanPlanner`` — called from inside `VaultWorker.run`.
enum IngestCandidateScanner {
    /// Maximum depth below `root` to walk (`root` itself is depth 0).
    ///
    /// Bounded so a wide scan root (a whole `~/Projects` with hundreds of
    /// repos) resolves fast — the marker scan's own discipline
    /// (`Materializer.scan`), mirrored rather than reused since that walk
    /// looks for `.sharibako` and this one looks for `.env`.
    static let maxDepth = 2

    /// Returns every directory at or below `root` (within ``maxDepth``)
    /// that contains a `.env` file, sorted by path for stable display.
    static func findCandidates(under root: URL) -> [URL] {
        let fileManager = FileManager.default
        var results: [URL] = []
        walk(root, depth: 0, fileManager: fileManager, results: &results)
        return results.sorted { $0.path < $1.path }
    }

    private static func walk(
        _ directory: URL, depth: Int, fileManager: FileManager, results: inout [URL]
    ) {
        guard depth <= maxDepth else { return }
        let envURL = directory.appendingPathComponent(".env")
        if fileManager.fileExists(atPath: envURL.path) {
            results.append(directory)
        }
        guard depth < maxDepth else { return }
        guard
            let children = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        else { return }
        for child in children {
            // Hidden directories (`.git`, dotfolders) have no reason to be
            // descended into on a `.env` search — the marker walk enumerates
            // everything because it must find `.sharibako` anywhere; this
            // walk only wants ordinary project directories.
            guard !child.lastPathComponent.hasPrefix(".") else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { continue }
            walk(child, depth: depth + 1, fileManager: fileManager, results: &results)
        }
    }
}
