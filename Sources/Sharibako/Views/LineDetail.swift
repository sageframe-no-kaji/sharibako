import SwiftUI

/// The detail column for a line not in the vault — a secret not protected,
/// or a setting (ho-06.10 Decisions 6–7).
///
/// Shows the key, its status, the value exactly as it stands in `.env`
/// (plain text on disk already, so shown in full and selectable), the
/// classifier's recommendation with its reason, and the choice for this line
/// in plain words — "What should Sharibako do?" — bound to
/// ``WorkshopModel/setLineChoice(_:forKey:)``. Beneath it, **Protect this
/// line** when the choice protects, or a quiet "Leave in .env" when it does
/// not. A line in the vault never reaches this view: the window shows
/// `SecretDetail` for it (``WorkshopModel/detailPane``).
///
/// Every word, option, and rule is a `WorkshopModel` read
/// (`WorkshopModel+Pages.swift`, tested); this view only lays them out.
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8).
struct LineDetail: View {
    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        Group {
            if let line = model.selectedLine {
                content(line)
            } else {
                Color.ground
            }
        }
        // Flat pālana ground (ho-06.5 Decision 3).
        .background(Color.ground)
    }

    private func content(_ line: WorkshopModel.ProjectLine) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(line.key)
                        .font(.title2.monospaced())
                        .foregroundStyle(Color.ink)
                        .textSelection(.enabled)
                    Label {
                        Text(WorkshopModel.lineStatusLabel(for: line))
                            .foregroundStyle(Color.inkSecondary)
                    } icon: {
                        Image(systemName: WorkshopModel.lineRowSymbol(for: line.status))
                            .foregroundStyle(line.status.rowPalette.color)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Label("Value in .env", systemImage: "doc.plaintext")
                        .font(.headline)
                        .foregroundStyle(Color.inkSecondary)
                    Text(WorkshopModel.lineValueText(for: line))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.groundDeep)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    if let classLabel = line.classLabel {
                        Text(classLabel)
                            .font(.callout)
                            .foregroundStyle(Color.inkSecondary)
                    }
                }

                Divider()

                choiceSection(line)

                if let error = model.paneError(in: .detail) {
                    PaneErrorView(error: error)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(line.key)
    }

    /// The question, the choice, the note, and the action.
    @ViewBuilder
    private func choiceSection(_ line: WorkshopModel.ProjectLine) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(WorkshopModel.lineChoiceQuestion)
                .font(.headline)
                .foregroundStyle(Color.ink)
            Picker(
                WorkshopModel.lineChoiceQuestion,
                selection: Binding(
                    get: { line.choice ?? .leaveAsSetting },
                    set: { model.setLineChoice($0, forKey: line.key) }
                )
            ) {
                ForEach(model.lineChoiceOptions(for: line), id: \.self) { choice in
                    Text(model.lineChoiceTitle(choice, for: line))
                        .tag(choice)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(model.activity != nil)

            if let sharedID = model.sharedSubPickerID(for: line) {
                Picker(
                    "Shared secret",
                    selection: Binding(
                        get: { sharedID },
                        set: { model.setLineChoice(.useShared(id: $0), forKey: line.key) }
                    )
                ) {
                    ForEach(model.sharedIDs, id: \.self) { id in
                        Text(id)
                            .tag(id)
                    }
                }
                .fixedSize()
                .disabled(model.activity != nil)
            }

            if let note = WorkshopModel.lineChoiceNote(for: line) {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if WorkshopModel.lineOffersProtect(line) {
                Button(WorkshopModel.lineActionTitle(for: line)) {
                    Task { await model.protectLine(key: line.key) }
                }
                .primaryActionButton()
                .disabled(model.activity != nil)
                .help("Move this line into the vault — one Touch ID")
                .padding(.top, 4)
            } else {
                Text(WorkshopModel.lineActionTitle(for: line))
                    .foregroundStyle(Color.inkTertiary)
                    .padding(.top, 4)
            }
        }
    }
}
