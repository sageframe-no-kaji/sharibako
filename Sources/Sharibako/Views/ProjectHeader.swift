import SwiftUI

/// The strip above a project's secret list (ho-06.9 Decision 9): where the
/// project stands and where its folder is, so the status is visible without
/// opening anything.
///
/// One line carries the status glyph, the status word, and — for an Out-of-date
/// project — how many lines differ; the line beneath names the folder,
/// abbreviated against home, or "No folder on this Mac". The status word comes
/// from ``WorkshopModel/ProjectStatus/label`` and every other string from
/// `WorkshopModel+Pages.swift` (tested); this view only lays them out.
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8).
struct ProjectHeader: View {
    /// The selected project's row.
    let entry: WorkshopModel.ProjectEntry

    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: entry.status.symbolName)
                        .foregroundStyle(entry.status.glyphPalette.color)
                    Text(entry.status.label)
                        .font(.headline)
                        .foregroundStyle(Color.ink)
                    if let drift = WorkshopModel.headerDriftClause(for: entry.status) {
                        Text("· \(drift)")
                            .font(.headline)
                            .foregroundStyle(Color.drift)
                    }
                }
                .help(entry.status.helpText)
                if let location = model.headerLocation(for: entry) {
                    Text(location)
                        .font(.callout)
                        .foregroundStyle(Color.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(entry.directory?.path ?? location)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
        .background(Color.ground)
    }
}
