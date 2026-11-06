import AppKit
import SwiftUI

/// The Workshop's right-side action column (ho-06.5 Decision 1, made
/// contextual by ho-06.9 Decision 7).
///
/// A hand-built trailing column on the flat `panelGround` surface (the token
/// ho-06.4 defined for exactly this), every verb an always-titled button.
/// Three groups: the selection group, titled with the selected thing's name
/// and holding only its verbs (``WorkshopModel/selectionVerbs`` — omitted
/// when nothing, or a shared secret, is selected); VAULT, the four
/// whole-vault verbs; and the one **New…** menu for the rare by-hand
/// creations. New… is the only menu — the ho-06.2 gate ruled burying the
/// journey's verbs unacceptable, and nothing on the journey lives in it.
///
/// The base carries a quiet System/Light/Dark control (ho-06.5 Decision 2)
/// bound to the same `@AppStorage` value the Settings scene writes — one
/// stored value, two surfaces, no divergence possible. Settings (⌘,) stays
/// the durable home.
///
/// Collapse is the parent's job: `WorkshopWindow` shows or hides the whole
/// column from its toolbar toggle and persists that state.
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8). Which verbs show, their titles, symbols, disabled
/// reasons, and tooltips are ``WorkshopModel`` reads, tested in
/// `WorkshopModelProjectsTests`; every tap routes to a tested intent. The
/// one dispatch here, ``perform(_:)``, only maps a verb to its intent.
struct ActionPanel: View {
    @Environment(WorkshopModel.self)
    private var model

    @Environment(\.openWindow)
    private var openWindow

    /// The appearance override (ho-06.5 Decision 2).
    ///
    /// The same stored value `SettingsScene`'s picker and `App.swift`'s
    /// `.preferredColorScheme` reader use.
    @AppStorage(AppAppearance.storageKey)
    private var appearance: AppAppearance = .system

    /// Fixed column width: wide enough for the longest verb ("Write all out
    /// of date") at body size, narrow enough to stay chrome.
    static let panelWidth: CGFloat = 212

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    selectionGroup
                    vaultGroup
                    newMenu
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 8)
            }

            Spacer(minLength: 0)

            appearanceControl
        }
        .frame(width: Self.panelWidth)
        .frame(maxHeight: .infinity)
        .background(Color.panelGround)
    }

    // MARK: - Groups

    /// The selected thing's verbs, under its name (Decision 7's table).
    ///
    /// Omitted entirely when ``WorkshopModel/selectionVerbs`` is empty —
    /// nothing selected, a shared secret, or a row that has gone. Destructive
    /// verbs wear pālana rust (`Color.drift`); their confirmations are
    /// system-rendered — dialogs take no tint (ho-06.5 gate).
    @ViewBuilder private var selectionGroup: some View {
        if let entry = model.selectedEntry, !model.selectionVerbs.isEmpty {
            panelGroup(entry.name) {
                ForEach(model.selectionVerbs) { verb in
                    actionButton(
                        verb.title,
                        systemImage: verb.systemImage,
                        help: model.help(for: verb),
                        disabled: model.disabledReason(for: verb) != nil || model.activity != nil,
                        tint: verb.isDestructive ? Color.drift : nil
                    ) {
                        perform(verb)
                    }
                }
            }
        }
    }

    /// Verbs acting on the whole vault.
    private var vaultGroup: some View {
        panelGroup("Vault") {
            actionButton(
                "Rescan",
                systemImage: "arrow.clockwise",
                help: "Look for projects under the scan folders",
                disabled: model.activity != nil
            ) {
                Task {
                    await model.rescan {
                        // First Rescan with no scan folder yet: pick one.
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.message = "Choose the folder where you keep your projects"
                        panel.prompt = "Choose"
                        return panel.runModal() == .OK ? panel.url : nil
                    }
                }
            }

            actionButton(
                "Sync",
                systemImage: "arrow.triangle.2.circlepath",
                help: "Back the vault up to its git remote",
                disabled: model.activity != nil
            ) {
                Task { await model.sync() }
            }

            actionButton(
                "Check all",
                systemImage: "checklist",
                help: "Check every protected project's .env against the vault — one Touch ID",
                disabled: model.activity != nil
            ) {
                Task { await model.checkDrift() }
            }

            actionButton(
                "Write all out of date",
                systemImage: "arrow.down.doc.fill",
                help: "Rewrite every out-of-date .env from the vault",
                disabled: !model.hasOutOfDateProjects || model.activity != nil
            ) {
                model.requestMaterializeAllStale()
            }
        }
    }

    /// The one menu (Decision 7): the rare by-hand creations, each opening
    /// its auxiliary `Window` scene (ho-06.1 AT-03 Decision 6) — movable,
    /// non-modal, the main window stays interactive while one is open.
    ///
    /// A borderless `Menu` with the sibling buttons' `Label`, padding, and
    /// ink, so it reads as one more verb on the flat ground (the AT-03 stop
    /// condition's fallback styling, taken directly).
    private var newMenu: some View {
        Menu {
            Button("Project") {
                openWindow(id: SharibakoApp.addScopeWindowID)
            }

            Button(model.newSecretMenuTitle) {
                // The project is read once, here, and travels as the window's
                // `value` — not re-read while the Add Secret window is open,
                // so a selection change in the main window afterward cannot
                // retarget an in-progress add (ho-06.1 Decision 6).
                if let scopeID = model.selectedEntry?.scopeID {
                    openWindow(id: SharibakoApp.addSecretWindowID, value: scopeID)
                }
            }
            .disabled(model.selectedEntry?.scopeID == nil)

            Button("Shared secret") {
                openWindow(id: SharibakoApp.addSharedEntryWindowID)
            }
        } label: {
            Label("New…", systemImage: "plus")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .foregroundStyle(Color.ink)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .help("Create a project, a secret, or a shared secret by hand")
    }

    // MARK: - Appearance control (Decision 2)

    /// The quiet System/Light/Dark control at the panel's base — reachable
    /// without knowing Settings exists; Settings keeps the durable copy.
    private var appearanceControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Appearance")
                .font(.caption)
                .foregroundStyle(Color.inkTertiary)
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .help("Override the app appearance — also in Settings (⌘,)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Building blocks

    /// One labeled group: a quiet header over its verbs.
    private func panelGroup(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption.weight(.medium))
                .tracking(0.6)
                .foregroundStyle(Color.inkTertiary)
                .padding(.leading, 6)
            content()
        }
    }

    /// One always-titled panel verb.
    ///
    /// The foreground is set explicitly per state (ink / faint ink, or `tint`
    /// when the verb is destructive) because an explicit `foregroundStyle` would
    /// otherwise override the borderless style's automatic disabled dimming — the
    /// honesty of a dimmed disabled verb matters more than the one-liner. A
    /// disabled verb always dims to faint ink regardless of `tint`.
    private func actionButton(
        _ title: String,
        systemImage: String,
        help: String,
        disabled: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(disabled ? Color.inkTertiary : (tint ?? Color.ink))
        .disabled(disabled)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .help(help)
    }

    // MARK: - Verb dispatch

    /// Routes a selection verb to its model intent.
    ///
    /// The selected row supplies the target: its folder for Protect and Open
    /// in Finder, its claim file for the two Problem verbs. A no-op when the
    /// row has gone — the button would not be showing then.
    private func perform(_ verb: WorkshopModel.SelectionVerb) {
        guard let entry = model.selectedEntry else { return }
        switch verb {
        case .protect:
            if let directory = entry.directory {
                Task { await model.beginIngest(directory: directory) }
            }
        case .writeEnv:
            Task { await model.materializeSelectedScope() }
        case .previewEnv:
            Task { await model.previewEnv() }
        case .openInFinder:
            if let directory = entry.directory {
                model.openInFinder(directory)
            }
        case .deleteProject:
            model.requestDeleteSelectedScope()
        case .protectFolder:
            if let marker = entry.problemMarker {
                Task { await model.createScopeFromMarker(marker) }
            }
        case .forgetFolder:
            if let marker = entry.problemMarker {
                model.requestRemoveStrayMarker(marker)
            }
        }
    }
}
