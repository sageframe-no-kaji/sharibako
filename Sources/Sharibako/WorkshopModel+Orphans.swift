import Foundation
import SharibakoCore

/// Orphan-remediation intents for the "Needs attention" section's
/// `.orphaned` rows (ho-06.3 Decision 7, AT-03) — the two verbs that turn
/// surfacing into action once ho-06.2 stopped at naming the marker.
///
/// **Protect this folder** (``createScopeFromMarker(_:)``) protects the
/// folder under the project its claim file names (ho-06.10 AT-02): the claim
/// file already carries the scope ID the vault forgot, so the folder's lines
/// are read and its recommended lines committed under that ID with no
/// prompt — recreating the project under its own name is what heals the
/// link.
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
    // MARK: - Protect this folder as its claimed project (Required Change 1)

    /// Protects an orphaned marker's folder as the project its claim file
    /// names (ho-06.10 AT-02 Required Change 6).
    ///
    /// Selects the Problem row, reads its folder's lines
    /// (``loadContent(for:)``), then commits them with
    /// ``protectRecommended(scopeID:)`` under `marker`'s own scope ID:
    /// `acceptIngest` creates the scope and rewrites the claim file, so the
    /// row moves from Needs attention to Projects. A no-op for `.failed`
    /// markers — scan-failure rows stay surfacing-only (Do Not §3).
    func createScopeFromMarker(_ marker: UnlinkedMarker) async {
        guard case .orphaned(let scope, let markerURL) = marker else { return }
        let problem = Selection.problem(markerPath: markerURL.path)
        selection = problem
        await loadContent(for: problem)
        await protectRecommended(scopeID: scope)
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

    /// Deletes the staged marker file, drops it from the cached scan report so
    /// the row leaves "Needs attention" immediately, then re-runs the scan
    /// quietly (ho-06.9 Decision 3).
    ///
    /// Touches only ``StrayMarkerRemoval/markerURL`` — no git, no vault
    /// write, the vault and the project's `.env` are both untouched (the
    /// inverted blast radius, Required Change 2). The local filter is what
    /// makes the row leave at once; the quiet rescan exists because Forget
    /// *adds* a row too: with its claim file gone, a folder that still holds
    /// a `.env` is a Not-protected candidate again, and only the candidate
    /// walk can say so. The rescan announces nothing of its own — the
    /// removal's line stands — and is skipped with no scan roots or while
    /// another activity runs. Failure of the removal — the file is already
    /// gone, or permissions refuse it — announces via
    /// ``WorkshopModel/errorMessage`` and leaves every other field
    /// untouched, matching the ho-06.7 trio's own failure posture.
    /// `removal` is passed in by the confirmation button, read synchronously
    /// at the tap: SwiftUI dismisses a `confirmationDialog` through its
    /// `isPresented` binding *before* the button's `Task` body runs, and that
    /// dismissal clears ``pendingStrayMarkerRemoval`` — so a body that read
    /// the pending value itself found `nil` and silently did nothing (the
    /// ho-06.9 gate: "Forget this folder didn't remove it"). Falls back to
    /// the pending value for callers that are not racing a dialog.
    func confirmRemoveStrayMarker(_ removal: StrayMarkerRemoval? = nil) async {
        guard let removal = removal ?? pendingStrayMarkerRemoval else { return }
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
        await rescanQuietlyAfterForget()
    }

    /// The quiet half of Forget: one marker-and-candidate scan through the
    /// shared hop, no status line, failures to ``WorkshopModel/errorMessage``.
    private func rescanQuietlyAfterForget() async {
        guard activity == nil, !scanRoots.isEmpty else { return }
        guard case .open(let vaultURL) = vaultState else { return }
        activity = .scanning
        defer { activity = nil }
        do {
            _ = try await scanMarkersAndCandidates(vaultURL: vaultURL, roots: scanRoots)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }
}
