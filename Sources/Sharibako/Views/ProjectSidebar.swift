import SharibakoCore
import SwiftUI

/// The left column: the user's projects in four sections by status — Not
/// protected, Projects, Needs attention, Shared secrets — with a fixed footer
/// naming the vault, its git remote, and the scan roots (ho-06.9 Decisions
/// 2 and 8; the footer is ho-06.1 AT-02 Waymarking Decision 3, unchanged).
///
/// Replaces ho-06.2's `ScopeSidebar`, which grouped vault scopes by
/// `ScopeType` and kept unlinked markers in a separate, unselectable section
/// with verbs inside the rows. Here every row is selectable and tagged with
/// its ``WorkshopModel/Selection``, so the content column shows each row's
/// page; no verb lives in a row — they moved to the pages and the action
/// column.
///
/// Pure rendering: sections, order, names, glyphs, tooltips, and tints all
/// come from `WorkshopModel` (`WorkshopModel+Projects.swift`,
/// `WorkshopModel+Pages.swift`, `Color+Theme.swift`), tested there.
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8).
struct ProjectSidebar: View {
    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if model.projectSections.isEmpty {
                // One empty state for an entirely empty window (Decision 2):
                // nothing in the vault and nothing found to protect.
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "folder",
                    description: Text("Rescan to find projects, or use New… to add one.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.projectSections) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                row(for: entry)
                                    .tag(entry.id)
                            }
                        } header: {
                            sectionHeader(section)
                        }
                    }
                }
                .listStyle(.sidebar)
                // Flat pālana ground (ho-06.5 Decision 3): hide the sidebar's
                // vibrancy so the warm paper shows through — the whole window
                // sits on flat token grounds now.
                .scrollContentBackground(.hidden)
            }

            footer
        }
        .background(Color.ground)
    }

    // MARK: - Section header

    /// The section's title with its row count trailing in `inkTertiary` —
    /// "NOT PROTECTED (3)" in the drawing.
    private func sectionHeader(_ section: WorkshopModel.ProjectSection) -> some View {
        HStack {
            Text(section.title)
            Spacer(minLength: 4)
            Text("\(section.entries.count)")
                .foregroundStyle(Color.inkTertiary)
                .monospacedDigit()
        }
    }

    // MARK: - Row

    /// One row: the status glyph and the name.
    ///
    /// The glyph is shape plus palette token (Decision 8); shared rows wear
    /// `link` and never their placeholder status.
    private func row(for entry: WorkshopModel.ProjectEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: entry.glyphSymbolName)
                .foregroundStyle(entry.glyphPalette.color)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
        }
        .help(entry.glyphHelp)
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
                    .foregroundStyle(Color.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let remoteShort = model.remoteShortDescription {
                    Label(remoteShort, systemImage: "arrow.triangle.branch")
                        .font(.callout)
                        .foregroundStyle(Color.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // Scan-root visibility (ho-06.2 AT-03 Decision 5): the missing
                // half of "where is it scanning" — read-only, all configured
                // roots, full paths in the tooltip.
                Label(model.scanRootsShortDescription, systemImage: "magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(Color.inkTertiary)
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
            // Flat groundDeep, not the .bar material (ho-06.5 Decision 3).
            .background(Color.groundDeep)
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
