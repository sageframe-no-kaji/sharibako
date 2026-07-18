import AppKit
import SwiftUI

/// The ingest candidate chooser (ho-06.3 gate-fix round).
///
/// Lists every `.env`-bearing project under the scan roots not yet in the
/// vault as a click-to-import list. Presented by the panel's **Ingest
/// Project…** verb, by the first-run wizard's finish hand-off when several
/// candidates exist, and again after each chooser-initiated import while
/// candidates remain (``WorkshopModel/IngestSession/chainOnCommit``).
///
/// All branching logic lives in `WorkshopModel+Ingest.swift` (tested): this
/// view reads `model.ingest.candidates` and calls the chooser intents — the
/// `IngestSheet` posture. The Choose Other… fallback keeps the original
/// hand-picked path for a project outside the scan roots.
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8) — see `.github/workflows/ci.yml`'s `EXCLUDED` regex.
struct IngestChooserSheet: View {
    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        if let candidates = model.ingest.candidates {
            content(for: candidates)
        }
    }

    @ViewBuilder
    private func content(for candidates: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(candidates)
            Divider()
            if candidates.isEmpty {
                emptyState
            } else {
                candidateList(candidates)
            }
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(Color.ground)
    }

    // MARK: - Header

    private func header(_ candidates: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import Projects")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.ink)
            Text(
                candidates.isEmpty
                    ? "Projects with a .env file, not yet in the vault"
                    : "\(candidates.count) project(s) with a .env file, not yet in the vault"
            )
            .font(.caption)
            .foregroundStyle(Color.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    // MARK: - Candidate list

    private func candidateList(_ candidates: [URL]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(candidates, id: \.path) { candidate in
                    candidateRow(candidate)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func candidateRow(_ candidate: URL) -> some View {
        Button {
            Task { await model.selectIngestCandidate(candidate) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .foregroundStyle(Color.inkSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.lastPathComponent)
                        .foregroundStyle(Color.ink)
                    Text(abbreviatedPath(candidate))
                        .font(.caption)
                        .foregroundStyle(Color.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text("Import")
                    .font(.caption)
                    .foregroundStyle(Color.accentMoss)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No new projects found")
                .font(.headline)
                .foregroundStyle(Color.inkSecondary)
            Text("Every .env-bearing project under your scan roots is already in the vault.")
                .font(.caption)
                .foregroundStyle(Color.inkTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Choose Other…") {
                chooseOther()
            }
            Spacer()
            Button("Done") {
                model.dismissIngestChooser()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    /// The hand-picked fallback for a project outside the scan roots — the
    /// panel verb's original picker, now living behind the chooser.
    ///
    /// Cancelling the picker keeps the chooser open.
    private func chooseOther() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project directory to scan for .env secrets"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.selectIngestCandidate(url) }
    }

    /// Home-relative display path (`~/Projects/bento`), mirroring the
    /// sidebar footer's abbreviation against the model's injected home.
    private func abbreviatedPath(_ url: URL) -> String {
        let path = url.path
        let home = model.home.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
