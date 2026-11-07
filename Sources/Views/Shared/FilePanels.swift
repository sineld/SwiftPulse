import AppKit

/// AppKit open/save panels instead of SwiftUI's `fileImporter`/`fileExporter`.
///
/// SwiftUI's importer traps inside its own completion handler when the picked file has no registered
/// content type (a `.spvault` file, an extensionless `id_rsa`), which crashed the app on import.
/// The app is not sandboxed, so the panels' URLs are usable directly, with no security scope dance.
@MainActor
enum FilePanel {
    static func openFile(title: String, message: String? = nil, directory: URL? = nil,
                         allowsMultiple: Bool = false, prompt: String = "Open") -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        if let message { panel.message = message }
        panel.prompt = prompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = allowsMultiple
        panel.showsHiddenFiles = true          // ~/.ssh/id_rsa lives in a hidden folder
        panel.treatsFilePackagesAsDirectories = true
        if let directory { panel.directoryURL = directory }
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    static func openFilesOrFolders(title: String, message: String? = nil, prompt: String = "Upload") -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        if let message { panel.message = message }
        panel.prompt = prompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    static func openDirectory(title: String, message: String? = nil, directory: URL? = nil,
                              prompt: String = "Choose") -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        if let message { panel.message = message }
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let directory { panel.directoryURL = directory }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func saveFile(title: String, suggestedName: String, directory: URL? = nil,
                         prompt: String = "Save") -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.prompt = prompt
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        if let directory { panel.directoryURL = directory }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
