import SwiftUI

/// A secure-value entry field with a show-while-typing eye toggle (ho-06.1
/// AT-03, Decision 5).
///
/// Swaps between `SecureField` (masked, default) and `TextField` (plaintext)
/// on the same `text` binding — focus and the typed value both survive the
/// swap since it's the same underlying binding, just a different field type
/// rendering it. Shared by Add Secret, Add Shared Entry, and the rotate
/// field so the toggle behavior can't drift across the three call sites.
///
/// Coverage-excluded: SwiftUI declarative body, not headlessly drivable
/// (ho-05 Decision 8) — same justification as every other Workshop View.
struct RevealableSecureField: View {
    let placeholder: String
    @Binding var text: String

    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .font(.system(.body, design: .monospaced))

            Button {
                isRevealed.toggle()
            } label: {
                Label(
                    isRevealed ? "Hide" : "Show",
                    systemImage: isRevealed ? "eye.slash" : "eye"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(isRevealed ? "Hide the value while typing" : "Show the value while typing")
        }
    }
}
