import SwiftUI
import SwiftData

struct IdentitiesView: View {
    @Query private var identities: [Identity]
    @Environment(AppState.self) private var state
    @Environment(\.modelContext) private var context
    @State private var sheet: Sheet?
    @State private var pendingDelete: DeleteRequest?
    enum Sheet: Identifiable { case new, edit(Identity); var id: String { if case .edit(let i) = self { "e\(i.id)" } else { "new" } } }

    var body: some View {
        NavigationStack {
            Page(title: "Identities") {
                if identities.isEmpty {
                    EmptyStateView(message: "No identities available, create one now!", buttonTitle: "Create New Identity") { sheet = .new }
                } else {
                    CardGrid(items: identities.filtered(by: state)) { identity in
                        NavigationLink(value: identity) {
                            ResourceCard(icon: "person", title: identity.name, subtitle: identity.username)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { sheet = .edit(identity) }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                pendingDelete = .confirm(kind: "Identity", name: identity.name,
                                                         note: "Machines that use it will need a new identity.") {
                                    KeychainService.delete(identity.passwordKey)
                                    context.delete(identity)
                                }
                            }
                        }
                    }
                }
            }
            .navigationDestination(for: Identity.self) { IdentityDetailView(identity: $0) }
            .searchable(text: Bindable(state).searchText)
            .findShortcut()
        }
        .deleteConfirmation($pendingDelete)
        .toolbar { ResourceToolbar { sheet = .new } }
        .sheet(item: $sheet) { which in
            switch which {
            case .new: IdentityFormSheet()
            case .edit(let i): IdentityFormSheet(identity: i)
            }
        }
    }
}
