import SwiftUI

/// The Workshop's main window: a three-pane `NavigationSplitView` shell, or
/// the "no vault" empty state when the resolved path holds none (Decision 3).
///
/// The center and detail columns are placeholders in AT-01; AT-02 fills them
/// with the secret list and the detail pane.
struct WorkshopWindow: View {
    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        switch model.vaultState {
        case .noVault(let expectedPath):
            ContentUnavailableView {
                Label("No vault found", systemImage: "shippingbox")
            } description: {
                Text(
                    "Sharibako looked for a vault at \(expectedPath.path) "
                        + "and found none. Create one with `sharibako key generate` "
                        + "or point SHARIBAKO_VAULT at an existing vault."
                )
                .textSelection(.enabled)
            }
        case .open:
            NavigationSplitView {
                ScopeSidebar()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 240)
            } content: {
                SecretList()
                    .onAppear {
                        if let scopeID = model.selectedScopeID {
                            model.loadSecrets(for: scopeID)
                        }
                    }
                    .onChange(of: model.selectedScopeID) { _, newScopeID in
                        if let scopeID = newScopeID {
                            model.loadSecrets(for: scopeID)
                        }
                    }
            } detail: {
                SecretDetail()
            }
            .safeAreaInset(edge: .bottom) {
                if let message = model.errorMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.bar)
                }
            }
        }
    }
}
