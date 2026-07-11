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
                            Label(scope.displayName ?? scope.identity, systemImage: "shippingbox")
                                .tag(scope.identity)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            footer
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
        return lines.joined(separator: "\n")
    }
}
