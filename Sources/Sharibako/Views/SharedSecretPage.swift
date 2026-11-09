import SwiftUI

/// The page for a Shared-secrets row (ho-06.9 Decision 9): which projects
/// use this shared secret, and under which key.
///
/// Read-only — no verbs this ho; editing, linking, and rotation arrive with
/// linking (ho-07), and the page says so. Never shows the secret's value.
/// The used-by list is ``WorkshopModel/usedBy(sharedID:)``, from the link
/// graph loaded with the scopes (keyless; it reads `.link` files only); its
/// heading and lines come from `WorkshopModel+Pages.swift` (tested).
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8).
struct SharedSecretPage: View {
    /// The shared secret's ID.
    let sharedID: String

    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sharedID)
                        .font(.title2)
                        .foregroundStyle(Color.ink)
                        .textSelection(.enabled)
                    Text("Shared secret")
                        .foregroundStyle(Color.inkSecondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.usedByHeading(sharedID: sharedID))
                        .font(.headline)
                        .foregroundStyle(Color.ink)
                    ForEach(model.usedByLines(sharedID: sharedID), id: \.self) { line in
                        Text(line)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Color.inkSecondary)
                            .textSelection(.enabled)
                    }
                }

                Text(WorkshopModel.sharedSecretNote)
                    .foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.ground)
    }
}
