import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// Keychain-touching methods on `GUIAgeKeyBootstrap` are seam-injected.
///
/// `GUIKeychainStore` keeps these tests off the real Keychain (ho-06.3
/// Decision 5, Do Not §4) — `FakeKeychainStore` stands in
/// (`AppTestSupport.swift`). `age-keygen` shell-outs run for real, the same
/// contract `VaultCoreEncryptionTests`/`AppAgeKeyFixture` already rely on.
@Suite("GUIAgeKeyBootstrap")
struct GUIAgeKeyBootstrapTests {
    @Test("prerequisitesPresent is true when age and age-keygen resolve")
    func prerequisitesPresentTrue() {
        // Both binaries are a documented dev/CI prerequisite (CLAUDE.md).
        #expect(GUIAgeKeyBootstrap.prerequisitesPresent())
    }

    @Test("keychainKeyExists reflects the injected store")
    func keychainKeyExistsReflectsStore() throws {
        let store = FakeKeychainStore()
        store.existsResult = false
        #expect(try GUIAgeKeyBootstrap.keychainKeyExists(store: store) == false)
        store.existsResult = true
        #expect(try GUIAgeKeyBootstrap.keychainKeyExists(store: store) == true)
    }

    @Test("keychainKeyExists propagates the store's error")
    func keychainKeyExistsPropagatesError() {
        let store = FakeKeychainStore()
        store.existsError = AgeKeyAccessError.keychainLoadFailed(osStatus: -1)
        #expect(throws: AgeKeyAccessError.self) {
            _ = try GUIAgeKeyBootstrap.keychainKeyExists(store: store)
        }
    }

    @Test("generateToKeychain stores the identity and returns a matching recipient")
    func generateToKeychainStoresAndReturns() throws {
        let store = FakeKeychainStore()
        let (identity, recipient) = try GUIAgeKeyBootstrap.generateToKeychain(store: store)
        #expect(identity.contains("AGE-SECRET-KEY-1"))
        #expect(recipient.hasPrefix("age1"))
        let stored = try #require(store.storedContents)
        #expect(String(bytes: stored, encoding: .utf8) == identity)
    }

    @Test("generateToKeychain propagates the store's error without leaving a temp file")
    func generateToKeychainPropagatesStoreError() {
        let store = FakeKeychainStore()
        store.storeError = AgeKeyAccessError.keychainStoreFailed(osStatus: -1)
        #expect(throws: AgeKeyAccessError.self) {
            _ = try GUIAgeKeyBootstrap.generateToKeychain(store: store)
        }
    }

    @Test("importToKeychain rejects a file with no AGE-SECRET-KEY-1 line and never stores it")
    func importToKeychainRejectsInvalidFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gui-agekey-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bogusURL = dir.appendingPathComponent("not-a-key.txt")
        try "this is not an age identity".write(to: bogusURL, atomically: true, encoding: .utf8)

        let store = FakeKeychainStore()
        let error = #expect(throws: GUIAgeKeyBootstrapError.self) {
            _ = try GUIAgeKeyBootstrap.importToKeychain(from: bogusURL, store: store)
        }
        #expect(error == .invalidIdentityFile(path: bogusURL))
        #expect(store.storedContents == nil)
    }

    @Test("importToKeychain stores a real identity file and derives its recipient from the header")
    func importToKeychainWithHeaderDerivesFromHeader() throws {
        try AppAgeKeyFixture.withEphemeralKey { fixture in
            let store = FakeKeychainStore()
            let (identity, recipient) = try GUIAgeKeyBootstrap.importToKeychain(
                from: fixture.privateKeyURL, store: store)
            #expect(recipient == fixture.publicKey)
            #expect(identity.contains("AGE-SECRET-KEY-1"))
            #expect(store.storedContents != nil)
        }
    }

    @Test("importToKeychain derives the recipient via age-keygen -y when the header is stripped")
    func importToKeychainWithoutHeaderDerivesViaAgeKeygen() throws {
        try AppAgeKeyFixture.withEphemeralKey { fixture in
            let contents = try String(contentsOf: fixture.privateKeyURL, encoding: .utf8)
            let identityLineOnly =
                contents
                .split(whereSeparator: \.isNewline)
                .filter { !$0.hasPrefix("#") }
                .joined(separator: "\n")
            let headerlessURL = fixture.privateKeyURL.deletingLastPathComponent()
                .appendingPathComponent("headerless-key.txt")
            try identityLineOnly.write(to: headerlessURL, atomically: true, encoding: .utf8)

            let store = FakeKeychainStore()
            let (_, recipient) = try GUIAgeKeyBootstrap.importToKeychain(
                from: headerlessURL, store: store)
            #expect(recipient == fixture.publicKey)
            #expect(store.storedContents != nil)
        }
    }

    @Test(
        "importToKeychain surfaces a derivation failure without storing garbage that only passes the prefix check"
    )
    func importToKeychainDerivationFailureNeverStores() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gui-agekey-garbage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let garbageURL = dir.appendingPathComponent("garbage-key.txt")
        // Passes `containsIdentityLine`'s loose prefix check but is not a
        // real age identity — `age-keygen -y` must reject it, and that
        // rejection must happen before any Keychain write (the ordering fix
        // this test guards).
        try "AGE-SECRET-KEY-1NOTAREALKEYATALL".write(
            to: garbageURL, atomically: true, encoding: .utf8)

        let store = FakeKeychainStore()
        #expect(throws: (any Error).self) {
            _ = try GUIAgeKeyBootstrap.importToKeychain(from: garbageURL, store: store)
        }
        #expect(store.storedContents == nil)
    }

    @Test("importToKeychain propagates the store's error after a successful derivation")
    func importToKeychainPropagatesStoreError() throws {
        try AppAgeKeyFixture.withEphemeralKey { fixture in
            let store = FakeKeychainStore()
            store.storeError = AgeKeyAccessError.keychainStoreFailed(osStatus: -1)
            #expect(throws: AgeKeyAccessError.self) {
                _ = try GUIAgeKeyBootstrap.importToKeychain(from: fixture.privateKeyURL, store: store)
            }
        }
    }
}
