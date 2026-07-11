import SharibakoCore
import SwiftUI

/// Form for adding a new secret to a scope.
///
/// Validates the key against the vault identifier grammar
/// (`VaultCore.isValidIdentifier`) and disables submit on invalid input.
/// The value field is a ``RevealableSecureField`` — masked by default, with a
/// show-while-typing eye toggle (ho-06.1 AT-03 Decision 5). Notes are
/// optional.
///
/// Hosted in its own auxiliary `Window` scene (`WindowGroup(id:for:)` keyed
/// on the scope ID), opened via `openWindow(id:value:)` (ho-06.1 AT-03
/// Decision 6) rather than a modal `.sheet` — movable, non-modal, the main
/// window stays interactive while this is open. `scopeID` is read once at
/// open time and carried as the window's own value — it does not track
/// `WorkshopModel.selectedScopeID` afterward, so a selection change in the
/// main window while this is open cannot retarget an in-progress add.
/// `dismiss()` closes the window on Cancel or successful submit; the
/// creation announce (`WorkshopModel.addSecret`) surfaces in the main
/// window's status surface, not here.
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8). All submitted work routes through `WorkshopModel.addSecret`.
struct AddSecretSheet: View {
    @Environment(WorkshopModel.self)
    private var model

    @Environment(\.dismiss)
    private var dismiss

    /// The scope to add the secret into, fixed for this window's lifetime.
    let scopeID: String

    @State private var secretKey: String = ""
    @State private var secretValue: String = ""
    @State private var notes: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        .foregroundStyle(Color.drift)
                    }
                } header: {
                    Text("Key")
                }

                Section {
                    // Masked by default (decision: same hygiene as the CLI prompt);
                    // the eye toggle lets the operator confirm what they typed
                    // before submitting (ho-06.1 AT-03 Decision 5).
                    RevealableSecureField(placeholder: "Value", text: $secretValue)
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
        // Fixed width + intrinsic height: with `.windowResizability(.contentSize)`
        // this pins the window compact (ho-06.1 gate finding).
        .frame(width: 440)
        // Esc closes the window — `.keyboardShortcut(.cancelAction)` alone is
        // not reliably routed in a plain window the way it is in a sheet.
        .onExitCommand { dismiss() }
        .background(AuxiliaryWindowChrome())
    }

    private var isValidKey: Bool {
        VaultCore.isValidIdentifier(secretKey)
    }

    private var canSubmit: Bool {
        !secretKey.isEmpty && isValidKey && !secretValue.isEmpty
    }
}
