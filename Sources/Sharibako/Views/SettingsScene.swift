import SwiftUI

/// The native Settings scene (⌘,) — the appearance override only (ho-06.2
/// AT-03, Decision 4).
///
/// `Settings {}` in `App.swift` wires ⌘, automatically and is the right scene
/// type (not a `WindowGroup`, which would need an explicit `id:` and would not
/// key ⌘,). The picker binds to the same `@AppStorage` value the main window
/// reads for `.preferredColorScheme`, so a change here updates the main window
/// live and survives relaunch. No invented heal/glyph toggles — appearance is
/// the only content this ho ratified (a "check drift at launch" toggle would
/// re-introduce the launch Touch ID this ho designs away).
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable (ho-05
/// Decision 8). The tested logic — the appearance ↔ `ColorScheme?` mapping —
/// lives in `AppAppearance` (not excluded).
struct SettingsScene: View {
    @AppStorage(AppAppearance.storageKey)
    private var appearance: AppAppearance = .system

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 160)
    }
}
