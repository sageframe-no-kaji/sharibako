import Foundation
import Testing

@testable import SharibakoCore

/// Tests for `Materializer.update` — file → vault sync for owned keys.
@Suite("Materializer Update")
struct MaterializerUpdateTests {
    // MARK: - Simple cases

    @Test("update on a missing target file returns .fileMissing")
    func updateFileMissing() throws {
        try VaultTestSupport.withEphemeralVault { vault in
            try VaultTestSupport.writeScope("bento", type: .projectDev, in: vault)
            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let core = try VaultCore(vaultURL: vault)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let marker = ScopeMarker(scope: "bento", materializeTo: "./.env", markerURL: markerURL)
                let result = try mat.update(scopeID: "bento", marker: marker)
                guard case .fileMissing = result else {
                    Issue.record("expected .fileMissing")
                    return
                }
            }
        }
    }

    @Test("update with all owned keys matching vault returns .noChanges without warnings")
    func updateNoChanges() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("bento", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "sk-live", inScope: "bento")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "API_KEY=sk-live\n".write(to: targetURL, atomically: true, encoding: .utf8)
                let marker = ScopeMarker(scope: "bento", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let result = try mat.update(scopeID: "bento", marker: marker)
                #expect(result == .noChanges(warnings: []))
            }
        }
    }

    // MARK: - Drift

    @Test("update with a drifted scope-local key rotates the .age and returns .updated")
    func updateScopeLocalDrift() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("bento", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "vault-value", inScope: "bento")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "API_KEY=hand-edited\n".write(to: targetURL, atomically: true, encoding: .utf8)
                let marker = ScopeMarker(scope: "bento", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let result = try mat.update(scopeID: "bento", marker: marker)
                #expect(result == .updated(keysUpdated: ["API_KEY"], warnings: []))
                #expect(try core.getValue("API_KEY", inScope: "bento") == "hand-edited")
            }
        }
    }

    @Test("update with a drifted linked-shared key rotates the shared entry, not a scope-local")
    func updateSharedLinkedDrift() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("bento", type: .projectDev, in: vault)
            try VaultTestSupport.writeScope("kanyo", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSharedEntry("openai-personal", value: "sk-original")
            try core.link("OPENAI_API_KEY", inScope: "bento", toShared: "openai-personal")
            try core.link("OPENAI_API_KEY", inScope: "kanyo", toShared: "openai-personal")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "OPENAI_API_KEY=sk-rotated\n".write(to: targetURL, atomically: true, encoding: .utf8)
                let marker = ScopeMarker(scope: "bento", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                _ = try mat.update(scopeID: "bento", marker: marker)
                // The shared value changed for both scopes — that's the .link semantics.
                #expect(try core.getValue("OPENAI_API_KEY", inScope: "bento") == "sk-rotated")
                #expect(try core.getValue("OPENAI_API_KEY", inScope: "kanyo") == "sk-rotated")
            }
        }
    }

    // MARK: - Owned removal and non-owned edits

    @Test("update does NOT report owned keys absent from the file (removal is heal's concern)")
    func updateIgnoresRemovedOwnedKeys() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("bento", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("A", value: "one", inScope: "bento")
            try core.addSecret("B", value: "two", inScope: "bento")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                // B has been removed from the file; A still matches.
                try "A=one\n".write(to: targetURL, atomically: true, encoding: .utf8)
                let marker = ScopeMarker(scope: "bento", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let result = try mat.update(scopeID: "bento", marker: marker)
                #expect(result == .noChanges(warnings: []))
                #expect(try core.getValue("B", inScope: "bento") == "two")
            }
        }
    }

    @Test("update ignores non-owned line edits entirely")
    func updateIgnoresNonOwnedEdits() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("bento", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("A", value: "one", inScope: "bento")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "A=one\nDEBUG=false\nPORT=3001\n"
                    .write(to: targetURL, atomically: true, encoding: .utf8)
                let marker = ScopeMarker(scope: "bento", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let result = try mat.update(scopeID: "bento", marker: marker)
                #expect(result == .noChanges(warnings: []))
                // Verify no ghost keys leaked into vault.
                let keys = try core.inspect("bento").map(\.key)
                #expect(keys == ["A"])
            }
        }
    }

    // MARK: - Warnings and idempotency

    @Test("update surfaces parse warnings alongside the update result")
    func updateSurfacesWarnings() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("bento", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("A", value: "one", inScope: "bento")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                // 1BAD is malformed (invalid key).
                try "A=new-value\n1BAD=nope\n"
                    .write(to: targetURL, atomically: true, encoding: .utf8)
                let marker = ScopeMarker(scope: "bento", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let result = try mat.update(scopeID: "bento", marker: marker)
                // swiftlint:disable:next pattern_matching_keywords
                guard case .updated(let keys, let warnings) = result else {
                    Issue.record("expected .updated")
                    return
                }
                #expect(keys == ["A"])
                #expect(!warnings.isEmpty)
            }
        }
    }

    @Test("update run twice returns .noChanges on the second call (idempotent-observable)")
    func updateIsIdempotent() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("bento", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("A", value: "original", inScope: "bento")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "A=rotated\n".write(to: targetURL, atomically: true, encoding: .utf8)
                let marker = ScopeMarker(scope: "bento", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)

                let first = try mat.update(scopeID: "bento", marker: marker)
                #expect(first == .updated(keysUpdated: ["A"], warnings: []))
                let second = try mat.update(scopeID: "bento", marker: marker)
                #expect(second == .noChanges(warnings: []))
            }
        }
    }
}
