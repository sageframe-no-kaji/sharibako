import SwiftUI

/// Parts shared by the content column's pages (ho-06.9 AT-02, moved here by
/// ho-06.10 AT-03 when the Not-protected page went): the title block, the
/// quiet Open in Finder link, and the pane-local error.
///
/// Every string comes from `WorkshopModel` (tested); these views only lay
/// them out.
///
/// Coverage-excluded: SwiftUI declarative bodies, not headlessly drivable
/// (ho-05 Decision 8).

/// A page's title block.
///
/// The row's name, its status word beneath when `showsStatus` (the project
/// page's header says where it stands instead), and the folder's path —
/// abbreviated and middle-truncated, the full path in the tooltip — or "No
/// folder on this Mac". Shared by the project and Problem pages.
struct PageTitle: View {
    /// The row the page is for; its name and status word head the page.
    let entry: WorkshopModel.ProjectEntry
    /// The folder the row stands for, when it has one on this Mac.
    let directory: URL?
    /// Whether the row's status word shows under its name.
    var showsStatus = true

    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.name)
                .font(.title2)
                .foregroundStyle(Color.ink)
                .textSelection(.enabled)
            if showsStatus {
                Text(entry.status.label)
                    .foregroundStyle(Color.inkSecondary)
            }
            Text(model.pageLocation(for: directory))
                .font(.callout)
                .foregroundStyle(Color.inkTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(directory?.path ?? model.pageLocation(for: nil))
        }
    }
}

/// The quiet "Open in Finder" link under a status page's verbs, through the
/// shared ``WorkshopModel/openInFinder(_:)`` helper (it announces).
struct OpenInFinderLink: View {
    /// The folder to open.
    let directory: URL

    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        Button {
            model.openInFinder(directory)
        } label: {
            Label("Open in Finder", systemImage: "folder")
        }
        .buttonStyle(.link)
        .foregroundStyle(Color.inkSecondary)
        .help("Open \(directory.path) in Finder")
    }
}

/// A failure from this pane's action, rendered where the action was
/// (ho-06.10 Decision 8): the message in the rust alarm, the next step
/// beneath in `inkSecondary`.
struct PaneErrorView: View {
    /// The failure to show.
    let error: WorkshopModel.PaneError

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(error.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.drift)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let nextStep = error.nextStep {
                Text(nextStep)
                    .font(.callout)
                    .foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
