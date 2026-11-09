import SwiftUI

/// The Remote… sheet (ho-06.10 Decision 8, AT-04): the vault's current git
/// remote, a field to set or change it, and Remove.
///
/// Presented while `model.remoteSheet` is non-nil. Save routes through
/// ``WorkshopModel/saveRemote()`` — the first-run wizard's validation, a
/// refusal shown under the field with the sheet left open; Remove through
/// ``WorkshopModel/removeRemote()``. Both close the sheet on success and the
/// sidebar footer reflects the change. Every word and rule is a
/// `WorkshopModel` read (`WorkshopModel+VaultSettings.swift`, tested).
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8) — same justification as `EnvPreviewSheet`.
struct RemoteSheet: View {
    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Remote")
                    .font(.headline)
                Text("Sync backs the vault up to this git remote.")
                    .font(.callout)
                    .foregroundStyle(Color.inkSecondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Now")
                    .font(.caption)
                    .foregroundStyle(Color.inkTertiary)
                Text(model.remoteSheetCurrent)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color.ink)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("git@github.com:you/vault.git", text: draftBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { model.saveRemote() }
                if let error = model.remoteSheet?.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(Color.drift)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Button("Remove", role: .destructive) {
                    model.removeRemote()
                }
                .foregroundStyle(model.canRemoveRemote ? Color.drift : Color.inkTertiary)
                .disabled(!model.canRemoveRemote)
                .help("Stop backing the vault up to a remote — Sync keeps history on this Mac only")
                Spacer()
                Button("Cancel") {
                    model.dismissRemoteSheet()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.saveRemote()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 460)
        // Flat pālana ground (ho-06.5 Decision 3).
        .background(Color.ground)
    }

    /// The field's text, read from and written to the sheet's draft.
    private var draftBinding: Binding<String> {
        Binding(
            get: { model.remoteSheet?.draft ?? "" },
            set: { model.remoteSheet?.draft = $0 }
        )
    }
}
