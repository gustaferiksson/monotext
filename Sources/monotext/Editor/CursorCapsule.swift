import SwiftUI

struct CursorCapsule: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let text: String

    var body: some View {
        let label = Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        if reduceTransparency {
            label
                .background(.background, in: Capsule())
                .overlay { Capsule().strokeBorder(.separator, lineWidth: 1) }
        } else {
            label.glassEffect(.regular, in: Capsule())
        }
    }
}
