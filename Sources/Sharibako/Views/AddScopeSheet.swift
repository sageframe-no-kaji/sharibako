import SharibakoCore
import SwiftUI

/// Form for creating a new scope in the Workshop.
///
/// Validates the scope ID against the vault identifier grammar
/// (`VaultCore.isValidIdentifier`) and disables submit on invalid input —
/// the same validation the CLI enforces at the path-building chokepoint.
/// A display name is optional.
///
/// Hosted in its own auxiliary `Window` scene, opened via `openWindow`
/// (ho-06.1 AT-03 Decision 6) rather than a modal `.sheet` — movable,
/// non-modal, the main window stays interactive while this is open.
/// `dismiss()` closes the window on Cancel or successful submit; the
/// creation announce (`WorkshopModel.addScope`) surfaces in the main
/// window's status surface, not here.
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8). All submitted work routes through `WorkshopModel.addScope`.
struct AddScopeSheet: View {
    @Environment(WorkshopModel.self)
    private var model

    @Environment(\.dismiss)
    private var dismiss

    @State private var scopeID: String = ""
    @State private var displayName: String = ""
    @State private var scopeType: ScopeType = .projectDev

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Scope")
                .font(.headline)

            Form {
                Section {
                    TextField("Scope ID (e.g. my-project)", text: $scopeID)
                        .font(.system(.body, design: .monospaced))
                    if !scopeID.isEmpty, !isValidID {
                        Text(
                            "ID must match ^[A-Za-z0-9_][A-Za-z0-9._-]*$ — "
                                + "no spaces, no leading dots or dashes."
                        )
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                } header: {
                    Text("Identifier")
                }

                Section {
                    TextField("Display name (optional)", text: $displayName)
                } header: {
                    Text("Display name")
                }

                Section {
                    Picker("Type", selection: $scopeType) {
                        Text("Project — dev").tag(ScopeType.projectDev)
                        Text("Project — prod").tag(ScopeType.projectProd)
                        Text("Service").tag(ScopeType.service)
                        Text("Machine").tag(ScopeType.machine)
                        Text("Other").tag(ScopeType.other)
                    }
                } header: {
                    Text("Category")
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Scope") {
                    model.addScope(
                        id: scopeID,
                        type: scopeType,
                        displayName: displayName.isEmpty ? nil : displayName
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
    }

    private var isValidID: Bool {
        VaultCore.isValidIdentifier(scopeID)
    }

    private var canSubmit: Bool {
        !scopeID.isEmpty && isValidID
    }
}
