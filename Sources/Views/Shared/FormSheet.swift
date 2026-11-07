import SwiftUI

/// Standard modal form: title bar, scrollable grouped Form, Cancel / Save footer.
struct FormSheet<Content: View>: View {
    let title: String
    var saveTitle = "Save"
    var canSave = true
    let onSave: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityLabel("Cancel")
                Button(saveTitle) { onSave(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(saveTitle)
                    .disabled(!canSave)
            }
            .padding(14)
        }
        .frame(width: 560, height: 600)
    }
}

/// Row with trailing label text used for read-only detail screens.
struct DetailRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
