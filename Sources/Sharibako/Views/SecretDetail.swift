import SharibakoCore
import SwiftUI

/// Detail column of the Workshop: shows a selected secret's value (masked or
/// revealed), notes, link target, and rotation history.
///
/// **Reveal idiom (Decision 4):** value renders as `••••••••` until the user
/// taps Reveal, which calls `model.reveal(key:inScope:)` (the file-key dev path
/// in tests, the Keychain in the signed app). The plaintext stays visible while
/// this secret is selected; changing selection re-masks via the model's
/// `selectedSecretKey` setter.
///
/// Read-only in AT-02 — no edit, rotate, or notes-edit controls (AT-03).
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8).
struct SecretDetail: View {
    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        Group {
            if let sel = resolvedSelection() {
                detailContent(key: sel.key, scopeID: sel.scopeID, info: sel.info)
            } else {
                ContentUnavailableView(
                    "No Secret Selected",
                    systemImage: "lock",
                    description: Text("Select a secret to view its details.")
                )
            }
        }
    }

    /// Resolved selection for the detail pane: all three pieces together or nil.
    private struct DetailSelection {
        let key: String
        let scopeID: String
        let info: SecretInfo
    }

    /// Returns the resolved selection when all three pieces of state are present, nil otherwise.
    private func resolvedSelection() -> DetailSelection? {
        guard let key = model.selectedSecretKey,
            let scopeID = model.selectedScopeID,
            let info = model.secrets.first(where: { $0.key == key })
        else { return nil }
        return DetailSelection(key: key, scopeID: scopeID, info: info)
    }

    @ViewBuilder
    private func detailContent(key: String, scopeID: String, info: SecretInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Key heading
                Text(key)
                    .font(.title2.monospaced())
                    .textSelection(.enabled)

                Divider()

                // Value section
                valueSection(key: key, scopeID: scopeID)

                // Link target (only for .link kind)
                if case .link(let sharedID) = info.kind {
                    linkSection(sharedID: sharedID)
                }

                Divider()

                // History section
                historySection()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(key)
    }

    // MARK: - Value section

    @ViewBuilder
    private func valueSection(key: String, scopeID: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Value", systemImage: "lock.rectangle")
                .font(.headline)
                .foregroundStyle(.secondary)

            if let revealed = model.revealedValue {
                HStack(alignment: .top, spacing: 8) {
                    Text(revealed)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        model.maskValue()
                    } label: {
                        Label("Hide", systemImage: "eye.slash")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Hide the revealed value")

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(revealed, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy to clipboard")
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                HStack(spacing: 8) {
                    Text("••••••••")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Reveal") {
                        model.reveal(key: key, inScope: scopeID)
                    }
                    .buttonStyle(.bordered)
                    .help("Reveal the secret value using Touch ID or the dev age key")
                }
                .padding(10)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Link target section

    @ViewBuilder
    private func linkSection(sharedID: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Linked to shared entry", systemImage: "link")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(sharedID)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - History section

    @ViewBuilder
    private func historySection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Rotation History", systemImage: "clock.arrow.circlepath")
                .font(.headline)
                .foregroundStyle(.secondary)

            if model.history.isEmpty {
                Text("No history — file is untracked or the vault has no git repository.")
                    .foregroundStyle(.tertiary)
                    .font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.history, id: \.shortSHA) { entry in
                        HistoryRow(entry: entry)
                    }
                }
            }
        }
    }
}

/// One row in the rotation history list.
private struct HistoryRow: View {
    let entry: CommitInfo

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.shortSHA)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            Text(entry.date)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(entry.subject)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .textSelection(.enabled)
    }
}
