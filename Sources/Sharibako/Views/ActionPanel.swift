import AppKit
import SwiftUI

/// The Workshop's right-side action panel (ho-06.5 Decision 1) — the
/// forward-only replacement for ho-06.2's failed toolbar + overflow chrome.
///
/// A hand-built trailing column on the flat `panelGround` surface (the token
/// ho-06.4 defined for exactly this), hosting every Workshop verb as an
/// always-titled button in labeled groups: the selected scope's verbs, the
/// vault-wide verbs, and the create verbs. Nothing lives behind a nested menu
/// — the ho-06.2 gate ruled that burial unacceptable. Disabled logic travels
/// with each verb unchanged from the toolbar it replaces (`selectedScopeID`,
/// `model.activity`, the preview/jump disabled reasons).
///
/// The base carries a quiet System/Light/Dark control (Decision 2) bound to
/// the same `@AppStorage` value the Settings scene writes — one stored value,
/// two surfaces, no divergence possible. Settings (⌘,) stays the durable home.
///
/// Collapse is the parent's job: `WorkshopWindow` shows or hides the whole
/// panel from its toolbar toggle and persists that state.
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8). Every verb routes through `WorkshopModel`'s tested
/// intents; no branching logic lives here beyond reading the model's
/// published disabled reasons.
struct ActionPanel: View {
    @Environment(WorkshopModel.self)
    private var model

    @Environment(\.openWindow)
    private var openWindow

    /// The appearance override (Decision 2).
    ///
    /// The same stored value `SettingsScene`'s picker and `App.swift`'s
    /// `.preferredColorScheme` reader use.
    @AppStorage(AppAppearance.storageKey)
    private var appearance: AppAppearance = .system

    /// Fixed panel width: wide enough for the longest title
    /// ("Materialize All Stale") at body size, narrow enough to stay chrome.
    static let panelWidth: CGFloat = 212

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    scopeGroup
                    vaultGroup
                    addGroup
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

    /// Verbs acting on the selected scope.
    private var scopeGroup: some View {
        panelGroup("Scope") {
            actionButton(
                "Materialize",
                systemImage: "arrow.down.doc",
                help: model.selectedScopeID == nil
                    ? "Select a scope to materialize its secrets"
                    : "Write this scope's secrets into its .env target",
                disabled: model.selectedScopeID == nil || model.activity != nil
            ) {
                Task { await model.materializeSelectedScope() }
            }

            actionButton(
                "Preview .env",
                systemImage: "doc.text.magnifyingglass",
                help: "Show exactly what Materialize would write, and where",
                disabled: model.previewDisabledReason != nil || model.activity != nil
            ) {
                Task { await model.previewEnv() }
            }

            actionButton(
                "Jump to Directory",
                systemImage: "arrow.up.forward.square",
                help: "Open the scope's marker directory in Finder",
                disabled: model.jumpDisabledReason != nil
            ) {
                jumpToSelectedScopeDirectory()
            }
        }
    }

    /// Verbs acting on the whole vault.
    private var vaultGroup: some View {
        panelGroup("Vault") {
            actionButton(
                "Check Drift",
                systemImage: "arrow.triangle.branch",
                help: "Check every materialized scope for drift from the vault (one Touch ID)",
                disabled: model.activity != nil
            ) {
                Task { await model.checkDrift() }
            }

            actionButton(
                "Materialize All Stale",
                systemImage: "arrow.down.doc.fill",
                help: "Reconcile every drifted scope from the last drift check",
                disabled: model.activity != nil
            ) {
                model.requestMaterializeAllStale()
            }

            actionButton(
                "Sync",
                systemImage: "arrow.triangle.2.circlepath",
                help: "Commit pending vault changes and push to the remote",
                disabled: model.activity != nil
            ) {
                Task { await model.sync() }
            }

            actionButton(
                "Rescan",
                systemImage: "arrow.clockwise",
                help: "Scan configured directories for .sharibako markers",
                disabled: model.activity != nil
            ) {
                Task {
                    await model.rescan {
                        // Open an NSOpenPanel directory picker for the scan root.
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.message = "Choose a directory to scan for .sharibako markers"
                        panel.prompt = "Choose"
                        return panel.runModal() == .OK ? panel.url : nil
                    }
                }
            }
        }
    }

    /// The create verbs — each opens its auxiliary `Window` scene
    /// (ho-06.1 AT-03 Decision 6): movable, non-modal, the main window stays
    /// interactive while one is open.
    private var addGroup: some View {
        panelGroup("Add") {
            actionButton(
                "Add Scope",
                systemImage: "folder.badge.plus",
                help: "Add a new scope to the vault"
            ) {
                openWindow(id: SharibakoApp.addScopeWindowID)
            }

            actionButton(
                "Add Secret",
                systemImage: "plus.circle",
                help: model.selectedScopeID == nil
                    ? "Select a scope to add a secret"
                    : "Add a secret to the selected scope",
                disabled: model.selectedScopeID == nil
            ) {
                // The scope ID is read once, here, and travels as the window's
                // `value` — not re-read from `model.selectedScopeID` while the
                // Add Secret window is open, so a selection change in the main
                // window afterward cannot retarget an in-progress add
                // (ho-06.1 Decision 6).
                if let scopeID = model.selectedScopeID {
                    openWindow(id: SharibakoApp.addSecretWindowID, value: scopeID)
                }
            }

            actionButton(
                "Add Shared Secret",
                systemImage: "link.badge.plus",
                help: "Add a shared entry that scopes can link to"
            ) {
                openWindow(id: SharibakoApp.addSharedEntryWindowID)
            }
        }
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
    /// The foreground is set explicitly per state (ink / faint ink) because an
    /// explicit `foregroundStyle` would otherwise override the borderless
    /// style's automatic disabled dimming — the honesty of a dimmed disabled
    /// verb matters more than the one-liner.
    private func actionButton(
        _ title: String,
        systemImage: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(disabled ? Color.inkTertiary : Color.ink)
        .disabled(disabled)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .help(help)
    }

    // MARK: - Jump to Directory

    /// Opens the selected scope's cached marker directory in Finder and
    /// announces it (ho-06.1 AT-02 Decision 3; moved here from the toolbar
    /// this panel replaces).
    ///
    /// A no-op when nothing is selected or the cache holds no marker — the
    /// panel button is already disabled in that state, so this is a defensive
    /// guard, not the primary gate.
    private func jumpToSelectedScopeDirectory() {
        guard let scopeID = model.selectedScopeID,
            let directory = model.jumpTargetDirectory(forScope: scopeID)
        else { return }
        NSWorkspace.shared.open(directory)
        model.announceJump(to: directory)
    }
}
