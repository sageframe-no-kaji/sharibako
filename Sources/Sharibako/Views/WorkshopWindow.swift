import SharibakoCore
import SwiftUI

/// The Workshop's main window: a three-pane `NavigationSplitView` shell, or
/// the "no vault" empty state when the resolved path holds none (Decision 3).
///
/// AT-03 adds the toolbar: Add Scope, Add Shared Secret, Materialize (enabled
/// when a scope is selected), Sync, and Rescan. The drift confirmation dialog
/// surfaces when `model.pendingDiff` is set; the user must confirm before the
/// overwrite runs. All branching logic lives in `WorkshopModel` (tested);
/// this view is declarative presentation only (Decision 8).
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8).
struct WorkshopWindow: View {
    @Environment(WorkshopModel.self)
    private var model

    @State private var showingAddScope = false
    @State private var showingAddSecret = false
    @State private var showingAddShared = false

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
            .sheet(isPresented: $showingAddScope) {
                AddScopeSheet()
            }
            .sheet(isPresented: $showingAddSecret) {
                if let scopeID = model.selectedScopeID {
                    AddSecretSheet(scopeID: scopeID)
                }
            }
            .sheet(isPresented: $showingAddShared) {
                AddSharedEntrySheet()
            }
        }
    }

    // MARK: - Status surface

    /// The bottom status surface: a progress row while a long operation is in
    /// flight (ho-06.1 Decision 1), else the error line, else the status line.
    ///
    /// Precedence: an active operation shows its progress indicator and label;
    /// when idle, errors win over status (both share the surface so every
    /// action visibly concludes, ho-05 Decision 4 / dogfood-gate finding).
    @ViewBuilder private var statusSurface: some View {
        if let activity = model.activity {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(activity.label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.bar)
        } else if let message = model.errorMessage {
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.bar)
        } else if let status = model.statusMessage {
            // Informational result line (e.g. rescan summary) — same surface as
            // errors so actions always visibly conclude.
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.bar)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingAddScope = true
            } label: {
                Label("Add Scope", systemImage: "folder.badge.plus")
            }
            .help("Add a new scope to the vault")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showingAddSecret = true
            } label: {
                Label("Add Secret", systemImage: "plus.circle")
            }
            .disabled(model.selectedScopeID == nil)
            .help(
                model.selectedScopeID == nil
                    ? "Select a scope to add a secret"
                    : "Add a secret to the selected scope"
            )
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showingAddShared = true
            } label: {
                Label("Add Shared Secret", systemImage: "link.badge.plus")
            }
            .help("Add a new shared secret entry to the vault")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.materializeSelectedScope() }
            } label: {
                Label("Materialize", systemImage: "arrow.down.doc")
            }
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

        ToolbarItem(placement: .secondaryAction) {
            Button {
                Task { await model.sync() }
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
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
                Label("Rescan", systemImage: "magnifyingglass")
            }
            .disabled(model.activity != nil)
            .help("Scan configured directories for .sharibako markers")
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
}
