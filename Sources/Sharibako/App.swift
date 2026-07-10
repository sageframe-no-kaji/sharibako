import SwiftUI

/// The Workshop app entry point: one `WorkshopModel`, injected once via
/// `.environment`, hosting the `WorkshopWindow` shell (ho-05 Decision 2).
@main
struct SharibakoApp: App {
    @State private var model = WorkshopModel()

    var body: some Scene {
        WindowGroup("Sharibako") {
            WorkshopWindow()
                .environment(model)
                .frame(minWidth: 720, minHeight: 440)
        }
    }
}
