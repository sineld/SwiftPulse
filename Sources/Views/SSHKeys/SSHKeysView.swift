import SwiftUI
import SwiftData

struct SSHKeysView: View {
    @Query private var keys: [SSHKey]
    @Environment(AppState.self) private var state
    @Environment(\.modelContext) private var context
    @State private var sheet: Sheet?
    @State private var pendingDelete: DeleteRequest?
    enum Sheet: Identifiable {
        case generate, importText(String), edit(SSHKey)
        var id: String {
            switch self {
            case .generate: "generate"
            case .importText: "import"
            case .edit(let key): "e\(key.id)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Page(title: "SSH Key") {
                if keys.isEmpty {
                    EmptyStateView(message: "No SSH keys available, create one now!", buttonTitle: "Generate New SSH Key") { sheet = .generate }
                } else {
                    CardGrid(items: keys.filtered(by: state)) { key in
                        NavigationLink(value: key) {
                            ResourceCard(icon: "key", title: key.name, badges: [key.publicKey.isEmpty ? "Unknown" : key.keyType.title])
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { sheet = .edit(key) }
                            Button("Copy Public Key", systemImage: "doc.on.doc") {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key.publicKey, forType: .string)
                            }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                pendingDelete = .confirm(kind: "SSH Key", name: key.name,
                                                         note: "Its private key is removed from this Mac.") {
                                    KeychainService.delete(key.privateKeyKey)
                                    KeychainService.delete(key.passphraseKey)
                                    context.delete(key)
                                }
                            }
                        }
                    }
                }
            }
            .navigationDestination(for: SSHKey.self) { SSHKeyDetailView(key: $0) }
            .searchable(text: Bindable(state).searchText)
            .findShortcut()
        }
        .deleteConfirmation($pendingDelete)
        .toolbar {
            ResourceToolbar()
            ToolbarItem {
                Menu {
                    Button("Generate New SSH Key", systemImage: "key") { sheet = .generate }
                    Divider()
                    Button("Import from Pasteboard", systemImage: "doc.on.clipboard") {
                        sheet = .importText(NSPasteboard.general.string(forType: .string) ?? "")
                    }
                    Button("Import from File", systemImage: "doc") { sheet = .importText("") }
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .generate: SSHKeyGenerateSheet()
            case .importText(let text): SSHKeyImportSheet(initialPrivate: text)
            case .edit(let key): SSHKeyImportSheet(key: key)
            }
        }
    }
}
