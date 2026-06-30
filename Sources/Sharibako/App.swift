import SharibakoCore
import SwiftUI

@main
struct SharibakoApp: App {
    var body: some Scene {
        WindowGroup("Sharibako") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Sharibako")
                .font(.largeTitle)
            Text("v\(SharibakoCore.version)")
                .foregroundStyle(.secondary)
            Text("Workshop placeholder. Build the real UI in ho-05.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }
}
