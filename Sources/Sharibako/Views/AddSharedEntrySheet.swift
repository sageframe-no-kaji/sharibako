import SharibakoCore
import SwiftUI

/// Sheet for adding a new shared entry to `shared/`.
///
/// Validates the shared entry ID against the vault identifier grammar
/// (`VaultCore.isValidIdentifier`) and disables submit on invalid input.
/// The value field is a `SecureField`. Notes are optional.
///
/// Note: the link *picker* (binding a scope key to this shared entry from the
/// UI) is ho-07. This sheet creates the shared entry; linking is a future
/// surface (Decision 5).
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8). All submitted work routes through
/// `WorkshopModel.addSharedEntry`.
struct AddSharedEntrySheet: View {
    @Environment(WorkshopModel.self)
    private var model

    @Environment(\.dismiss)
    private var dismiss

    @State private var entryID: String = ""
    @State private var entryValue: String = ""
    @State private var notes: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Shared Entry")
                .font(.headline)

            Text(
                "A shared entry lives in shared/ and can be linked from "
                    + "multiple scopes. Linking a scope key to this entry is done "
                    + "via `sharibako link` in the CLI (ho-07 will surface it here)."
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            Form {
                Section {
                    TextField("ID (e.g. openai-personal)", text: $entryID)
                        .font(.system(.body, design: .monospaced))
                    if !entryID.isEmpty, !isValidID {
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
                    SecureField("Value", text: $entryValue)
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
                Button("Add Shared Entry") {
                    model.addSharedEntry(
                        id: entryID,
                        value: entryValue,
                        notes: notes.isEmpty ? nil : notes
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding()
        .frame(minWidth: 440, minHeight: 380)
    }

    private var isValidID: Bool {
        VaultCore.isValidIdentifier(entryID)
    }

    private var canSubmit: Bool {
        !entryID.isEmpty && isValidID && !entryValue.isEmpty
    }
}
