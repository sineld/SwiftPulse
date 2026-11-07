import SwiftUI

/// Grid/List + sort menu and a plain Add button, shared by resource pages.
struct ResourceToolbar: ToolbarContent {
    @Environment(AppState.self) private var state
    var showViewMenu = true
    var add: (() -> Void)? = nil

    var body: some ToolbarContent {
        @Bindable var state = state
        if showViewMenu {
            ToolbarItem {
                Menu {
                    Picker("Display Style", selection: $state.displayStyle) {
                        Label("Grid", systemImage: "square.grid.2x2").tag(DisplayStyle.grid)
                        Label("List", systemImage: "list.bullet").tag(DisplayStyle.list)
                    }
                    Picker("Sort", selection: $state.sortOrder) {
                        Label("Name", systemImage: "textformat").tag(SortOrder.name)
                        Label("Date", systemImage: "calendar").tag(SortOrder.date)
                    }
                    Toggle("Hide Host", systemImage: "eye.slash", isOn: $state.hideHost)
                } label: {
                    Image(systemName: state.displayStyle == .grid ? "square.grid.2x2" : "list.bullet")
                }
            }
        }
        if let add {
            ToolbarItem { Button("Add", systemImage: "plus", action: add) }
        }
    }
}

/// Lays out cards in the selected display style.
struct CardGrid<Item: Identifiable, Card: View>: View {
    let items: [Item]
    @ViewBuilder let card: (Item) -> Card
    @Environment(AppState.self) private var state

    var body: some View {
        if state.displayStyle == .grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 420), spacing: 14)], spacing: 14) {
                ForEach(items) { card($0) }
            }
        } else {
            LazyVStack(spacing: 10) { ForEach(items) { card($0) } }
        }
    }
}
