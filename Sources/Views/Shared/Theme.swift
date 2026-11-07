import SwiftUI

enum Theme {
    static let pageBackground = Color(nsColor: .windowBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let cardRadius: CGFloat = 12
    static let pagePadding: CGFloat = 20
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(.quaternary.opacity(0.5)))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}
