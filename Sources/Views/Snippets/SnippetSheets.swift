import SwiftUI
import SwiftData

struct SnippetFormSheet: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SnippetPackage.name) private var packages: [SnippetPackage]
    var snippet: Snippet?
    @State private var name = ""
    @State private var script = "#!/bin/bash\n\n"
    @State private var package: SnippetPackage?
    @State private var remark = Machine.defaultRemark()
    @State private var pickPackage = false

    var body: some View {
        FormSheet(title: snippet == nil ? "Create New Snippet" : "Edit Snippet", canSave: !name.isEmpty, onSave: save) {
            Section("Snippet Information") {
                TextField("Name", text: $name, prompt: Text("Name"))
                LabeledContent("Package") {
                    ChipButton(title: package?.name ?? "Select Package", icon: "shippingbox") { pickPackage = true }
                }
            }
            Section("Script") {
                TextEditor(text: $script).font(.system(.body, design: .monospaced)).frame(minHeight: 200)
            }
            Section("Remark") { TextField("Snippet Remark", text: $remark, axis: .vertical) }
        }
        .onAppear { if let snippet { name = snippet.name; script = snippet.script; package = snippet.package; remark = snippet.remark } }
        .sheet(isPresented: $pickPackage) {
            PickerSheet(title: "Select Package", items: packages, noneTitle: "No Package", onSelect: { package = $0 },
                        row: { ResourceCard(icon: "shippingbox", title: $0.name) },
                        matches: { $0.name.localizedCaseInsensitiveContains($1) })
        }
    }

    private func save() {
        let target = snippet ?? Snippet()
        target.name = name; target.script = script; target.package = package; target.remark = remark
        if snippet == nil { context.insert(target) }
    }
}

struct PackageFormSheet: View {
    @Environment(\.modelContext) private var context
    var package: SnippetPackage?
    @State private var name = ""
    @State private var remark = Machine.defaultRemark()

    var body: some View {
        FormSheet(title: package == nil ? "Create New Package" : "Edit Package", canSave: !name.isEmpty, onSave: save) {
            Section("Package Information") { TextField("Name", text: $name, prompt: Text("Name")) }
            Section("Remark") { TextField("Package Remark", text: $remark, axis: .vertical) }
        }
        .onAppear { if let package { name = package.name; remark = package.remark } }
    }

    private func save() {
        let target = package ?? SnippetPackage()
        target.name = name; target.remark = remark
        if package == nil { context.insert(target) }
    }
}
