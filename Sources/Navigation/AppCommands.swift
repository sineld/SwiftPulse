import SwiftUI

struct AppCommands: Commands {
    var body: some Commands {
        SidebarCommands()
        CommandGroup(replacing: .help) {
            Link("SwiftPulse Documentation", destination: URL(string: "https://github.com/sineld/SwiftPulse")!)
        }
    }
}
