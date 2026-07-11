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
            // Materialize-all-stale confirmation (AT-02 Decision 3): lists the
            // drifted scopes and target paths that will be written before the
            // one-Touch-ID batch reconcile runs.
            .confirmationDialog(
                "Reconcile drifted scopes",
                isPresented: .init(
                    get: { model.allStalePlan != nil },
                    set: { if !$0 { model.dismissAllStale() } }
                ),
                titleVisibility: .visible
            ) {
                Button("Overwrite \(allStaleCount) Target\(allStaleCount == 1 ? "" : "s")", role: .destructive) {
                    Task { await model.confirmMaterializeAllStale() }
                }
                Button("Cancel", role: .cancel) {
                    model.dismissAllStale()
                }
            } message: {
                if let plan = model.allStalePlan {
                    Text(allStaleMessage(for: plan))
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
                    .foregroundStyle(Color.inkSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.leading, Self.sidebarAlignedInset)
            .padding(.trailing, Self.sidebarAlignedInset)
            .background(.bar)
        } else if let message = model.errorMessage {
            Text(message)
                .font(.body)
                .foregroundStyle(Color.drift)
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
                .foregroundStyle(Color.inkSecondary)
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
                Rectangle().fill(Color.inSync.opacity(0.25))
            }
        }
    }

    /// The error line's background: red tint while ``errorPulseActive``,
    /// mirroring ``statusPulseBackground``.
    private var errorPulseBackground: some View {
        ZStack {
            Rectangle().fill(.bar)
            if errorPulseActive {
                Rectangle().fill(Color.drift.opacity(0.25))
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
}

// MARK: - Toolbar and dialogs

/// The toolbar content, the drift/all-stale confirmation helpers, and the
/// jump-to-directory action, split into an extension so the main `View` struct
/// body stays under SwiftLint's `type_body_length` ceiling (the same pressure
/// the `WorkshopModel` extension-file splits relieve, here within one file
/// since a `View`'s `body` and its helpers can't move to another target).
extension WorkshopWindow {
    /// Every primary action carries an always-visible title alongside its icon
    /// (AT-02 Decision 4 — hover tooltips failed the operator at the ho-05
    /// gate). ho-06.2 Decision 1's chrome fix keeps the native top-toolbar
    /// (no right-side rail): the heal workflow this ho adds — Materialize,
    /// Check Drift, Materialize All Stale — sits front-and-center as primary
    /// titled actions alongside Sync and Rescan; the two secondary reads that
    /// crowded the bar (Preview .env, Jump to Directory) and the least-used
    /// create action (Add Shared Secret) move into a legible overflow menu with
    /// their titles intact.
    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        // Add Scope/Secret open auxiliary windows (ho-06.1 AT-03 Decision 6)
        // rather than modal sheets — the main window stays interactive while
        // one is up.
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

        // Check Drift: sweeps every live-here scope behind one Touch ID
        // (Decision 3). Sits beside Materialize — the per-scope drift workflow.
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.checkDrift() }
            } label: {
                Label("Check Drift", systemImage: "arrow.triangle.branch")
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.activity != nil)
            .help("Check every materialized scope for drift from the vault (one Touch ID)")
        }

        // Materialize All Stale: batch-reconciles the drift-cache's drifted set
        // behind one confirmation and one Touch ID (Decision 3). Prompts to
        // check drift first when the cache is empty.
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.requestMaterializeAllStale()
            } label: {
                Label("Materialize All Stale", systemImage: "arrow.down.doc.fill")
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.activity != nil)
            .help("Reconcile every drifted scope from the last drift check")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.sync() }
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.activity != nil)
            .help("Commit pending vault changes and push to the remote")
        }

        ToolbarItem(placement: .primaryAction) {
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

        // Overflow: the secondary reads and the least-used create action, kept
        // legible as a titled menu rather than crowding the primary bar past
        // legibility (Decision 1's chrome fix — native menu, not a rail).
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    openWindow(id: SharibakoApp.addSharedEntryWindowID)
                } label: {
                    Label("Add Shared Secret", systemImage: "link.badge.plus")
                }

                Button {
                    Task { await model.previewEnv() }
                } label: {
                    Label("Preview .env", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(model.previewDisabledReason != nil || model.activity != nil)

                Button {
                    jumpToSelectedScopeDirectory()
                } label: {
                    Label("Jump to Directory", systemImage: "arrow.up.forward.square")
                }
                .disabled(model.jumpDisabledReason != nil)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More actions — Add Shared Secret, Preview .env, Jump to Directory")
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

    // MARK: - Materialize-all-stale dialog helpers

    /// The number of scopes the pending all-stale plan would reconcile.
    private var allStaleCount: Int {
        model.allStalePlan?.scopeIDs.count ?? 0
    }

    /// The all-stale confirmation body: each drifted scope and the target path
    /// that will be written, so the batch write is never a blind action.
    private func allStaleMessage(for plan: WorkshopModel.AllStalePlan) -> String {
        var lines = ["These scopes will be overwritten with vault values:"]
        for (index, scopeID) in plan.scopeIDs.enumerated() {
            let path = index < plan.targetPaths.count ? plan.targetPaths[index] : ""
            lines.append("• \(scopeID) → \(path)")
        }
        return lines.joined(separator: "\n")
    }
}
