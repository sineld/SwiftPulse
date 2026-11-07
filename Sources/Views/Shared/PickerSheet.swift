import SwiftUI

/// Searchable "Select X" sub-sheet with optional "None" row and a "+" create action.
struct PickerSheet<Item: Identifiable & Hashable, Row: View>: View {
    let title: String
    let items: [Item]
    var noneTitle: String? = nil
    var onCreate: (() -> Void)? = nil
    let onSelect: (Item?) -> Void
    @ViewBuilder let row: (Item) -> Row
    let matches: (Item, String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(width: 200).findShortcut(textField: true)
            }
            .padding(14)
            ScrollView {
                VStack(spacing: 8) {
                    if let noneTitle {
                        Button { onSelect(nil); dismiss() } label: {
                            ResourceCard(icon: "xmark.circle", title: noneTitle)
                        }.buttonStyle(.plain)
                    }
                    let filtered = items.filter { query.isEmpty || matches($0, query) }
                    if filtered.isEmpty && noneTitle == nil {
                        ContentUnavailableView("Nothing to select", systemImage: "tray")
                            .frame(minHeight: 160)
                    }
                    ForEach(filtered) { item in
                        Button { onSelect(item); dismiss() } label: { row(item) }.buttonStyle(.plain)
                            .accessibilityLabel(String(describing: item.id))
                    }
                }
                .padding(.horizontal, 14)
            }
            Divider()
            HStack {
                if let onCreate { Button("Create", systemImage: "plus", action: onCreate).labelStyle(.iconOnly) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityLabel("Cancel")
            }
            .padding(12)
        }
        .frame(width: 460, height: 460)
        .background(Theme.pageBackground)
    }
}

/// Trailing "Select X ⌄" chip.
struct ChipButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
    }
}

/// Secure field with reveal toggle.
struct SecretField: View {
    let label: String
    @Binding var text: String
    @State private var reveal = false
    var body: some View {
        HStack {
            if reveal { TextField(label, text: $text, prompt: Text(label)) }
            else { SecureField(label, text: $text, prompt: Text(label)) }
            Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }
}
