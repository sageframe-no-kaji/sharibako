import Foundation
import SharibakoCore

/// Unlinked-marker reads for the sidebar (ho-06.2 AT-01, Decision 2b).
///
/// Every value here is computed from state `WorkshopModel.swift` already owns —
/// the in-memory scan cache (``WorkshopModel/scanReport``) intersected with the
/// loaded ``WorkshopModel/scopes``. Nothing here re-walks the tree
/// (`Materializer.status` does, and is the exact cost the ho-06.1 scan cache
/// exists to kill), decrypts, or touches an age key.
///
/// ho-06.9 folded this file's per-scope glyph (`GlyphState`) into
/// ``WorkshopModel/ProjectStatus`` (`WorkshopModel+Projects.swift`); what
/// stays is ``UnlinkedMarker`` — the payload of the Problem status — and its
/// derivation, which the "Needs attention" section reads.
///
/// Kept in its own file matching the `Conduit`/`Conduit+Remote.swift` split
/// precedent so `WorkshopModel.swift` stays under SwiftLint's `file_length`
/// ceiling.
extension WorkshopModel {
    /// One row in the sidebar's "Unlinked markers" section (Decision 2b).
    ///
    /// Surfacing only — a marker the vault can't place, or a `.sharibako` that
    /// failed to load during the scan. Remediation (create-scope, remove-marker)
    /// is ingest-adjacent and belongs to ho-06.3.
    enum UnlinkedMarker: Equatable, Identifiable {
        /// A marker referencing a vault scope that doesn't exist; carries the
        /// referenced scope name and the marker's on-disk path.
        case orphaned(scope: String, markerURL: URL)
        /// A `.sharibako` that failed to load during the scan (ho-04.11);
        /// carries the marker's path and the load-failure reason.
        case failed(markerURL: URL, reason: String)

        /// Stable identity for SwiftUI lists — the marker path plus a
        /// discriminator, so an orphan and a failure at the same path (they
        /// cannot both occur, but the id space stays disjoint) never collide.
        var id: String {
            switch self {
            case .orphaned(_, let markerURL): return "orphaned:\(markerURL.path)"
            case .failed(let markerURL, _): return "failed:\(markerURL.path)"
            }
        }

        /// The row's primary label: the orphaned scope name, or a fixed
        /// "Malformed marker" for a load failure.
        var title: String {
            switch self {
            case .orphaned(let scope, _): return scope
            case .failed: return "Malformed marker"
            }
        }

        /// The marker's on-disk path, shown inline and in the tooltip so the
        /// orphan is fully surfaced without any action (Decision 2b).
        var markerPath: String {
            switch self {
            case .orphaned(_, let markerURL): return markerURL.path
            case .failed(let markerURL, _): return markerURL.path
            }
        }

        /// SF Symbol for the row's leading glyph — shape-distinct from the two
        /// scope-row glyphs.
        var symbolName: String {
            switch self {
            case .orphaned: return "questionmark.circle"
            case .failed: return "exclamationmark.triangle"
            }
        }

        /// The row's help tooltip: the marker path, plus the failure reason for
        /// a load failure.
        var helpText: String {
            switch self {
            case .orphaned(let scope, let markerURL):
                return "Marker references scope '\(scope)', which the vault does not have\n\(markerURL.path)"
            case .failed(let markerURL, let reason):
                return "\(markerURL.path)\n\(reason)"
            }
        }
    }

    /// The "Unlinked markers" section contents, derived from the scan cache
    /// (Decision 2b).
    ///
    /// Orphans: cached markers whose `scope` is absent from ``scopes`` — a
    /// marker pointing at a vault scope that doesn't exist. Failures:
    /// ``ScanReport/failures`` (malformed markers, ho-04.11). Empty when the
    /// cache is cold or holds neither. Reads only ``scanReport`` and
    /// ``scopes`` — no re-derivation in the view.
    var unlinkedMarkers: [UnlinkedMarker] {
        guard let scanReport else { return [] }
        let vaultScopeIDs = Set(scopes.map(\.identity))
        let orphans = scanReport.markers
            .filter { !vaultScopeIDs.contains($0.scope) }
            .map { UnlinkedMarker.orphaned(scope: $0.scope, markerURL: $0.markerURL) }
        let failures = scanReport.failures
            .map { UnlinkedMarker.failed(markerURL: $0.markerURL, reason: $0.reason) }
        return orphans + failures
    }
}
