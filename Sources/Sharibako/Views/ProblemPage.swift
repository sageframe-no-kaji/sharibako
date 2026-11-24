import SwiftUI

/// The page for a Needs-attention row (ho-06.9 Decision 9): a folder whose
/// claim file names a project the vault does not have, or a claim file that
/// cannot be read.
///
/// The claim file names a missing project: the page explains it in plain
/// words (verbatim from the ho drawing) and offers the two verbs that resolve
/// it — Protect this folder (recreates the project through the Protect sheet)
/// and Forget this folder (removes only the claim file, after the window's
/// confirmation) — plus Open in Finder. The claim file is unreadable: the page
/// names the file and the reason, and offers Open in Finder only, since
/// neither verb can act on a file that will not load. The verbs mirror the
/// action column (AT-03). All copy comes from `WorkshopModel+Pages.swift`
/// (tested).
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8).
struct ProblemPage: View {
    /// The selected Needs-attention row.
    let entry: WorkshopModel.ProjectEntry
    /// The claim file the row stands for — the `.problem` status's payload.
    let marker: WorkshopModel.UnlinkedMarker
    /// The folder holding the claim file.
    let directory: URL

    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageTitle(entry: entry, directory: directory)
                switch marker {
                case .orphaned(let scope, _):
                    orphanedBody(projectName: scope)
                case .failed(_, let reason):
                    failedBody(reason: reason)
                }
                OpenInFinderLink(directory: directory)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.ground)
    }

    /// The claim file names a project the vault does not have: the
    /// explanation and the two verbs.
    @ViewBuilder
    private func orphanedBody(projectName: String) -> some View {
        ForEach(WorkshopModel.problemExplanation(projectName: projectName), id: \.self) { paragraph in
            Text(paragraph)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 12) {
            Button("Protect this folder") {
                Task { await model.createScopeFromMarker(marker) }
            }
            .primaryActionButton()
            .help("Bring this folder's .env into the vault as \(projectName)")

            // The rust alarm marks the destructive verb, the panel's
            // Delete-project precedent; its confirmation is system-rendered.
            Button("Forget this folder") {
                model.requestRemoveStrayMarker(marker)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.drift)
            .help("Remove this folder's claim file — the vault and the .env are untouched")
        }
        .disabled(model.activity != nil)
        .padding(.top, 8)
    }

    /// The claim file will not load: what Sharibako could not read, and why.
    @ViewBuilder
    private func failedBody(reason: String) -> some View {
        Text(WorkshopModel.unreadableClaimLead)
            .foregroundStyle(Color.ink)
        Text(reason)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(Color.inkSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
