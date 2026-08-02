import SwiftUI

struct StatCard: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = .accentColor
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                // Plain monochrome icon, no filled circle behind it — matches the
                // restrained, single-accent icon treatment already used everywhere else
                // on this screen (InstallPackCard, RecommendedCard both use a bare
                // `.tint`-colored symbol). Four cards each in their own saturated color
                // circle read as a toy-ish rainbow next to that; this makes the row
                // consistent with its own screen instead of the odd one out.
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)

                Text(verbatim: value)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.primary)
                    // Proportional (not tabular/monospaced) figures read correctly at
                    // display sizes — tabular-nums is for aligned table/axis columns.
                    .contentTransition(.numericText())

                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: CardCornerRadius.large)
                    .fill(.quaternary.opacity(isHovering ? 0.6 : 0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CardCornerRadius.large)
                    .strokeBorder(tint.opacity(isHovering ? 0.25 : 0), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 && isEnabled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isEnabled ? L("Opens this section") : "")
    }
}
