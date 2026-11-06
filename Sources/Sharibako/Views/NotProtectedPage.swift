import SwiftUI

/// The page for a Not-protected row (ho-06.9 Decision 9): a folder under the
/// scan roots with a `.env` and nothing in the vault yet.
///
/// Shows what Protect would take in — the `.env`'s keys, never a value; each
/// one is masked as `••••••••` — and offers the one verb, Protect, which opens
/// the Protect sheet (Decision 6). The preview is
/// ``WorkshopModel/candidatePreview``, loaded keyless on the worker by the
/// content column's `.task(id:)`; until it lands the page says it is reading.
/// Every count-aware string comes from `WorkshopModel+Pages.swift` (tested).
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8).
struct NotProtectedPage: View {
    /// The selected Not-protected row; its `directory` is always set.
    let entry: WorkshopModel.ProjectEntry
    /// The folder the row stands for.
    let directory: URL

    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageTitle(entry: entry, directory: directory)

                if let preview = model.candidatePreview {
                    keyList(preview)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reading .env…")
                            .foregroundStyle(Color.inkSecondary)
                    }
                }

                Button("Protect \(entry.name)") {
                    Task { await model.beginIngest(directory: directory) }
                }
                .primaryActionButton()
                .disabled(model.activity != nil)
                .help("Read this folder's .env and move its secrets into the vault")
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                OpenInFinderLink(directory: directory)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.ground)
    }

    /// The keys of the folder's `.env`, in file order, each value masked.
    ///
    /// Any lines the parser could not read follow, in the rust alarm.
    private func keyList(_ preview: WorkshopModel.CandidatePreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(WorkshopModel.envLineCount(preview.keys.count))
                .font(.headline)
                .foregroundStyle(Color.ink)
            ForEach(preview.keys, id: \.self) { key in
                HStack {
                    Text(key)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 16)
                    Text("••••••••")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color.inkTertiary)
                }
            }
            ForEach(preview.warnings, id: \.self) { warning in
                Text(warning)
                    .font(.callout)
                    .foregroundStyle(Color.drift)
            }
        }
    }
}

// MARK: - Shared page parts

/// A status page's title block.
///
/// The row's name, its status word beneath, and the folder's path —
/// abbreviated and middle-truncated, the full path in the tooltip. Shared by
/// the Not-protected and Problem pages.
struct PageTitle: View {
    /// The row the page is for; its name and status word head the page.
    let entry: WorkshopModel.ProjectEntry
    /// The folder the row stands for.
    let directory: URL

    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.name)
                .font(.title2)
                .foregroundStyle(Color.ink)
                .textSelection(.enabled)
            Text(entry.status.label)
                .foregroundStyle(Color.inkSecondary)
            Text(model.abbreviatedPath(directory))
                .font(.callout)
                .foregroundStyle(Color.inkTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(directory.path)
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
