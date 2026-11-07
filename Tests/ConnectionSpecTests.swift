import Testing
import Foundation
import SwiftData
@testable import SwiftPulse

@MainActor
struct ConnectionSpecTests {
    private func makeContext() -> ModelContext { ModelContext(AppSchema.container(inMemory: true)) }

    @Test func identityWithKeyProducesSpecWithoutTouchingTheStore() throws {
        let ctx = makeContext()
        let key = SSHKey(name: "k", keyType: .ed25519, publicKey: "ssh-ed25519 AAAA")
        ctx.insert(key)
        KeychainService.set("PEM", for: key.privateKeyKey); defer { KeychainService.delete(key.privateKeyKey) }
        let identity = Identity(name: "oci", username: "ubuntu"); identity.sshKey = key
        ctx.insert(identity)
        try ctx.save()

        let fields = ConnectionSpec.Fields(host: " 10.0.0.1 ", port: 2198, authMethod: .identity, identity: identity,
                                           username: "", sshKey: nil, proxy: nil, jumpHostIDs: [])
        let spec = try ConnectionSpec.make(fields, in: ctx)
        #expect(spec.host == "10.0.0.1")
        #expect(spec.port == 2198)
        #expect(spec.username == "ubuntu")
        #expect(spec.privateKey == "PEM")
        #expect(spec.password == nil)
        // Regression: "Test Connection" used to insert a phantom Machine for every attempt.
        #expect(try ctx.fetchCount(FetchDescriptor<Machine>()) == 0)
    }

    @Test func missingPrivateKeyIsNamed() throws {
        let ctx = makeContext()
        let key = SSHKey(name: "work-laptop", keyType: .rsa, publicKey: "ssh-rsa AAAA")
        ctx.insert(key)
        KeychainService.delete(key.privateKeyKey)
        let identity = Identity(name: "oci", username: "ubuntu"); identity.sshKey = key
        ctx.insert(identity)
        let fields = ConnectionSpec.Fields(host: "h", port: 22, authMethod: .identity, identity: identity, username: "", sshKey: nil, proxy: nil, jumpHostIDs: [])
        #expect(throws: ConnectionSpec.SpecError.missingPrivateKey("work-laptop")) { try ConnectionSpec.make(fields, in: ctx) }
    }

    @Test func identityWithoutAnyCredentialFails() throws {
        let ctx = makeContext()
        let identity = Identity(name: "empty", username: "u"); ctx.insert(identity)
        let fields = ConnectionSpec.Fields(host: "h", port: 22, authMethod: .identity, identity: identity, username: "", sshKey: nil, proxy: nil, jumpHostIDs: [])
        #expect(throws: ConnectionSpec.SpecError.identityWithoutCredentials("empty")) { try ConnectionSpec.make(fields, in: ctx) }
    }

    @Test func formPasswordWinsOverStoredOne() throws {
        let ctx = makeContext()
        let fields = ConnectionSpec.Fields(host: "h", port: 22, authMethod: .passwordOrKey, identity: nil, username: "root",
                                           sshKey: nil, proxy: nil, jumpHostIDs: [], passwordKey: "machine.password.none", enteredPassword: "typed")
        let spec = try ConnectionSpec.make(fields, in: ctx)
        #expect(spec.password == "typed")
        #expect(spec.username == "root")
    }

    @Test func blankHostAndMissingIdentityAreReported() {
        let ctx = makeContext()
        let noHost = ConnectionSpec.Fields(host: "  ", port: 22, authMethod: .identity, identity: nil, username: "", sshKey: nil, proxy: nil, jumpHostIDs: [])
        #expect(throws: ConnectionSpec.SpecError.noHost) { try ConnectionSpec.make(noHost, in: ctx) }
        let noIdentity = ConnectionSpec.Fields(host: "h", port: 22, authMethod: .identity, identity: nil, username: "", sshKey: nil, proxy: nil, jumpHostIDs: [])
        #expect(throws: ConnectionSpec.SpecError.noIdentity) { try ConnectionSpec.make(noIdentity, in: ctx) }
    }

    @Test func jumpHostsAreResolvedInOrder() throws {
        let ctx = makeContext()
        let identity = Identity(name: "i", username: "u"); identity.hasPassword = true; ctx.insert(identity)
        KeychainService.set("pw", for: identity.passwordKey); defer { KeychainService.delete(identity.passwordKey) }
        let hop = Machine(name: "bastion", host: "bastion.example", port: 22); hop.identity = identity; ctx.insert(hop)
        let target = Machine(name: "db", host: "10.0.0.9", port: 22); target.identity = identity
        target.useJumpHost = true; target.jumpHostIDs = [hop.id]; ctx.insert(target)
        try ctx.save()
        let spec = try ConnectionSpec.make(for: target, in: ctx)
        #expect(spec.jumpHosts.map(\.host) == ["bastion.example"])
        #expect(spec.jumpHosts[0].password == "pw")
    }
}
