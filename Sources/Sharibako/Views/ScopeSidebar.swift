import SharibakoCore
import SwiftUI

/// The left column: every scope in the vault, sectioned by `ScopeType`, with a
/// fixed footer naming the vault and its git remote (ho-06.1 AT-02 Waymarking
/// Decision 3 — the gate's "which repo am I on" finding).
///
/// Pure rendering — grouping/ordering and the footer's text both live in
/// `WorkshopModel` (Decision 8 keeps branching logic out of `View` structs).
/// Selection binds to the model's `selectedScopeID`; AT-02's secret list
/// reads it.
struct ScopeSidebar: View {
    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            List(selection: $model.selectedScopeID) {
                ForEach(model.scopeSections) { section in
                    Section(section.title) {
                        ForEach(section.scopes, id: \.identity) { scope in
                            scopeRow(for: scope)
                                .tag(scope.identity)
                        }
                    }
                }
                unlinkedSection
            }
            .listStyle(.sidebar)

            footer
        }
    }

    // MARK: - Scope row

    /// One scope row: a state glyph leading the name, then a trailing slot.
    ///
    /// The glyph (``WorkshopModel/glyphState(forScope:)``, Decision 2a) leads
    /// the name; the trailing slot is where AT-02 fills the drift badge. The
    /// glyph's shape carries the state (colorblind-safe); the symbol name and
    /// tooltip text both come from the model (Decision 8 keeps the branching
    /// out of the view).
    @ViewBuilder
    private func scopeRow(for scope: ScopeMetadata) -> some View {
        let state = model.glyphState(forScope: scope.identity)
        HStack(spacing: 6) {
            Image(systemName: state.symbolName)
                .foregroundStyle(.secondary)
                .help(state.helpText)
            Text(scope.displayName ?? scope.identity)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            // Drift badge (AT-02): rendered only after a Check-drift has run for
            // this scope; before that the slot is empty and the row shows only
            // its glyph (Decision 3 — no ambient badge, no launch-time Touch ID).
            if let badge = model.driftBadge(forScope: scope.identity) {
                Image(systemName: badge.symbolName)
                    .foregroundStyle(.secondary)
                    .help(badge.helpText)
            }
        }
    }

    // MARK: - Unlinked markers

    /// The "Unlinked markers" section, from ``WorkshopModel/unlinkedMarkers``.
    ///
    /// Orphaned markers (a `.sharibako` pointing at a vault scope that doesn't
    /// exist) and malformed-marker scan failures (ho-04.11, Decision 2b).
    /// Omitted entirely when there are none. Surfacing only — the rows
    /// show the marker path (inline and in the tooltip); no remediation
    /// actions, and no `.tag`, so selecting one never drives the scope-detail
    /// panes with a non-scope id (remediation is ho-06.3).
    @ViewBuilder private var unlinkedSection: some View {
        let unlinked = model.unlinkedMarkers
        if !unlinked.isEmpty {
            Section("Unlinked markers") {
                ForEach(unlinked) { marker in
                    HStack(spacing: 6) {
                        Image(systemName: marker.symbolName)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(marker.title)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(marker.markerPath)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .help(marker.helpText)
                }
            }
        }
    }

    // MARK: - Footer

    /// The vault + remote indicator.
    ///
    /// Omitted entirely in `.noVault` — the footer names the vault the
    /// sidebar is listing scopes from, and there is nothing to name when no
    /// vault is open.
    @ViewBuilder private var footer: some View {
        if let vaultShort = model.vaultDirectoryShortDescription {
            VStack(alignment: .leading, spacing: 3) {
                Divider()
                // .callout, not .caption — the ho-06.1 gate found the footer
                // unreadably small at .caption (10 pt).
                Label(vaultShort, systemImage: "shippingbox.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let remoteShort = model.remoteShortDescription {
                    Label(remoteShort, systemImage: "arrow.triangle.branch")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // Scan-root visibility (ho-06.2 AT-03 Decision 5): the missing
                // half of "where is it scanning" — read-only, all configured
                // roots, full paths in the tooltip.
                Label(model.scanRootsShortDescription, systemImage: "magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // 16 pt insets keep the footer clear of the window's rounded
            // bottom-left corner and on the sidebar's own content line
            // (ho-06.1 gate finding: content tucked into the "mac
            // super-corners" reads cramped).
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .help(footerTooltip)
        }
    }

    /// Full, non-abbreviated paths for the footer's tooltip — the short form
    /// in the row is for scanning, the tooltip is for verifying.
    private var footerTooltip: String {
        var lines: [String] = []
        if let vaultFull = model.vaultDirectoryFullDescription {
            lines.append("Vault: \(vaultFull)")
        }
        if let remoteFull = model.remoteFullDescription {
            lines.append("Remote: \(remoteFull)")
        }
        if let scanRootsFull = model.scanRootsFullDescription {
            lines.append("Scan roots: \(scanRootsFull)")
        }
        return lines.joined(separator: "\n")
    }
}
