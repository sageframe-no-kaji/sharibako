import Foundation
import SharibakoCore

/// The heal surface: pull-based, session-cached drift and its reconciliation
/// (ho-06.2 AT-02, Decision 3).
///
/// The forcing fact: ``Materializer/heal(marker:)`` decrypts every owned key to
/// compare vault-plaintext against file-plaintext, so drift cannot be known
/// without the age key and a Touch ID. Drift is therefore *pulled* by an
/// explicit ``checkDrift()`` sweep, then *cached* in ``WorkshopModel/driftReports``
/// for the session — exactly parallel to how ``WorkshopModel/scanReport`` caches
/// markers. Nothing here runs at launch or on selection change.
///
/// Reconcile — per-scope and batch — routes through the existing
/// ``WorkshopModel/materializeSelectedScope(force:)`` flow and its `pendingDiff`
/// confirmation; there is no second write path. Kept in its own file matching
/// the `Conduit`/`Conduit+Remote.swift` split precedent.
extension WorkshopModel {
    // MARK: - Drift classification (pure, tested)

    /// Whether a drift report indicates the scope's `.env` has drifted.
    ///
    /// Drifted when any owned key is `.fileValueDiffers`, `.fileMissing`, or
    /// `.fileLineCorrupted`; clean when every owned key is `.match`. Drives both
    /// the Out-of-date status (``projectStatus(forScope:)``) and the
    /// Materialize-all-stale set.
    static func isDrifted(_ report: DriftReport) -> Bool {
        report.owned.contains { drift in
            switch drift {
            case .match: return false
            case .fileMissing, .fileValueDiffers, .fileLineCorrupted: return true
            }
        }
    }

    /// The number of drifted owned keys in a report — the Out-of-date count.
    static func driftedKeyCount(_ report: DriftReport) -> Int {
        report.owned.reduce(into: 0) { count, drift in
            switch drift {
            case .match: break
            case .fileMissing, .fileValueDiffers, .fileLineCorrupted: count += 1
            }
        }
    }

    /// A single owned key's drift, rendered in plain language for the detail
    /// pane — never surfacing plaintext or the SHA digests.
    ///
    /// The `fileValueDiffers` digests exist only to prove difference; a
    /// "Differs" label is the whole user-facing truth (the Do-Not in AT-02).
    static func driftStatusLabel(for drift: KeyDrift) -> String {
        switch drift {
        case .match: return "In sync"
        case .fileMissing: return "Missing from file"
        case .fileValueDiffers: return "Differs"
        case .fileLineCorrupted: return "Malformed line"
        }
    }

    /// The owned key a `KeyDrift` describes.
    static func driftKey(_ drift: KeyDrift) -> String {
        switch drift {
        case .match(let key), .fileMissing(let key),
            .fileValueDiffers(let key, _, _), .fileLineCorrupted(let key):
            return key
        }
    }

    /// Whether a single owned key has drifted — drives the detail pane's red
    /// status coloring (gate finding: drift needs to read at a glance, not blend
    /// into the in-sync rows).
    static func isKeyDrifted(_ drift: KeyDrift) -> Bool {
        switch drift {
        case .match: return false
        case .fileMissing, .fileValueDiffers, .fileLineCorrupted: return true
        }
    }

    // MARK: - Per-key reads (cache-only, synchronous)

    /// The cached drift report for `scopeID`, for the detail pane's per-key
    /// display; `nil` before a check has run for the scope.
    func driftReport(forScope scopeID: String) -> DriftReport? {
        driftReports[scopeID]
    }

    /// The cached drift for a single owned `key` in `scopeID`, for the
    /// secret-detail pane's inline drift banner; `nil` when no check has run for
    /// the scope or the key is not owned.
    ///
    /// Lets the drift stay visible when a key is selected (gate finding: drift
    /// vanished the moment you drilled into a secret), not just in the
    /// scope-overview pane.
    func keyDrift(forScope scopeID: String, key: String) -> KeyDrift? {
        driftReports[scopeID]?.owned.first { Self.driftKey($0) == key }
    }

    /// The `live_here` scopes a sweep would check — vault scopes with a marker
    /// in the scan roots (the projects whose folder is on this Mac).
    var liveHereScopes: [ScopeMetadata] {
        scopes.filter { cachedMarker(forScope: $0.identity) != nil }
    }

    // MARK: - Check all (ho-06.10 AT-04)

    /// Check all's announce: "4 checked · 1 out of date · 2 could not be
    /// read", with the could-not-be-read clause only when some could not be
    /// read, and a closing clause when lines match a shared secret's value.
    static func checkAllSummary(checked: Int, outOfDate: Int, unreadable: Int, matches: Int) -> String {
        var parts = ["\(checked) checked", "\(outOfDate) out of date"]
        if unreadable > 0 {
            parts.append("\(unreadable) could not be read")
        }
        if matches > 0 {
            parts.append(matches == 1 ? "1 line matches a shared secret" : "\(matches) lines match a shared secret")
        }
        return parts.joined(separator: " · ")
    }

    /// Checks every project with a folder on this Mac behind one Touch ID,
    /// and notices protected values equal to a shared secret's (Decision 3,
    /// ho-06.10 Decision 8).
    ///
    /// Async (Decision 1): each project's check decrypts every key it owns,
    /// the same weight as Write .env, so it runs through ``worker``. The age
    /// key is acquired ONCE on the main actor and its `Sendable` handle URL
    /// reused across the sweep, so one Touch ID covers it — the shared
    /// secrets' values are decrypted once, up front, inside the same handle.
    /// Each project is checked in its own worker hop and its failure caught:
    /// a project this key cannot read lands in ``unreadableProjects`` (its
    /// pane shows why, with a next step) and the sweep goes on. Results
    /// replace ``driftReports``, ``unreadableProjects``, and
    /// ``sharedMatches`` wholesale, so a project no longer here keeps no
    /// stale result. Announces through ``statusMessage`` every time,
    /// including when there is nothing to check (the silent-success rule).
    func checkDrift() async {
        guard activity == nil else { return }
        guard case .open(let vaultURL) = vaultState else { return }
        statusMessage = nil
        let projects = liveHereScopes
        guard !projects.isEmpty else {
            // Honest conclusion — nothing to check, so no Touch ID spent.
            statusMessage = "No protected projects with a folder on this Mac to check."
            return
        }
        activity = .checkingDrift
        defer { activity = nil }
        let handle: AgeKeyHandle
        do {
            handle = try makeAgeKeyProvider().loadIdentity(reason: "Check every protected project against its .env")
        } catch {
            errorMessage = "Could not load age key: \(error)"
            return
        }
        defer { handle.release() }
        let keyURL = handle.url
        let ids = sharedIDs
        let sharedValues = await worker.run {
            ProjectChecker.sharedValues(ids, vaultURL: vaultURL, keyURL: keyURL)
        }
        var reports: [String: DriftReport] = [:]
        var unreadable: [String: PaneError] = [:]
        var matches: [String: [String: String]] = [:]
        for scope in projects {
            guard let marker = cachedMarker(forScope: scope.identity) else { continue }
            do {
                let checked = try await worker.run {
                    try ProjectChecker.check(
                        marker: marker, vaultURL: vaultURL, keyURL: keyURL, sharedValues: sharedValues)
                }
                reports[scope.identity] = checked.report
                if !checked.matches.isEmpty {
                    matches[scope.identity] = checked.matches
                }
            } catch {
                unreadable[scope.identity] = PaneError(
                    message: Self.message(for: error), nextStep: Self.nextStep(for: error))
            }
        }
        driftReports = reports
        unreadableProjects = unreadable
        sharedMatches = matches
        statusMessage = Self.checkAllSummary(
            checked: reports.count,
            outOfDate: reports.values.filter { Self.isDrifted($0) }.count,
            unreadable: unreadable.count,
            matches: matches.values.reduce(0) { $0 + $1.count }
        )
        errorMessage = nil
    }

    // MARK: - Reconcile refresh

    /// Refreshes the selected scope's cached drift after it reconciles.
    ///
    /// Called from ``applyMaterializeResult(_:)`` on a successful write /
    /// already-up-to-date outcome. A full materialize writes every owned value
    /// into the file, so the scope is in sync *by construction* — rather than
    /// dropping the cached report (which reverted the detail pane to its "no
    /// check yet" empty state and read as a blank window at the 06.2 gate),
    /// ``markScopeInSync(_:)`` rebuilds it as an all-`match` report. The detail
    /// pane stays on the drift view showing every key "In sync" and the badge
    /// flips to clean (Decision 3's "re-heal it" branch — done without a decrypt
    /// or a new Touch ID, since the in-sync result is known from the write).
    func refreshDriftForSelectedScopeAfterWrite() {
        guard let scopeID = selectedScopeID else { return }
        markScopeInSync(scopeID)
    }

    /// Rebuilds a reconciled scope's cached drift as an all-in-sync report.
    ///
    /// Runs only when the scope already had a cached report, so a plain
    /// Materialize on a never-checked scope never conjures an ambient badge
    /// (Decision 3's no-badge-without-a-check).
    ///
    /// The owned key list comes from ``VaultCore/inspect(_:)``, which lists keys
    /// without decrypting, so this stays a synchronous, key-free refresh. If the
    /// vault read fails, the entry is dropped rather than left stale.
    func markScopeInSync(_ scopeID: String) {
        guard driftReports[scopeID] != nil else { return }
        guard case .open(let vaultURL) = vaultState,
            let core = try? VaultCore(vaultURL: vaultURL),
            let infos = try? core.inspect(scopeID)
        else {
            driftReports.removeValue(forKey: scopeID)
            return
        }
        let owned = infos.map(\.key).sorted().map { KeyDrift.match(key: $0) }
        let path = driftReports[scopeID]?.path ?? URL(fileURLWithPath: "/")
        driftReports[scopeID] = DriftReport(
            scopeID: scopeID, path: path, owned: owned, parseWarnings: [])
    }

    // MARK: - Materialize all stale

    /// The scopes a Materialize-all-stale run would reconcile, for the
    /// confirmation dialog (Decision 3).
    struct AllStalePlan: Equatable {
        /// Drifted scope ids, sorted for stable display.
        let scopeIDs: [String]
        /// Target `.env` paths that will be written, parallel to ``scopeIDs``.
        let targetPaths: [String]
    }

    /// Computes the drifted set from the drift cache and stages a confirmation
    /// (Decision 3).
    ///
    /// When ``driftReports`` is empty (no check has run), prompts the user to
    /// Check drift first rather than silently doing nothing. When a check has
    /// run but nothing drifted, says so. Otherwise stages an ``AllStalePlan``.
    func requestMaterializeAllStale() {
        guard activity == nil else { return }
        guard case .open = vaultState else { return }
        statusMessage = nil
        guard !driftReports.isEmpty else {
            statusMessage = "Check drift first — there's no drift information yet."
            return
        }
        let drifted = driftReports.filter { Self.isDrifted($0.value) }
        guard !drifted.isEmpty else {
            statusMessage = "Nothing to reconcile — every checked scope is in sync."
            return
        }
        let sortedIDs = drifted.keys.sorted()
        let paths = sortedIDs.compactMap { driftReports[$0]?.path.path }
        allStalePlan = AllStalePlan(scopeIDs: sortedIDs, targetPaths: paths)
    }

    /// Dismisses the pending Materialize-all-stale plan (user cancelled).
    func dismissAllStale() {
        allStalePlan = nil
    }

    /// Reconciles the drifted set behind one confirmation and one Touch ID
    /// (Decision 3).
    ///
    /// Forces the write for each drifted scope through ``worker`` (reusing the
    /// existing `materialize(marker:overwriteDrift:)` — no second write path),
    /// riding the one Touch ID across the batch, then clears each scope's cached
    /// drift so the badges refresh. Announces the batch outcome through
    /// ``statusMessage``.
    func confirmMaterializeAllStale() async {
        guard activity == nil else { return }
        guard case .open(let vaultURL) = vaultState else { return }
        guard let plan = allStalePlan else { return }
        allStalePlan = nil
        statusMessage = nil
        activity = .materializing
        defer { activity = nil }
        let provider = makeAgeKeyProvider()
        let handle: AgeKeyHandle
        do {
            handle = try provider.loadIdentity(reason: "Reconcile drifted scopes")
        } catch {
            errorMessage = "Could not load age key: \(error)"
            return
        }
        defer { handle.release() }
        let keyURL = handle.url
        do {
            var wrote = 0
            for scopeID in plan.scopeIDs {
                guard let marker = cachedMarker(forScope: scopeID) else { continue }
                let result = try await worker.run {
                    let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
                    let materializer = Materializer(vaultCore: core, vaultURL: vaultURL)
                    return try materializer.materialize(marker: marker, overwriteDrift: true)
                }
                // The forced write brings the file into sync — refresh the
                // cached report to all-`match` so the badge flips to clean
                // rather than vanishing (gate finding, same as reconcile).
                markScopeInSync(scopeID)
                if case .wrote = result { wrote += 1 }
            }
            let total = plan.scopeIDs.count
            statusMessage =
                "Reconciled \(wrote) of \(total) drifted scope\(total == 1 ? "" : "s")."
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }
}

// MARK: - Checking one project (pure, off-main-actor-safe)

/// The worker half of Check all: one project's check and value match, and
/// the shared secrets' values read once per sweep.
///
/// A plain `enum` (never instantiated) for the same off-main-actor reason as
/// ``EnvReader``.
enum ProjectChecker {
    /// One project's result: its check, and its protected lines whose value
    /// equals a shared secret's (key → shared ID).
    struct Checked: Sendable {
        /// The project's check against its `.env`.
        let report: DriftReport
        /// Key → the shared secret with the same value.
        let matches: [String: String]
    }

    /// Decrypts every shared secret's value, by ID; one that cannot be read
    /// is left out rather than failing the sweep — a match is a hint, never
    /// a requirement.
    static func sharedValues(_ ids: [String], vaultURL: URL, keyURL: URL) -> [String: String] {
        guard let core = try? VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL) else { return [:] }
        var values: [String: String] = [:]
        for id in ids {
            if let value = try? core.getSharedValue(id) {
                values[id] = value
            }
        }
        return values
    }

    /// Checks one project's `.env` against the vault and compares each of its
    /// own protected values with `sharedValues`.
    ///
    /// A line already using a shared secret is not compared. With several
    /// shared secrets of the same value, the first by ID is named.
    static func check(
        marker: ScopeMarker, vaultURL: URL, keyURL: URL, sharedValues: [String: String]
    ) throws -> Checked {
        let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
        let report = try Materializer(vaultCore: core, vaultURL: vaultURL).heal(marker: marker)
        guard !sharedValues.isEmpty else { return Checked(report: report, matches: [:]) }
        var matches: [String: String] = [:]
        for info in try core.inspect(marker.scope) where info.kind == .value {
            let value = try core.getValue(info.key, inScope: marker.scope)
            if let id = sharedValues.filter({ $0.value == value }).keys.min() {
                matches[info.key] = id
            }
        }
        return Checked(report: report, matches: matches)
    }
}
