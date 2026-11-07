import SwiftUI
import SwiftData

struct ProxiesView: View {
    @Query private var proxies: [Proxy]
    @Environment(AppState.self) private var state
    @Environment(\.modelContext) private var context
    @State private var sheet: Sheet?
    @State private var pendingDelete: DeleteRequest?
    enum Sheet: Identifiable { case new, edit(Proxy); var id: String { if case .edit(let p) = self { "e\(p.id)" } else { "new" } } }

    var body: some View {
        Page(title: "Proxy") {
            if proxies.isEmpty {
                EmptyStateView(message: "No proxy profiles available, create one now!", buttonTitle: "Create New Proxy Profile") { sheet = .new }
            } else {
                CardGrid(items: proxies.filtered(by: state)) { proxy in
                    ResourceCard(icon: "globe", title: proxy.name, subtitle: "\(proxy.kind.title) · \(proxy.host):\(proxy.port)")
                        .onTapGesture { sheet = .edit(proxy) }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { sheet = .edit(proxy) }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                pendingDelete = .confirm(kind: "Proxy", name: proxy.name,
                                                         note: "Machines and rules that use it fall back to a direct connection.") {
                                    KeychainService.delete(proxy.passwordKey)
                                    context.delete(proxy)
                                }
                            }
                        }
                }
            }
        }
        .searchable(text: Bindable(state).searchText)
        .findShortcut()
        .deleteConfirmation($pendingDelete)
        .toolbar { ResourceToolbar { sheet = .new } }
        .sheet(item: $sheet) { which in
            switch which {
            case .new: ProxyFormSheet()
            case .edit(let p): ProxyFormSheet(proxy: p)
            }
        }
    }
}
