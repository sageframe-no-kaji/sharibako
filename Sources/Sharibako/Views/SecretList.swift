import SharibakoCore
import SwiftUI

/// Center column of the Workshop: lists the selected scope's secrets.
///
/// Each row shows the secret key plus a glyph distinguishing a direct
/// `.value` (padlock) from a `.link` (link symbol). Selecting a row sets
/// `model.selectedSecretKey` and triggers history loading in the parent.
/// Shows an empty-state prompt when no scope is selected.
///
/// Read-only in AT-02 — no add/edit/rotate buttons (those are AT-03).
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8).
struct SecretList: View {
    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        Group {
            if let scopeID = model.selectedScopeID {
                secretList(for: scopeID)
            } else {
                ContentUnavailableView(
                    "No Scope Selected",
                    systemImage: "lock.rectangle.stack",
                    description: Text("Pick a scope from the sidebar to view its secrets.")
                )
            }
        }
        .background(Color.ground)
        .navigationTitle(model.selectedScopeID ?? "Secrets")
    }

    @ViewBuilder
    private func secretList(for scopeID: String) -> some View {
        if model.secrets.isEmpty {
            ContentUnavailableView(
                "No Secrets",
                systemImage: "lock.slash",
                description: Text("This scope has no secrets yet.")
            )
        } else {
            List(model.secrets, id: \.key, selection: selectionBinding(scopeID: scopeID)) { info in
                SecretRow(info: info)
            }
            // Flat pālana ground (ho-06.5 Decision 3) — the Group backdrop
            // below carries the paper; the list stops painting over it.
            .scrollContentBackground(.hidden)
        }
    }

    /// A `Binding<String?>` that syncs the list selection to the model and
    /// triggers history loading when a new secret is selected.
    private func selectionBinding(scopeID: String) -> Binding<String?> {
        Binding(
            get: { model.selectedSecretKey },
            set: { [self] newKey in
                model.selectedSecretKey = newKey
                guard let key = newKey,
                    let info = model.secrets.first(where: { $0.key == key })
                else { return }
                model.loadHistory(for: key, inScope: scopeID, kind: info.kind)
            }
        )
    }
}

/// A single row in the secret list.
private struct SecretRow: View {
    let info: SecretInfo

    var body: some View {
        Label {
            Text(info.key)
                .font(.system(.body, design: .monospaced))
        } icon: {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
        }
    }

    private var iconName: String {
        switch info.kind {
        case .value:
            return "lock.fill"
        case .link:
            return "link"
        }
    }

    private var iconColor: Color {
        switch info.kind {
        case .value:
            return .inkSecondary
        case .link:
            return .accentMoss
        }
    }
}
