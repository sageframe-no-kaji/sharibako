import Foundation
import SharibakoCore

/// Orphan-remediation intents for the "Unlinked markers" section's
/// `.orphaned` rows (ho-06.3 Decision 7, AT-03) — the two verbs that turn
/// surfacing into action once ho-06.2 stopped at naming the marker.
///
/// **Create Scope from Marker** rides ``WorkshopModel/beginIngest(directory:)``
/// unchanged (Do Not §4): the orphaned marker's own `.sharibako` file is
/// exactly what that scan's reconcile detection loads, so pointing it at the
/// marker's directory reproduces the marker's recorded scope ID as the
/// session's seed with no new machinery.
///
/// **Remove Stray Marker** follows the ho-06.7 pending-deletion trio
/// (`WorkshopModel+Mutations.swift`) precisely: `requestRemoveStrayMarker` /
/// `confirmRemoveStrayMarker` / `dismissStrayMarkerRemoval`, staged state on
/// the model, a system-rendered destructive confirmation in
/// `WorkshopWindow.swift`. The blast radius is inverted from every 06.7
/// deletion — the file removed lives in the user's project directory, not
/// the vault — so the confirmation copy says exactly that; the removal
/// itself touches only that one file (`FileManager`, no git, no vault
/// write).
///
/// Split into its own file rather than folded into
/// `WorkshopModel+Glyphs.swift` (the `UnlinkedMarker` derivation the panel
/// reads): that file is pure derivation over the scan cache, and these
/// intents mutate — the `Conduit`/`Conduit+Remote.swift` split precedent
/// applies again, this time by read/write rather than by feature.
extension WorkshopModel {
    // MARK: - Create Scope from Marker (Required Change 1)

    /// Seeds the ingest sheet with an orphaned marker's directory.
    ///
    /// The marker at `marker`'s recorded path already carries the scope name
    /// the vault forgot; `beginIngest(directory:)`'s own marker-detection
    /// (`IngestScanPlanner.plan`) loads that same `.sharibako` file and
    /// reconciles under its scope unchanged — the vault side simply doesn't
    /// have that scope yet, so every detected key comes back unowned and
    /// `commitIngest()`'s `acceptIngest` creates the scope idempotently on
    /// commit (recreating under the marker's own ID is what heals the link).
    /// A no-op for `.failed` markers — scan-failure rows stay surfacing-only
    /// (Do Not §3).
    func createScopeFromMarker(_ marker: UnlinkedMarker) async {
        guard case .orphaned(_, let markerURL) = marker else { return }
        await beginIngest(directory: markerURL.deletingLastPathComponent())
    }

    // MARK: - Remove Stray Marker (Required Change 2)

    /// A staged stray-marker removal awaiting the window's confirmation.
    struct StrayMarkerRemoval: Equatable {
        /// The scope name the marker referenced — named in the confirmation
        /// and the success announce.
        let scope: String
        /// The `.sharibako` file's on-disk path — the only file the confirm
        /// step touches.
        let markerURL: URL
    }

    /// Stages removal of the `.sharibako` file `marker` names, to be
    /// confirmed in the window.
    ///
    /// A no-op for `.failed` markers (Do Not §3) or while another activity is
    /// in flight — the same defensive guard
    /// ``requestDeleteSelectedScope()`` uses.
    func requestRemoveStrayMarker(_ marker: UnlinkedMarker) {
        guard activity == nil else { return }
        guard case .orphaned(let scope, let markerURL) = marker else { return }
        statusMessage = nil
        pendingStrayMarkerRemoval = StrayMarkerRemoval(scope: scope, markerURL: markerURL)
    }

    /// Dismisses the pending stray-marker removal (user cancelled).
    func dismissStrayMarkerRemoval() {
        pendingStrayMarkerRemoval = nil
    }

    /// Deletes the staged marker file and drops it from the cached scan
    /// report so the orphan row leaves the section immediately.
    ///
    /// Touches only ``StrayMarkerRemoval/markerURL`` — no git, no vault
    /// write, the vault and the project's `.env` are both untouched (the
    /// inverted blast radius, Required Change 2). The cache update is a
    /// local filter of the already-loaded ``WorkshopModel/scanReport``
    /// rather than a fresh filesystem walk — deleting one known file cannot
    /// surface any marker a re-scan would have found, so paying for another
    /// walk through ``WorkshopModel/worker`` buys nothing here (contrast
    /// `refreshScanCacheAfterIngestCommit()` in `WorkshopModel+Ingest.swift`,
    /// which must re-walk because a commit can *add* a marker a stale cache
    /// wouldn't know about). Failure — the file is already gone, or
    /// permissions refuse the removal — announces via
    /// ``WorkshopModel/errorMessage`` and leaves every other field
    /// untouched, matching the ho-06.7 trio's own failure posture.
    func confirmRemoveStrayMarker() {
        guard let removal = pendingStrayMarkerRemoval else { return }
        pendingStrayMarkerRemoval = nil
        do {
            try FileManager.default.removeItem(at: removal.markerURL)
        } catch {
            errorMessage =
                "Could not remove marker at \(removal.markerURL.path): \(Self.message(for: error))"
            return
        }
        if let report = scanReport {
            updateScanReport(
                ScanReport(
                    markers: report.markers.filter { $0.markerURL != removal.markerURL },
                    failures: report.failures
                )
            )
        }
        statusMessage =
            "Removed stray marker for '\(removal.scope)' at \(removal.markerURL.path)."
        errorMessage = nil
    }
}
