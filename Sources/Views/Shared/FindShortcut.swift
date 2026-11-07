import SwiftUI

extension View {
    /// ⌘F puts the cursor in this view's search field: the one its `.searchable` adds, or, with
    /// `textField: true`, this view itself when it is a plain search `TextField` (in sheets).
    func findShortcut(textField: Bool = false) -> some View {
        modifier(FindShortcut(targetsTextField: textField))
    }
}

private struct FindShortcut: ViewModifier {
    let targetsTextField: Bool
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        Group {
            if targetsTextField {
                content.focused($focused)
            } else {
                content.searchFocused($focused)
            }
        }
        // An invisible button carries the shortcut; shortcuts only reach the key window, so a sheet's own
        // search field wins over the page behind it.
        .background {
            Button("Find") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}
