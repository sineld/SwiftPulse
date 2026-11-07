import Foundation

protocol Searchable {
    var searchTerms: [String] { get }
    var sortName: String { get }
    var sortDate: Date { get }
}

extension Array where Element: Searchable {
    func filtered(by state: AppState) -> [Element] {
        let q = state.searchText.trimmingCharacters(in: .whitespaces)
        let hits = q.isEmpty ? self : filter { $0.searchTerms.contains { $0.localizedCaseInsensitiveContains(q) } }
        return state.sortOrder == .name
            ? hits.sorted { $0.sortName.localizedCaseInsensitiveCompare($1.sortName) == .orderedAscending }
            : hits.sorted { $0.sortDate > $1.sortDate }
    }
}

extension Machine: Searchable {
    var searchTerms: [String] { [name, host] + tags }
    var sortName: String { displayName }
    var sortDate: Date { createdAt }
}
extension Identity: Searchable {
    var searchTerms: [String] { [name, username] }
    var sortName: String { name }
    var sortDate: Date { createdAt }
}
extension SSHKey: Searchable {
    var searchTerms: [String] { [name, keyType.title] }
    var sortName: String { name }
    var sortDate: Date { createdAt }
}
extension Proxy: Searchable {
    var searchTerms: [String] { [name, host] }
    var sortName: String { name }
    var sortDate: Date { createdAt }
}
extension Snippet: Searchable {
    var searchTerms: [String] { [name, script] }
    var sortName: String { name }
    var sortDate: Date { createdAt }
}
extension SnippetPackage: Searchable {
    var searchTerms: [String] { [name] }
    var sortName: String { name }
    var sortDate: Date { createdAt }
}
extension PortForwardingRule: Searchable {
    var searchTerms: [String] { [name, targetHost] }
    var sortName: String { name }
    var sortDate: Date { createdAt }
}
