import SharibakoCore
import SwiftUI

/// The Workshop's main window: a three-pane `NavigationSplitView` shell with
/// the right-side action panel trailing it (ho-06.5 Decision 1), or the
/// first-run wizard when the resolved path holds no vault yet (ho-06.3
/// Decision 1 — superseding the ho-05 static "no vault" empty state, which
/// stopped at naming the path with nowhere to go next).
///
/// Every Workshop verb lives in `ActionPanel` — the forward-only replacement
/// for the ho-06.2 toolbar + overflow chrome that failed its gate. The
/// toolbar carries only the panel toggle; the collapse state persists across
/// relaunch (`@AppStorage`). The drift confirmation dialog surfaces when
/// `model.pendingDiff` is set; the user must confirm before the overwrite
/// runs. All branching logic lives in `WorkshopModel` (tested); this view is
/// declarative presentation only (Decision 8).
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

    /// Whether the action panel is collapsed (ho-06.5 Decision 1).
    ///
    /// Persists across relaunch — a pure UI preference, same backend as the
    /// appearance override.
    @AppStorage("actionPanelCollapsed")
    private var actionPanelCollapsed = false

    var body: some View {
        switch model.vaultState {
        case .noVault(let expectedPath):
            // ho-06.3 Decision 1: the first-run wizard replaces the ho-05
            // static empty state. All branching lives in
            // `WorkshopModel+FirstRun.swift`; this arm is pure wiring.
            FirstRunWizard(expectedPath: expectedPath)
        case .open:
            HStack(spacing: 0) {
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

                // The action panel (ho-06.5 Decision 1): every Workshop verb,
                // always titled, on the flat panelGround surface. Collapsing
                // removes it entirely; the toolbar toggle restores it.
                if !actionPanelCollapsed {
                    Divider()
                    ActionPanel()
                        .transition(.move(edge: .trailing))
                }
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
                // System-rendered, deliberately (ho-06.5 Decision 4, gate
                // finding): confirmation dialogs render out of the view
                // hierarchy and take NO tint — rust was ignored and even the
                // moss accent never reached them (the untinted button came
                // back system-blue). Dialogs speak the system's alarm voice;
                // pālana rust lands on in-window destructive affordances
                // (first consumer: the owed delete-scope ho).
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
                // System-rendered, same platform constraint as the drift
                // dialog above.
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
            // Delete-scope confirmation (ho-06.7): the first in-window
            // destructive verb reaches its confirmation here. The panel button
            // wears pālana rust; this dialog is system-rendered (role:
            // .destructive, no tint) — the same platform constraint the drift
            // and all-stale dialogs above hit.
            .confirmationDialog(
                "Delete scope",
                isPresented: .init(
                    get: { model.pendingScopeDeletion != nil },
                    set: { if !$0 { model.dismissScopeDeletion() } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Scope", role: .destructive) {
                    model.confirmDeleteScope()
                }
                Button("Cancel", role: .cancel) {
                    model.dismissScopeDeletion()
                }
            } message: {
                if let deletion = model.pendingScopeDeletion {
                    Text(scopeDeletionMessage(for: deletion))
                }
            }
            // Delete-secret confirmation (ho-06.7): same split as above — the
            // detail-pane button wears rust, this dialog is system-rendered.
            .confirmationDialog(
                "Delete secret",
                isPresented: .init(
                    get: { model.pendingSecretDeletion != nil },
                    set: { if !$0 { model.dismissSecretDeletion() } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Secret", role: .destructive) {
                    model.confirmDeleteSecret()
                }
                Button("Cancel", role: .cancel) {
                    model.dismissSecretDeletion()
                }
            } message: {
                if let deletion = model.pendingSecretDeletion {
                    Text(secretDeletionMessage(for: deletion))
                }
            }
            // Remove-stray-marker confirmation (ho-06.3 AT-03, Decision 7):
            // the blast radius is INVERTED from every 06.7 dialog above — the
            // file removed lives in the user's project directory, not the
            // vault — so the copy names the full path and says the vault is
            // untouched. Same platform constraint: system-rendered, no tint.
            .confirmationDialog(
                "Remove stray marker",
                isPresented: .init(
                    get: { model.pendingStrayMarkerRemoval != nil },
                    set: { if !$0 { model.dismissStrayMarkerRemoval() } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove Marker", role: .destructive) {
                    model.confirmRemoveStrayMarker()
                }
                Button("Cancel", role: .cancel) {
                    model.dismissStrayMarkerRemoval()
                }
            } message: {
                if let removal = model.pendingStrayMarkerRemoval {
                    Text(strayMarkerRemovalMessage(for: removal))
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
            // Ingest sheet (ho-06.3 AT-02, Decision 6): presented whenever
            // `model.ingest.session` is non-nil, from any of its three entry
            // points (the panel verb, the first-run wizard's finish
            // hand-off, and — AT-03 — orphaned-marker rows). Dismissing via
            // the system chrome (swipe/Escape) discards the session exactly
            // like the sheet's own Cancel button — the `envPreview` sheet's
            // dismiss-clears-state precedent.
            .sheet(
                isPresented: .init(
                    get: { model.ingest.session != nil },
                    set: { if !$0 { model.cancelIngest() } }
                )
            ) {
                IngestSheet()
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
            .background(Color.groundDeep)
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

    /// The status line's background: the flat `groundDeep` surface (ho-06.5
    /// Decision 3 — the `.bar` material went with the vibrancy), tinted
    /// green while ``statusPulseActive`` — the announce (AT-02 Decision 4).
    ///
    /// Under Reduce Motion the tint still appears and fades, just without an
    /// eased animation curve driving it (a static emphasis, not a flash).
    private var statusPulseBackground: some View {
        ZStack {
            Rectangle().fill(Color.groundDeep)
            if statusPulseActive {
                Rectangle().fill(Color.inSync.opacity(0.40))
            }
        }
    }

    /// The error line's background: red tint while ``errorPulseActive``,
    /// mirroring ``statusPulseBackground``.
    private var errorPulseBackground: some View {
        ZStack {
            Rectangle().fill(Color.groundDeep)
            if errorPulseActive {
                Rectangle().fill(Color.drift.opacity(0.40))
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

/// The toolbar toggle and the drift/all-stale confirmation helpers, split
/// into an extension so the main `View` struct body stays under SwiftLint's
/// `type_body_length` ceiling (the same pressure the `WorkshopModel`
/// extension-file splits relieve, here within one file since a `View`'s
/// `body` and its helpers can't move to another target).
extension WorkshopWindow {
    /// The emptied toolbar (ho-06.5 Decision 1): only the panel toggle.
    ///
    /// Every verb lives in `ActionPanel`. An icon-only chrome toggle is the
    /// native idiom (Xcode's inspector toggle) — the titles-always-visible
    /// rule guards action verbs, not chrome.
    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                if reduceMotion {
                    actionPanelCollapsed.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        actionPanelCollapsed.toggle()
                    }
                }
            } label: {
                Label("Actions", systemImage: "sidebar.trailing")
            }
            .help(actionPanelCollapsed ? "Show the actions panel" : "Hide the actions panel")
        }
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

    private func scopeDeletionMessage(for deletion: WorkshopModel.ScopeDeletion) -> String {
        let noun = deletion.secretCount == 1 ? "secret" : "secrets"
        return """
            "\(deletion.scopeID)" and its \(deletion.secretCount) \(noun) will be removed \
            from the vault. Materialized .env files and project markers are left in place. \
            The removal is committed on the next Sync.
            """
    }

    private func secretDeletionMessage(for deletion: WorkshopModel.SecretDeletion) -> String {
        """
        "\(deletion.key)" will be removed from scope "\(deletion.scopeID)". \
        Materialized .env files are left in place. The removal is committed on the next Sync.
        """
    }

    // MARK: - Stray-marker removal dialog helper

    /// The inverted-blast-radius copy (ho-06.3 Decision 7): unlike every
    /// deletion above, this file lives in the user's own project directory,
    /// not the vault — the message names the full path and says so plainly.
    private func strayMarkerRemovalMessage(for removal: WorkshopModel.StrayMarkerRemoval) -> String {
        """
        "\(removal.markerURL.path)" will be deleted from your project directory. \
        The vault is untouched — this only removes the marker referencing scope \
        "\(removal.scope)".
        """
    }
}
