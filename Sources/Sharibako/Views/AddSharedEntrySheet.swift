import SharibakoCore
import SwiftUI

/// Form for adding a new shared entry to `shared/`.
///
/// Validates the shared entry ID against the vault identifier grammar
/// (`VaultCore.isValidIdentifier`) and disables submit on invalid input. The
/// value field is a ``RevealableSecureField`` — masked by default, with a
/// show-while-typing eye toggle (ho-06.1 AT-03 Decision 5). Notes are
/// optional.
///
/// Note: the link *picker* (binding a scope key to this shared entry from the
/// UI) is ho-07. This form creates the shared entry; linking is a future
/// surface.
///
/// Hosted in its own auxiliary `Window` scene, opened via `openWindow`
/// (ho-06.1 AT-03 Decision 6) rather than a modal `.sheet` — movable,
/// non-modal, the main window stays interactive while this is open.
/// `dismiss()` closes the window on Cancel or successful submit; the
/// creation announce (`WorkshopModel.addSharedEntry`) surfaces in the main
/// window's status surface, not here — shared entries especially have no
/// visible home of their own until ho-07's browser.
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Shared Entry")
                .font(.headline)

            Text(
                "A shared entry lives in shared/ and can be linked from "
                    + "multiple scopes. Linking a scope key to this entry is done "
                    + "via `sharibako link` in the CLI (ho-07 will surface it here)."
            )
            .font(.callout)
            .foregroundStyle(Color.inkSecondary)

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
                        .foregroundStyle(Color.drift)
                    }
                } header: {
                    Text("Identifier")
                }

                Section {
                    // Masked by default; the eye toggle lets the operator
                    // confirm what they typed before submitting (ho-06.1
                    // AT-03 Decision 5).
                    RevealableSecureField(placeholder: "Value", text: $entryValue)
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
            // Flat pālana ground behind the form sections (ho-06.5 Decision 3).
            .scrollContentBackground(.hidden)

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
        // Fixed width + intrinsic height: with `.windowResizability(.contentSize)`
        // this pins the window compact (ho-06.1 gate finding).
        .frame(width: 440)
        // Esc closes the window — `.keyboardShortcut(.cancelAction)` alone is
        // not reliably routed in a plain window the way it is in a sheet.
        .onExitCommand { dismiss() }
        .background(Color.ground)
        .background(AuxiliaryWindowChrome())
    }

    private var isValidID: Bool {
        VaultCore.isValidIdentifier(entryID)
    }

    private var canSubmit: Bool {
        !entryID.isEmpty && isValidID && !entryValue.isEmpty
    }
}
