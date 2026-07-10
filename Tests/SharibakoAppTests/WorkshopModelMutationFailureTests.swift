import Foundation
import Testing

@testable import Sharibako
@testable import SharibakoCore

/// Failure-path coverage for `WorkshopModel+Mutations.swift`: the age-key-load
/// guard and the `VaultCore` catch block on each of the four secret-mutating
/// intents (`addSecret`, `addSharedEntry`, `editValue`, `editNotes`).
///
/// `addScope` needs no age key (it never encrypts) and its failure path is
/// already covered by `WorkshopModelMutationTests.addScopeDuplicate`. Split
/// into its own file/suite because these intents moved out of
/// `WorkshopModel.swift` in ho-06.1 AT-02 (the `WorkshopModel+Mutations.swift`
/// split) and their failure branches were previously diluted by the rest of
/// that larger file's coverage — worth naming explicitly here rather than
/// leaving them as a percentage-point gap.
///
/// Age-key-load failure is triggered deterministically by pointing
/// `SHARIBAKO_AGE_KEY` at a path that does not exist:
/// `GUIFileAgeKeyProvider.loadIdentity` throws `keyFileNotFound` before any
/// vault I/O happens (`Sources/Sharibako/Support/GUIAgeKeyProvider.swift`).
@MainActor
@Suite("WorkshopModel Mutation Failures")
struct WorkshopModelMutationFailureTests {
    @Test("addSecret surfaces 'Could not load age key' when the dev key file is missing")
    func addSecretMissingAgeKey() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let model = WorkshopModel(
                environment: [
                    "SHARIBAKO_VAULT": vault.path,
                    "SHARIBAKO_AGE_KEY": "/nonexistent/dev-key.txt",
                ],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.addSecret(key: "TOKEN", value: "v", notes: nil, inScope: "kanyo-dev")
            #expect(model.errorMessage?.hasPrefix("Could not load age key") == true)
            #expect(model.statusMessage == nil)
        }
    }

    @Test("addSharedEntry surfaces 'Could not load age key' when the dev key file is missing")
    func addSharedEntryMissingAgeKey() throws {
        try WorkshopTestSupport.withTempVault { vault in
            let model = WorkshopModel(
                environment: [
                    "SHARIBAKO_VAULT": vault.path,
                    "SHARIBAKO_AGE_KEY": "/nonexistent/dev-key.txt",
                ],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.addSharedEntry(id: "openai", value: "v", notes: nil)
            #expect(model.errorMessage?.hasPrefix("Could not load age key") == true)
            #expect(model.statusMessage == nil)
        }
    }

    @Test("editValue surfaces 'Could not load age key' when the dev key file is missing")
    func editValueMissingAgeKey() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let model = WorkshopModel(
                environment: [
                    "SHARIBAKO_VAULT": vault.path,
                    "SHARIBAKO_AGE_KEY": "/nonexistent/dev-key.txt",
                ],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.editValue(key: "TOKEN", inScope: "kanyo-dev", newValue: "new")
            #expect(model.errorMessage?.hasPrefix("Could not load age key") == true)
        }
    }

    @Test("editNotes surfaces 'Could not load age key' when the dev key file is missing")
    func editNotesMissingAgeKey() throws {
        try WorkshopTestSupport.withTempVault { vault in
            try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let model = WorkshopModel(
                environment: [
                    "SHARIBAKO_VAULT": vault.path,
                    "SHARIBAKO_AGE_KEY": "/nonexistent/dev-key.txt",
                ],
                home: URL(fileURLWithPath: "/Users/nobody")
            )
            model.editNotes(key: "TOKEN", inScope: "kanyo-dev", notes: "new notes")
            #expect(model.errorMessage?.hasPrefix("Could not load age key") == true)
        }
    }

    @Test("addSecret's catch block surfaces errorMessage when the scope does not exist")
    func addSecretCatchBlockOnMissingScope() throws {
        try AppAgeKeyFixture.withEphemeralKey { fixture in
            try WorkshopTestSupport.withTempVault { vault in
                // No scope seeded — VaultCore.addSecret throws scopeNotFound
                // once the age key loads successfully, exercising the second
                // do/catch (not the age-key guard).
                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.addSecret(key: "TOKEN", value: "v", notes: nil, inScope: "ghost-scope")
                #expect(model.errorMessage != nil)
                #expect(model.errorMessage?.hasPrefix("Could not load age key") != true)
                #expect(model.statusMessage == nil)
            }
        }
    }

    @Test("addSharedEntry's catch block surfaces errorMessage on a duplicate id")
    func addSharedEntryCatchBlockOnDuplicate() throws {
        try AppAgeKeyFixture.withEphemeralKey { fixture in
            try WorkshopTestSupport.withTempVault { vault in
                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.addSharedEntry(id: "openai", value: "v1", notes: nil)
                #expect(model.statusMessage == "Created shared entry openai.")

                model.addSharedEntry(id: "openai", value: "v2", notes: nil)
                #expect(model.errorMessage != nil)
            }
        }
    }

    @Test("editValue's catch block surfaces errorMessage for a nonexistent secret")
    func editValueCatchBlockOnMissingSecret() throws {
        try AppAgeKeyFixture.withEphemeralKey { fixture in
            try WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.editValue(key: "GHOST", inScope: "kanyo-dev", newValue: "new")
                #expect(model.errorMessage != nil)
                #expect(model.errorMessage?.hasPrefix("Could not load age key") != true)
            }
        }
    }

    @Test("editNotes's catch block surfaces errorMessage for a nonexistent secret")
    func editNotesCatchBlockOnMissingSecret() throws {
        try AppAgeKeyFixture.withEphemeralKey { fixture in
            try WorkshopTestSupport.withTempVault { vault in
                try WorkshopTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
                let model = WorkshopModel(
                    environment: [
                        "SHARIBAKO_VAULT": vault.path,
                        "SHARIBAKO_AGE_KEY": fixture.privateKeyURL.path,
                    ],
                    home: URL(fileURLWithPath: "/Users/nobody")
                )
                model.editNotes(key: "GHOST", inScope: "kanyo-dev", notes: "new notes")
                #expect(model.errorMessage != nil)
                #expect(model.errorMessage?.hasPrefix("Could not load age key") != true)
            }
        }
    }
}
