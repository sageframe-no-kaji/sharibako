import SharibakoCore
import SwiftUI

/// Sheet for adding a new secret to the selected scope.
///
/// Validates the key against the vault identifier grammar
/// (`VaultCore.isValidIdentifier`) and disables submit on invalid input.
/// The value field is a `SecureField` so the plaintext never echoes on screen.
/// Notes are optional.
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8). All submitted work routes through `WorkshopModel.addSecret`.
struct AddSecretSheet: View {
    @Environment(WorkshopModel.self)
    private var model

    @Environment(\.dismiss)
    private var dismiss

    /// The scope to add the secret into.
    let scopeID: String

    @State private var secretKey: String = ""
    @State private var secretValue: String = ""
    @State private var notes: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Secret")
                .font(.headline)

            Form {
                Section {
                    TextField("Key (e.g. DATABASE_URL)", text: $secretKey)
                        .font(.system(.body, design: .monospaced))
                    if !secretKey.isEmpty, !isValidKey {
                        Text(
                            "Key must match ^[A-Za-z0-9_][A-Za-z0-9._-]*$ — "
                                + "no spaces, no leading dots or dashes."
                        )
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                } header: {
                    Text("Key")
                }

                Section {
                    // SecureField so the value never echoes (decision: same hygiene as the CLI prompt).
                    SecureField("Value", text: $secretValue)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Value")
                }

                Section {
                    TextField(
                        "Notes (optional)",
                        text: $notes,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                } header: {
                    Text("Notes")
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Secret") {
                    model.addSecret(
                        key: secretKey,
                        value: secretValue,
                        notes: notes.isEmpty ? nil : notes,
                        inScope: scopeID
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 340)
    }

    private var isValidKey: Bool {
        VaultCore.isValidIdentifier(secretKey)
    }

    private var canSubmit: Bool {
        !secretKey.isEmpty && isValidKey && !secretValue.isEmpty
    }
}
