import SwiftUI

/// The Workshop app entry point: one `WorkshopModel`, injected once via
/// `.environment`, hosting the `WorkshopWindow` shell (ho-05 Decision 2).
///
/// The three Add forms are auxiliary `Window` scenes (ho-06.1 AT-03 Decision
/// 6), opened via `openWindow` from `WorkshopWindow`'s toolbar: movable,
/// non-modal, the main window stays interactive while one is open — the
/// operator could not check an existing secret mid-add under ho-05's modal
/// `.sheet`s. Each scene re-declares `.environment(model)` because SwiftUI
/// scenes don't inherit environment values from sibling scenes; `model` is
/// the same instance across all of them (one `WorkshopModel` for the app's
/// lifetime).
@main
struct SharibakoApp: App {
    @State private var model = WorkshopModel()

    /// The appearance override (ho-06.2 AT-03, Decision 4).
    ///
    /// Read from the same `@AppStorage` value `SettingsScene`'s picker writes,
    /// so a change in Settings updates the main window live and survives
    /// relaunch.
    @AppStorage(AppAppearance.storageKey)
    private var appearance: AppAppearance = .system

    /// Window scene identifier for the Add Secret window (Decision 6).
    static let addSecretWindowID = "add-secret"
    /// Window scene identifier for the Add Scope window (Decision 6).
    static let addScopeWindowID = "add-scope"
    /// Window scene identifier for the Add Shared Entry window (Decision 6).
    static let addSharedEntryWindowID = "add-shared-entry"

    var body: some Scene {
        WindowGroup("Sharibako") {
            WorkshopWindow()
                .environment(model)
                .frame(minWidth: 720, minHeight: 440)
                .preferredColorScheme(appearance.colorScheme)
                // The one interactive color drives selection and every
                // `.borderedProminent` CTA (ho-06.4 Decision 4); set on each
                // scene root since scenes don't inherit environment from siblings.
                .tint(Color.accentMoss)
        }

        // The appearance override's home (ho-06.2 AT-03 Decision 4). `Settings {}`
        // keys ⌘, itself and is the correct scene type — NOT a `WindowGroup`
        // (which would need an explicit `id:` and would not wire ⌘,).
        Settings {
            SettingsScene()
                .tint(Color.accentMoss)
        }

        // Add Secret carries its target scope as the window's `value` —
        // read once at open, not re-read from `model.selectedScopeID` while
        // the window is up, so a selection change in the main window after
        // the Add Secret window opens cannot retarget an in-progress add
        // (Decision 6's "must not break when selection changes mid-add").
        WindowGroup("Add Secret", id: Self.addSecretWindowID, for: String.self) { $scopeID in
            if let scopeID {
                AddSecretSheet(scopeID: scopeID)
                    .environment(model)
                    .tint(Color.accentMoss)
            }
        }
        .windowResizability(.contentSize)

        // The unlabeled `WindowGroup(_:)` initializer takes a TITLE, not an id —
        // passing the id positionally registers no id at all and
        // `openWindow(id:)` silently does nothing (ho-06.1 gate finding: the
        // Add Scope button was dead). Every auxiliary scene spells `id:`.
        WindowGroup("Add Scope", id: Self.addScopeWindowID) {
            AddScopeSheet()
                .environment(model)
                .tint(Color.accentMoss)
        }
        .windowResizability(.contentSize)

        WindowGroup("Add Shared Secret", id: Self.addSharedEntryWindowID) {
            AddSharedEntrySheet()
                .environment(model)
                .tint(Color.accentMoss)
        }
        .windowResizability(.contentSize)
    }
}
