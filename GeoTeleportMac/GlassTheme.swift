import SwiftUI

extension View {
    func glassPanel(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
    }

    func glassCapsule(tint: Color) -> some View {
        Capsule()
            .fill(.regularMaterial)
            .overlay(
                Capsule().fill(tint.opacity(0.12))
            )
            .overlay(
                Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1)
            )
    }
}
