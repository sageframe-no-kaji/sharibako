import AppKit
import SwiftUI

/// The one project page (ho-06.10 Decision 6): every project gets it,
/// protected or not, and a folder the vault does not know yet is the same
/// page with nothing protected.
///
/// The header names the project and its folder, then where it stands: the
/// large red mark, "N secrets not protected", and the one **Protect N
/// secrets** button while any secret sits in `.env` in plain text; the green
/// check and "Protected" (with the check's clause) once none does. Beneath,
/// the lines: secrets first, each with its status mark, key, value (masked
/// for a line in the vault) and caption; then the settings, folded under one
/// row. Selecting a line fills the detail column (`SecretDetail` or
/// `LineDetail`, chosen by ``WorkshopModel/detailPane``). Every line and the
/// page's sidebar row carry right-click menus (Decision 8).
///
/// There is no sheet: the page is the review (Decision 6). Every word,
/// symbol, count, tint, and which verbs a line offers are `WorkshopModel`
/// and `Color+Theme.swift` reads, tested there; ``perform(_:on:)`` only maps
/// a verb to its intent, as `ActionPanel`'s dispatch does.
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8).
struct ProjectPage: View {
    /// The selected row — a project, or a folder not yet protected.
    let entry: WorkshopModel.ProjectEntry

    @Environment(WorkshopModel.self)
    private var model

    /// Whether the settings fold is open; collapsed by default and kept
    /// while the page stays up (Required Change 2).
    @State private var settingsExpanded = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            lines(selection: $model.selectedLineKey)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.ground)
        .onChange(of: model.selectedLineKey) {
            model.loadSelectedLineHistory()
        }
    }

    // MARK: - Header

    /// The title block, the state row, and any pane error beneath it.
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageTitle(entry: entry, directory: entry.directory, showsStatus: false)
            if model.areLinesLoaded {
                // The button sits right of the state on a wide column and
                // drops beneath it on a narrow one.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        stateLabel
                        Spacer(minLength: 16)
                        protectButton
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        stateLabel
                        protectButton
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading .env…")
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            if let error = model.paneError(in: .page) {
                PaneErrorView(error: error)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The mark and the words for where the project stands.
    private var stateLabel: some View {
        let state = model.headerState
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: state.symbolName)
                .font(.system(size: 28))
                .foregroundStyle(state.markPalette.color)
            Text(state.steadyLabel)
                .font(.title3)
                .foregroundStyle(state.labelPalette.color)
            if let clause = state.alarmClause {
                Text("· \(clause)")
                    .font(.title3)
                    .foregroundStyle(Color.drift)
            }
        }
        .fixedSize()
    }

    /// The one Protect button, while secrets are not protected.
    @ViewBuilder private var protectButton: some View {
        if model.headerState.offersProtect {
            Button(model.protectButtonTitle) {
                Task { await model.protectRecommended() }
            }
            .primaryActionButton()
            .disabled(model.isProtectButtonDisabled)
            .help(model.protectButtonHelp)
            .fixedSize()
        }
    }

    // MARK: - Lines

    /// The lines list, the reading state, or the empty state.
    @ViewBuilder
    private func lines(selection: Binding<String?>) -> some View {
        if !model.areLinesLoaded {
            Color.ground
        } else if model.projectLines.isEmpty {
            ContentUnavailableView(
                "No lines",
                systemImage: "doc.text",
                description: Text(WorkshopModel.noLinesDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: selection) {
                ForEach(model.secretLines) { line in
                    row(line)
                        .tag(line.key)
                }
                if !model.settingLines.isEmpty {
                    if !model.secretLines.isEmpty {
                        Divider()
                    }
                    DisclosureGroup(isExpanded: $settingsExpanded) {
                        ForEach(model.settingLines) { line in
                            row(line)
                                .tag(line.key)
                        }
                    } label: {
                        Text(model.settingsFoldLabel)
                            .foregroundStyle(Color.inkSecondary)
                    }
                }
                ForEach(model.lineWarnings, id: \.self) { warning in
                    Text(warning)
                        .font(.callout)
                        .foregroundStyle(Color.drift)
                        .selectionDisabled()
                }
            }
            // Flat pālana ground (ho-06.5 Decision 3): the page's backdrop
            // carries the paper; the list stops painting over it.
            .scrollContentBackground(.hidden)
        }
    }

    /// One line: status mark, key, value, and the caption beneath.
    private func row(_ line: WorkshopModel.ProjectLine) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: WorkshopModel.lineRowSymbol(for: line.status))
                    .imageScale(.small)
                    .foregroundStyle(line.status.rowPalette.color)
                    .frame(width: 16)
                Text(line.key)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(line.status.keyPalette.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 16)
                Text(WorkshopModel.lineValueText(for: line))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(WorkshopModel.lineCaption(for: line))
                .font(.caption)
                .foregroundStyle(line.status.captionPalette.color)
                .padding(.leading, 24)
        }
        .padding(.vertical, 2)
        .help(WorkshopModel.lineStatusLabel(for: line))
        .contextMenu {
            lineMenu(line)
        }
    }

    /// A line's right-click menu: the verbs from
    /// ``WorkshopModel/lineVerbs(for:)``, choices as checkable items.
    @ViewBuilder
    private func lineMenu(_ line: WorkshopModel.ProjectLine) -> some View {
        ForEach(model.lineVerbs(for: line)) { verb in
            if let systemImage = verb.systemImage {
                Button(role: verb.isDestructive ? .destructive : nil) {
                    perform(verb, on: line)
                } label: {
                    Label(verb.title, systemImage: systemImage)
                }
                .disabled(model.isLineVerbDisabled(verb))
            } else {
                Toggle(
                    verb.title,
                    isOn: Binding(
                        get: { WorkshopModel.isLineVerbChecked(verb, for: line) },
                        set: { _ in perform(verb, on: line) }
                    ))
            }
        }
    }

    /// Routes a line verb to its model intent.
    ///
    /// The mapping only, as `ActionPanel`'s dispatch; Copy's clipboard write
    /// is the one AppKit call the model cannot make.
    private func perform(_ verb: WorkshopModel.LineVerb, on line: WorkshopModel.ProjectLine) {
        switch verb {
        case .protectLine:
            Task { await model.protectLineNow(key: line.key) }
        case .choose(let choice):
            model.setLineChoice(choice, forKey: line.key)
        case .reveal:
            model.revealLine(key: line.key)
        case .copy:
            if let value = model.copyableValue(forKey: line.key) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
        case .deleteSecret:
            model.requestDeleteLine(key: line.key)
        }
    }
}
