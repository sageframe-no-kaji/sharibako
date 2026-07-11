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
    /// the sidebar badge and the Materialize-all-stale set.
    static func isDrifted(_ report: DriftReport) -> Bool {
        report.owned.contains { drift in
            switch drift {
            case .match: return false
            case .fileMissing, .fileValueDiffers, .fileLineCorrupted: return true
            }
        }
    }

    /// The number of drifted owned keys in a report — the badge tooltip count.
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

    // MARK: - Badge + per-key reads (cache-only, synchronous)

    /// The sidebar drift badge for `scopeID`, or `nil` when no check has run
    /// for it — the row then shows only its AT-01 glyph, no badge.
    enum DriftBadge: Equatable {
        /// Every owned key is in sync as of the last check.
        case clean
        /// `keyCount` owned keys have drifted as of the last check.
        case drifted(keyCount: Int)

        /// SF Symbol — shape-distinct (colorblind-safe) from the AT-01 glyphs
        /// and from each other.
        var symbolName: String {
            switch self {
            case .clean: return "checkmark.seal"
            case .drifted: return "exclamationmark.triangle.fill"
            }
        }

        /// The badge's help tooltip.
        var helpText: String {
            switch self {
            case .clean:
                return "In sync — the materialized .env matches the vault as of the last check"
            case .drifted(let keyCount):
                return "\(keyCount) key\(keyCount == 1 ? "" : "s") drifted from the vault"
            }
        }
    }

    /// The cached drift badge for `scopeID`, read from ``driftReports`` only.
    ///
    /// `nil` before a Check-drift has run for the scope (no ambient badge,
    /// Decision 3); `.clean` / `.drifted` from the cached report otherwise.
    func driftBadge(forScope scopeID: String) -> DriftBadge? {
        guard let report = driftReports[scopeID] else { return nil }
        let count = Self.driftedKeyCount(report)
        return count == 0 ? .clean : .drifted(keyCount: count)
    }

    /// The cached drift report for `scopeID`, for the detail pane's per-key
    /// display; `nil` before a check has run for the scope.
    func driftReport(forScope scopeID: String) -> DriftReport? {
        driftReports[scopeID]
    }

    /// The `live_here` scopes a sweep would check — vault scopes with a marker
    /// in the scan roots (AT-01's ``glyphState(forScope:)``).
    var liveHereScopes: [ScopeMetadata] {
        scopes.filter { glyphState(forScope: $0.identity) == .liveHere }
    }

    // MARK: - Check-drift sweep

    /// Sweeps drift across every `live_here` scope behind one Touch ID and
    /// caches a ``DriftReport`` per scope (Decision 3).
    ///
    /// Async (Decision 1): each ``Materializer/heal(marker:)`` decrypts every
    /// owned key — the same weight as materialize — so the compare runs through
    /// ``worker`` off the main thread. The age key is acquired ONCE on the main
    /// actor (user interaction, not CPU work) and its `Sendable` handle URL is
    /// reused across the whole sweep, so one Touch ID covers it (ho-06.1's
    /// 5-minute reuse window). Guards re-entry against ``activity``. Announces
    /// the outcome through ``statusMessage`` including the no-drift and
    /// nothing-to-check cases (the silent-success rule); errors land in
    /// ``errorMessage``. Results replace ``driftReports`` wholesale on success
    /// so a scope that is no longer `live_here` doesn't keep a stale report.
    func checkDrift() async {
        guard activity == nil else { return }
        guard case .open(let vaultURL) = vaultState else { return }
        statusMessage = nil
        let candidates = liveHereScopes
        guard !candidates.isEmpty else {
            // Honest conclusion — the sweep visibly did nothing because there
            // was nothing materialized here to check (no Touch ID spent).
            statusMessage = "No materialized scopes to check for drift."
            return
        }
        activity = .checkingDrift
        defer { activity = nil }
        let provider = makeAgeKeyProvider()
        let handle: AgeKeyHandle
        do {
            handle = try provider.loadIdentity(reason: "Check drift across materialized scopes")
        } catch {
            errorMessage = "Could not load age key: \(error)"
            return
        }
        defer { handle.release() }
        let keyURL = handle.url
        do {
            var reports: [String: DriftReport] = [:]
            for scope in candidates {
                guard let marker = cachedMarker(forScope: scope.identity) else { continue }
                let report = try await worker.run {
                    let core = try VaultCore(vaultURL: vaultURL, ageKeyURL: keyURL)
                    return try Materializer(vaultCore: core, vaultURL: vaultURL).heal(marker: marker)
                }
                reports[scope.identity] = report
            }
            driftReports = reports
            let checked = reports.count
            let drifted = reports.values.filter { Self.isDrifted($0) }.count
            statusMessage =
                "Checked \(checked) scope\(checked == 1 ? "" : "s") — "
                + "\(drifted) drifted."
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    // MARK: - Reconcile refresh

    /// Clears the selected scope's cached drift after it reconciles.
    ///
    /// Called from ``applyMaterializeResult(_:)`` on a successful write /
    /// already-up-to-date outcome: the file now matches the vault, so the
    /// cached "drifted" report is stale — dropping it removes the badge until
    /// the next Check-drift refills it (Decision 3's "clear it and let the next
    /// check refill").
    func clearDriftForSelectedScope() {
        guard let scopeID = selectedScopeID else { return }
        driftReports.removeValue(forKey: scopeID)
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
                // The forced write brings the file into sync — drop the stale
                // report so the badge stops showing drift.
                driftReports.removeValue(forKey: scopeID)
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
