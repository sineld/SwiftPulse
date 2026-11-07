import Foundation
import LocalAuthentication

/// Gate for revealing secrets when "Require Authentication" is on (Touch ID / login password).
enum LocalAuth {
    static func authorize(reason: String) async -> Bool {
        guard UserDefaults.standard.bool(forKey: "requireAuthentication") else { return true }
        let context = LAContext()
        do { return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) }
        catch { return false }
    }
}
