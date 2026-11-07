import SwiftUI
import SwiftData

struct SnippetsView: View {
    @Query private var packages: [SnippetPackage]
    @Query private var snippets: [Snippet]
    @Environment(AppState.self) private var state
    @Environment(\.modelContext) private var context
    @State private var sheet: Sheet?
    @State private var pendingDelete: DeleteRequest?
    enum Sheet: Identifiable {
        case newSnippet, newPackage, editSnippet(Snippet), editPackage(SnippetPackage), run(Snippet)
        var id: String {
            switch self {
            case .newSnippet: "ns"; case .newPackage: "np"
            case .editSnippet(let s): "s\(s.id)"; case .editPackage(let p): "p\(p.id)"; case .run(let s): "r\(s.id)"
            }
        }
    }

    var body: some View {
        Page(title: "Snippets") {
            SectionTitle(text: "Packages")
            if packages.isEmpty {
                EmptyStateView(message: "No snippet packages available, create one now!", buttonTitle: "Create New Snippet Package") { sheet = .newPackage }
            } else {
                CardGrid(items: packages.filtered(by: state)) { package in
                    ResourceCard(icon: "shippingbox", title: package.name, subtitle: "\(package.snippets?.count ?? 0) Snippets")
                        .onTapGesture { sheet = .editPackage(package) }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { sheet = .editPackage(package) }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                pendingDelete = .confirm(kind: "Package", name: package.name,
                                                         note: "Its snippets are kept.") { context.delete(package) }
                            }
                        }
                }
            }
            SectionTitle(text: "Snippets")
            if snippets.isEmpty {
                EmptyStateView(message: "No snippets available, create one now!", buttonTitle: "Create New Snippet") { sheet = .newSnippet }
            } else {
                CardGrid(items: snippets.filtered(by: state)) { snippet in
                    ResourceCard(icon: "curlybraces", title: snippet.name, subtitle: snippet.package?.name) {
                        Button("Run", systemImage: "play.fill") { sheet = .run(snippet) }.buttonStyle(.borderless)
                    }
                        .onTapGesture { sheet = .editSnippet(snippet) }
                        .contextMenu {
                            Button("Run", systemImage: "play.fill") { sheet = .run(snippet) }
                            Button("Edit", systemImage: "pencil") { sheet = .editSnippet(snippet) }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                pendingDelete = .confirm(kind: "Snippet", name: snippet.name) { context.delete(snippet) }
                            }
                        }
                }
            }
        }
        .searchable(text: Bindable(state).searchText)
        .findShortcut()
        .deleteConfirmation($pendingDelete)
        .toolbar {
            ResourceToolbar()
            ToolbarItem {
                Menu {
                    Button("Create New Snippet", systemImage: "curlybraces") { sheet = .newSnippet }
                    Divider()
                    Button("Create New Package", systemImage: "shippingbox") { sheet = .newPackage }
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .newSnippet: SnippetFormSheet()
            case .newPackage: PackageFormSheet()
            case .editSnippet(let s): SnippetFormSheet(snippet: s)
            case .editPackage(let p): PackageFormSheet(package: p)
            case .run(let s): SnippetRunSheet(snippet: s)
            }
        }
    }
}
