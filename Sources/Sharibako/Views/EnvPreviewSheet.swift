import SwiftUI

/// Renders the exact `.env` composition "Preview .env" produced.
///
/// A materialize dry-run and the scope-level reveal surface (ho-06.1 AT-03,
/// Decision 5): monospaced, text-selectable, titled with the target path so
/// the operator sees exactly what Materialize would write and where.
///
/// Presented when `model.envPreview` is non-nil; dismissing (Done or the
/// sheet's own close) calls `model.dismissEnvPreview()`. All branching logic
/// (the preview intent, marker resolution, the Touch ID load) lives in
/// `WorkshopModel`/`WorkshopModel+Preview.swift`; this view only reads the
/// published `EnvPreviewResult`.
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8) — same justification as `SecretDetail` and the Add
/// sheets.
struct EnvPreviewSheet: View {
    @Environment(WorkshopModel.self)
    private var model

    @Environment(\.dismiss)
    private var dismiss

    let preview: EnvPreviewResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Preview .env — \(preview.scopeID)")
                    .font(.headline)
                Text("This is what Materialize writes to \(preview.targetURL.path)")
                    .font(.callout)
                    .foregroundStyle(Color.inkSecondary)
                    .textSelection(.enabled)
            }

            ScrollView {
                Text(preview.content)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Spacer()
                Button("Done") {
                    model.dismissEnvPreview()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 360)
    }
}
