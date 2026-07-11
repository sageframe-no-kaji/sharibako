import SharibakoCore
import SwiftUI

/// The Workshop's main window: a three-pane `NavigationSplitView` shell, or
/// the "no vault" empty state when the resolved path holds none (Decision 3).
///
/// The toolbar carries Add Scope, Add Shared Secret, Materialize (enabled
/// when a scope is selected), Preview .env, Sync, Rescan, and — its own
/// block, left of Sync (ho-06.1 AT-02 Decision 3) — Jump to Directory. The
/// three Add actions open auxiliary `Window` scenes via `openWindow`
/// (ho-06.1 AT-03 Decision 6) — movable, non-modal, this window stays
/// interactive while one is open. The drift confirmation dialog surfaces
/// when `model.pendingDiff` is set; the user must confirm before the
/// overwrite runs. All branching logic lives in `WorkshopModel` (tested);
/// this view is declarative presentation only (Decision 8).
///
/// The status surface pulses green on a `statusMessage` change and red on an
/// `errorMessage` change (AT-02 Decision 4) — the text persists (no
/// auto-clear); Reduce Motion swaps the animated tint for a static one.
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8).
struct WorkshopWindow: View {
    @Environment(WorkshopModel.self)
    private var model

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @Environment(\.openWindow)
    private var openWindow

    /// Leading inset shared by the status surface and the sidebar footer's
    /// own horizontal padding (`ScopeSidebar`), so the status line's leading
    /// edge reads as continuous with the sidebar column's section labels
    /// (AT-02 Decision 4) instead of spanning the full window edge-to-edge.
    /// 16 pt also keeps the bottom row's text clear of the window's rounded
    /// corners (ho-06.1 gate finding).
    private static let sidebarAlignedInset: CGFloat = 16

    /// `true` for one brief window after `statusMessage` changes — drives the
    /// status surface's green pulse.
    @State private var statusPulseActive = false
    /// `true` for one brief window after `errorMessage` changes — drives the
    /// status surface's red pulse.
    @State private var errorPulseActive = false

    var body: some View {
        switch model.vaultState {
        case .noVault(let expectedPath):
            ContentUnavailableView {
                Label("No vault found", systemImage: "shippingbox")
            } description: {
                Text(
                    "Sharibako looked for a vault at \(expectedPath.path) "
                        + "and found none. Create one with `sharibako key generate` "
                        + "or point SHARIBAKO_VAULT at an existing vault."
                )
                .textSelection(.enabled)
            }
        case .open:
            NavigationSplitView {
                ScopeSidebar()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 240)
            } content: {
                SecretList()
                    .onAppear {
                        if let scopeID = model.selectedScopeID {
                            model.loadSecrets(for: scopeID)
                        }
                    }
                    .onChange(of: model.selectedScopeID) { _, newScopeID in
                        if let scopeID = newScopeID {
                            model.loadSecrets(for: scopeID)
                        }
                    }
            } detail: {
                SecretDetail()
            }
            .toolbar {
                toolbarContent
            }
            // Warm the scan cache without blocking window render (ho-06.1
            // Decision 2): the window paints immediately; the launch scan runs
            // through the worker behind it. A no-op when no roots are configured
            // or the vault is not open.
            .task {
                await model.performLaunchScan()
            }
            .safeAreaInset(edge: .bottom) {
                statusSurface
            }
            // Status pulse (Decision 4): a brief background tint on change,
            // never a timer that clears the text — the message stays until the
            // next action replaces it. Reduce Motion swaps the animated flash
            // for an immediate static tint of the same duration-independent shape.
            .onChange(of: model.statusMessage) { _, newValue in
                guard newValue != nil else { return }
                pulse($statusPulseActive)
            }
            .onChange(of: model.errorMessage) { _, newValue in
                guard newValue != nil else { return }
                pulse($errorPulseActive)
            }
            // Drift confirmation dialog: surfaces when materialize detects owned
            // lines that differ from vault values. Requires explicit confirmation
            // before overwriting (Decision 5 — never silently overwrite drift).
            .confirmationDialog(
                driftTitle,
                isPresented: .init(
                    get: { model.pendingDiff != nil },
                    set: { if !$0 { model.dismissPendingDiff() } }
                ),
                titleVisibility: .visible
            ) {
                Button("Overwrite Drift", role: .destructive) {
                    Task { await model.materializeSelectedScope(force: true) }
                }
                Button("Cancel", role: .cancel) {
                    model.dismissPendingDiff()
                }
            } message: {
                if let diff = model.pendingDiff {
                    Text(driftMessage(for: diff))
                }
            }
            // Preview .env (ho-06.1 AT-03 Decision 5): presented whenever
            // `envPreview` is non-nil; dismissing (either affordance) clears it.
            .sheet(
                isPresented: .init(
                    get: { model.envPreview != nil },
                    set: { if !$0 { model.dismissEnvPreview() } }
                )
            ) {
                if let preview = model.envPreview {
                    EnvPreviewSheet(preview: preview)
                }
            }
        }
    }

    // MARK: - Status surface

    /// The bottom status surface: a progress row while a long operation is in
    /// flight (ho-06.1 Decision 1), else the error line, else the status line.
    ///
    /// Precedence: an active operation shows its progress indicator and label;
    /// when idle, errors win over status (both share the surface so every
    /// action visibly concludes, ho-05 Decision 4 / dogfood-gate finding). The
    /// leading edge is inset by ``sidebarAlignedInset`` to read as continuous
    /// with the sidebar column's section labels rather than the window edge
    /// (AT-02 Decision 4).
    @ViewBuilder private var statusSurface: some View {
        if let activity = model.activity {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(activity.label)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.leading, Self.sidebarAlignedInset)
            .padding(.trailing, Self.sidebarAlignedInset)
            .background(.bar)
        } else if let message = model.errorMessage {
            Text(message)
                .font(.body)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.leading, Self.sidebarAlignedInset)
                .padding(.trailing, 8)
                .background(errorPulseBackground)
        } else if let status = model.statusMessage {
            // Informational result line (e.g. rescan summary) — same surface as
            // errors so actions always visibly conclude.
            Text(status)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.leading, Self.sidebarAlignedInset)
                .padding(.trailing, 8)
                .background(statusPulseBackground)
        }
    }

    /// The status line's background: the standard `.bar` material, tinted
    /// green while ``statusPulseActive`` — the announce (AT-02 Decision 4).
    ///
    /// Under Reduce Motion the tint still appears and fades, just without an
    /// eased animation curve driving it (a static emphasis, not a flash).
    private var statusPulseBackground: some View {
        ZStack {
            Rectangle().fill(.bar)
            if statusPulseActive {
                Rectangle().fill(Color.green.opacity(0.25))
            }
        }
    }

    /// The error line's background: red tint while ``errorPulseActive``,
    /// mirroring ``statusPulseBackground``.
    private var errorPulseBackground: some View {
        ZStack {
            Rectangle().fill(.bar)
            if errorPulseActive {
                Rectangle().fill(Color.red.opacity(0.25))
            }
        }
    }

    /// Flips `flag` on, animated unless Reduce Motion is active, then off
    /// after a brief window — the announce (Decision 4).
    ///
    /// The message itself is untouched: no auto-clear timer, ever.
    private func pulse(_ flag: Binding<Bool>) {
        if reduceMotion {
            flag.wrappedValue = true
        } else {
            withAnimation(.easeIn(duration: 0.15)) {
                flag.wrappedValue = true
            }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if reduceMotion {
                flag.wrappedValue = false
            } else {
                withAnimation(.easeOut(duration: 0.3)) {
                    flag.wrappedValue = false
                }
            }
        }
    }

    // MARK: - Toolbar

    /// Every action button carries an always-visible title alongside its icon
    /// (AT-02 Decision 4 — hover tooltips failed the operator at the ho-05
    /// gate).
    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        // Add Scope/Secret/Shared open auxiliary windows (ho-06.1 AT-03
        // Decision 6) rather than modal sheets — the main window stays
        // interactive while one is up.
        ToolbarItem(placement: .primaryAction) {
            Button {
                openWindow(id: SharibakoApp.addScopeWindowID)
            } label: {
                Label("Add Scope", systemImage: "folder.badge.plus")
            }
            .labelStyle(.titleAndIcon)
            .help("Add a new scope to the vault")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                // The scope ID is read once, here, and travels as the
                // window's `value` — not re-read from `model.selectedScopeID`
                // while the Add Secret window is open, so a selection change
                // in the main window afterward cannot retarget an in-progress
                // add (Decision 6).
                if let scopeID = model.selectedScopeID {
                    openWindow(id: SharibakoApp.addSecretWindowID, value: scopeID)
                }
            } label: {
                Label("Add Secret", systemImage: "plus.circle")
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.selectedScopeID == nil)
            .help(
                model.selectedScopeID == nil
                    ? "Select a scope to add a secret"
                    : "Add a secret to the selected scope"
            )
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                openWindow(id: SharibakoApp.addSharedEntryWindowID)
            } label: {
                Label("Add Shared Secret", systemImage: "link.badge.plus")
            }
            .labelStyle(.titleAndIcon)
            .help("Add a new shared secret entry to the vault")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.materializeSelectedScope() }
            } label: {
                Label("Materialize", systemImage: "arrow.down.doc")
            }
            .labelStyle(.titleAndIcon)
            // Disabled while any long operation is in flight — the intents also
            // guard re-entry, but the disabled button keeps the UI honest
            // (ho-06.1 Decision 1).
            .disabled(model.selectedScopeID == nil || model.activity != nil)
            .help(
                model.selectedScopeID == nil
                    ? "Select a scope to materialize its secrets"
                    : "Write this scope's secrets into its .env target"
            )
        }

        // Preview .env: adjacent to Materialize (ho-06.1 AT-03 Decision 5) —
        // one Touch ID renders exactly what Materialize would write, without
        // writing. Disabled without a selected scope + cached marker, same
        // gate as Jump to Directory.
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.previewEnv() }
            } label: {
                Label("Preview .env", systemImage: "doc.text.magnifyingglass")
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.previewDisabledReason != nil || model.activity != nil)
            .help(model.previewDisabledReason ?? "Preview this scope's .env composition")
        }

        // Jump to Directory: its own block, left of Sync (operator-specified
        // placement at the ho-05 gate). Reads the AT-01 scan cache only —
        // never re-scans for display; the disabled reason names why it can't
        // (AT-02 Decision 3).
        ToolbarItem(placement: .secondaryAction) {
            Button {
                jumpToSelectedScopeDirectory()
            } label: {
                Label("Jump to Directory", systemImage: "arrow.up.forward.square")
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.jumpDisabledReason != nil)
            .help(model.jumpDisabledReason ?? "Open this scope's marker directory in Finder")
        }

        ToolbarItem(placement: .secondaryAction) {
            Button {
                Task { await model.sync() }
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.activity != nil)
            .help("Commit pending vault changes and push to the remote")
        }

        ToolbarItem(placement: .secondaryAction) {
            Button {
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
            } label: {
                // Rotate-form, not a magnifying glass (AT-02 Decision 4) — Rescan
                // re-walks known roots, it doesn't search for new ones.
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.activity != nil)
            .help("Scan configured directories for .sharibako markers")
        }
    }

    // MARK: - Jump to Directory

    /// Opens the selected scope's cached marker directory in Finder and
    /// announces it (AT-02 Decision 3).
    ///
    /// A no-op when nothing is selected or the cache holds no marker — the
    /// toolbar button is already disabled in that state, so this is a
    /// defensive guard, not the primary gate.
    private func jumpToSelectedScopeDirectory() {
        guard let scopeID = model.selectedScopeID,
            let directory = model.jumpTargetDirectory(forScope: scopeID)
        else { return }
        NSWorkspace.shared.open(directory)
        model.announceJump(to: directory)
    }

    // MARK: - Drift dialog helpers

    private var driftTitle: String {
        guard let diff = model.pendingDiff else { return "Materialize Drift" }
        return "Drift detected in \(diff.path.lastPathComponent)"
    }

    private func driftMessage(for diff: MaterializeDiff) -> String {
        var parts: [String] = []
        if !diff.ownedKeysDiffering.isEmpty {
            parts.append("Changed: \(diff.ownedKeysDiffering.joined(separator: ", "))")
        }
        if !diff.ownedKeysMissingFromFile.isEmpty {
            parts.append("Missing: \(diff.ownedKeysMissingFromFile.joined(separator: ", "))")
        }
        parts.append("Overwriting will replace file values with vault values.")
        return parts.joined(separator: "\n")
    }
}
