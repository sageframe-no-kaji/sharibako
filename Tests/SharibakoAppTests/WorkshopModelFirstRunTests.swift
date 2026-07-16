import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// Tests for the first-run wizard's prereq and key pages (ho-06.3),
/// declared in `WorkshopModel+FirstRun.swift`.
///
/// Split across three files by page group — `WorkshopModelFirstRunBackupRootTests.swift`
/// (backup/root/remote) and `WorkshopModelFirstRunCompletionTests.swift`
/// (navigation/`completeFirstRun`) — purely to stay under SwiftLint's
/// `type_body_length` ceiling; shared fixtures live in `FirstRunTestSupport`
/// (`AppTestSupport.swift`).
///
/// Every Keychain-touching intent takes an injected `GUIKeychainStore`
/// (`FakeKeychainStore`, `AppTestSupport.swift`) so nothing here reaches the
/// real Keychain (Do Not §4).
@MainActor
@Suite("WorkshopModel+FirstRun")
struct WorkshopModelFirstRunTests {
    // MARK: - Prereq page

    @Test("checkFirstRunPrerequisites reflects the injected probe; advance blocks until true")
    func prereqGatesAdvance() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)

            model.checkFirstRunPrerequisites { false }
            #expect(model.firstRun.prerequisitesOK == false)
            #expect(model.firstRunCanContinue == false)
            model.advanceFromPrereq()
            #expect(model.firstRun.page == .prereq)

            model.checkFirstRunPrerequisites { true }
            #expect(model.firstRun.prerequisitesOK == true)
            #expect(model.firstRunCanContinue == true)
            model.advanceFirstRunPage()
            #expect(model.firstRun.page == .key)
        }
    }

    // MARK: - Key page

    @Test("checkExistingKeychainKey sets existingKeyFound when the store reports one")
    func checkExistingKeyFound() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)
            let store = FakeKeychainStore()
            store.existsResult = true

            model.checkExistingKeychainKey(store: store)

            #expect(model.firstRun.keyMode == .existingKeyFound)
        }
    }

    @Test("checkExistingKeychainKey leaves notChosen when the store reports none")
    func checkExistingKeyAbsent() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)
            let store = FakeKeychainStore()
            store.existsResult = false

            model.checkExistingKeychainKey(store: store)

            #expect(model.firstRun.keyMode == .notChosen)
        }
    }

    @Test("checkExistingKeychainKey surfaces the store's error")
    func checkExistingKeyPropagatesError() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)
            let store = FakeKeychainStore()
            store.existsError = AgeKeyAccessError.keychainLoadFailed(osStatus: -1)

            model.checkExistingKeychainKey(store: store)

            #expect(model.firstRun.errorMessage != nil)
            #expect(model.firstRun.keyMode == .notChosen)
        }
    }

    @Test("generateFirstRunKey stores the key, stages the backup page, and advances")
    func generateAdvancesToBackup() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)
            let store = FakeKeychainStore()

            model.generateFirstRunKey(store: store)

            #expect(model.firstRun.keyMode == .generated)
            #expect(model.firstRun.page == .backup)
            #expect(model.firstRun.pendingBackup?.recipient.hasPrefix("age1") == true)
            #expect(store.storedContents != nil)
            #expect(model.firstRun.errorMessage == nil)
        }
    }

    @Test("generateFirstRunKey is a no-op once an existing key was found (never a second key)")
    func generateNoOpWhenExistingKeyFound() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)
            model.firstRun.keyMode = .existingKeyFound
            let store = FakeKeychainStore()

            model.generateFirstRunKey(store: store)

            #expect(model.firstRun.pendingBackup == nil)
            #expect(store.storedContents == nil)
            #expect(model.firstRun.page == .prereq)
        }
    }

    @Test("generateFirstRunKey surfaces a Keychain store failure")
    func generateSurfacesStoreFailure() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)
            let store = FakeKeychainStore()
            store.storeError = AgeKeyAccessError.keychainStoreFailed(osStatus: -1)

            model.generateFirstRunKey(store: store)

            #expect(model.firstRun.errorMessage != nil)
            #expect(model.firstRun.page == .prereq)
        }
    }

    @Test("importFirstRunKey validates, stores, and skips straight to the root page")
    func importAdvancesToRoot() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            try AppAgeKeyFixture.withEphemeralKey { fixture in
                let model = FirstRunTestSupport.noVaultModel(home: home)
                let store = FakeKeychainStore()

                model.importFirstRunKey(from: fixture.privateKeyURL, store: store)

                #expect(model.firstRun.keyMode == .imported)
                #expect(model.firstRun.page == .root)
                #expect(store.storedContents != nil)
                #expect(model.firstRun.pendingBackup == nil)
            }
        }
    }

    @Test("importFirstRunKey surfaces validation failure for a non-identity file")
    func importSurfacesInvalidFile() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let bogus = home.appendingPathComponent("not-a-key.txt")
            try "nope".write(to: bogus, atomically: true, encoding: .utf8)
            let model = FirstRunTestSupport.noVaultModel(home: home)
            model.firstRun.page = .key
            let store = FakeKeychainStore()

            model.importFirstRunKey(from: bogus, store: store)

            #expect(model.firstRun.errorMessage != nil)
            #expect(model.firstRun.keyMode == .notChosen)
            #expect(model.firstRun.page == .key)  // a failed import never advances
        }
    }

    @Test("importFirstRunKey is a no-op once an existing key was found")
    func importNoOpWhenExistingKeyFound() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            try AppAgeKeyFixture.withEphemeralKey { fixture in
                let model = FirstRunTestSupport.noVaultModel(home: home)
                model.firstRun.keyMode = .existingKeyFound
                let store = FakeKeychainStore()

                model.importFirstRunKey(from: fixture.privateKeyURL, store: store)

                #expect(store.storedContents == nil)
                #expect(model.firstRun.page == .prereq)
            }
        }
    }

    @Test("advanceFromKeyPage only advances on existingKeyFound")
    func advanceFromKeyPageGuards() throws {
        try WorkshopTestSupport.withTempDirectory { home in
            let model = FirstRunTestSupport.noVaultModel(home: home)
            model.firstRun.page = .key

            model.advanceFromKeyPage()
            #expect(model.firstRun.page == .key)

            model.firstRun.keyMode = .existingKeyFound
            model.advanceFirstRunPage()
            #expect(model.firstRun.page == .root)
        }
    }
}
