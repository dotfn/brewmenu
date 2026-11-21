import SwiftUI

/// A system button style with more room either side of the label. The system's bordered styles fit
/// the bezel tight around the text, which in the macOS 26 toolbar's glass capsules ("Check Again")
/// and next to cards read as cramped.
///
/// It draws through the system style itself — the same bezel, Liquid Glass, tint, roles, focus ring
/// and disabled state — and only pads the label, so nothing else about the button changes.
struct RoomyButtonStyle<Base: PrimitiveButtonStyle>: PrimitiveButtonStyle {
    let base: Base
    @Environment(\.controlSize) private var controlSize

    /// Points added on each side, on top of the system's own inset.
    private var extraInset: CGFloat {
        switch controlSize {
        case .mini: 2
        case .small: 4
        case .large, .extraLarge: 8
        default: 6
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.padding(.horizontal, extraInset)
        }
        .buttonStyle(base)
    }
}

extension PrimitiveButtonStyle where Self == RoomyButtonStyle<BorderedButtonStyle> {
    /// `.bordered`, with more room either side of the label.
    static var roomyBordered: Self {
        RoomyButtonStyle(base: .bordered)
    }
}

extension PrimitiveButtonStyle where Self == RoomyButtonStyle<BorderedProminentButtonStyle> {
    /// `.borderedProminent`, with more room either side of the label.
    static var roomyBorderedProminent: Self {
        RoomyButtonStyle(base: .borderedProminent)
    }
}
