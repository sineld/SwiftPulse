import Testing
@testable import SwiftPulse

struct DeleteConfirmationTests {

    @Test func wordingMatchesTheReferenceDialog() {
        var ran = false
        let request = DeleteRequest.confirm(kind: "Machine", name: "Web Server - 203.0.113.10 Copy",
                                            note: "Active sessions for this machine will be stopped.") { ran = true }
        #expect(request.title == "Delete Machine")
        #expect(request.message == "Are you sure you want to delete the machine “Web Server - 203.0.113.10 Copy”? Active sessions for this machine will be stopped. This action cannot be undone.")
        #expect(request.confirmTitle == "Delete")
        #expect(!ran)              // nothing happens until the alert's button is pressed
        request.action()
        #expect(ran)
    }

    @Test func noteIsOptionalAndKindIsLowercasedInTheSentence() {
        let request = DeleteRequest.confirm(kind: "SSH Key", name: "work-laptop") {}
        #expect(request.title == "Delete SSH Key")
        #expect(request.message == "Are you sure you want to delete the ssh key “work-laptop”? This action cannot be undone.")
    }

    @Test func askKeepsItsOwnTitleAndButton() {
        let request = DeleteRequest.ask(title: "Prune System",
                                        message: "Docker removes stopped containers on Production.",
                                        confirmTitle: "Prune") {}
        #expect(request.title == "Prune System")
        #expect(request.message == "Docker removes stopped containers on Production. This action cannot be undone.")
        #expect(request.confirmTitle == "Prune")
    }
}
