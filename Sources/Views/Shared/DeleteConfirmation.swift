import SwiftUI

/// One pending destructive action, shown as a Cancel / Delete alert.
struct DeleteRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirmTitle = "Delete"
    var action: () -> Void

    /// Standard wording: "Delete Machine" · "Are you sure you want to delete the machine “X”? … This action cannot be undone."
    static func confirm(kind: String, name: String, note: String? = nil,
                        confirmTitle: String = "Delete", action: @escaping () -> Void) -> DeleteRequest {
        var message = "Are you sure you want to delete the \(kind.lowercased()) “\(name)”?"
        if let note, !note.isEmpty { message += " " + note }
        message += " This action cannot be undone."
        return DeleteRequest(title: "Delete \(kind)", message: message, confirmTitle: confirmTitle, action: action)
    }

    /// For actions that are not literally a delete (prune, forget, replace, bring down).
    static func ask(title: String, message: String, confirmTitle: String, action: @escaping () -> Void) -> DeleteRequest {
        DeleteRequest(title: title, message: message + " This action cannot be undone.",
                      confirmTitle: confirmTitle, action: action)
    }
}

private struct DeleteConfirmationModifier: ViewModifier {
    @Binding var request: DeleteRequest?

    func body(content: Content) -> some View {
        content.alert(request?.title ?? "", isPresented: isPresented, presenting: request) { pending in
            Button("Cancel", role: .cancel) {}
            Button(pending.confirmTitle, role: .destructive) { pending.action() }
        } message: { pending in
            Text(pending.message)
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { request != nil }, set: { presented in if !presented { request = nil } })
    }
}

extension View {
    /// Routes a screen's destructive actions through one confirmation alert.
    func deleteConfirmation(_ request: Binding<DeleteRequest?>) -> some View {
        modifier(DeleteConfirmationModifier(request: request))
    }
}
