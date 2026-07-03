import Foundation
import Testing

@testable import SharibakoCore

/// Tests for `Materializer.materialize` — line-preserving merge and drift handling.
///
/// The clean/heal/round-trip tests live in `MaterializerCleanHealTests.swift`;
/// splitting keeps each test struct under the type-body-length ceiling.
@Suite("Materializer Merge")
struct MaterializerMergeTests {
    // MARK: - Materialize (write path — needs age key for real vault values)

    @Test("materialize into a nonexistent .env creates the file with owned keys only")
    func materializeCreatesNewFile() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("DATABASE_URL", value: "postgres://x@y/z", inScope: "kanyo-dev")
            try core.addSecret("API_KEY", value: "sk-live-abc", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let marker = ScopeMarker(
                    scope: "kanyo-dev",
                    materializeTo: "./.env",
                    markerURL: markerURL
                )
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let result = try mat.materialize(marker: marker)
                guard case .wrote(let path, let keys) = result else {
                    Issue.record("expected .wrote, got \(result)")
                    return
                }
                #expect(keys.sorted() == ["API_KEY", "DATABASE_URL"])
                let text = try String(contentsOf: path, encoding: .utf8)
                #expect(text.contains("API_KEY=sk-live-abc"))
                #expect(text.contains("DATABASE_URL=postgres://x@y/z"))
            }
        }
    }

    @Test("materialize into a file with only non-owned lines appends owned keys and preserves the rest byte-for-byte")
    func materializePreservesNonOwnedLines() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "sk-live", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                let original = "# top comment\nDEBUG=true\nPORT=3000\n"
                try original.write(to: targetURL, atomically: true, encoding: .utf8)

                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let result = try mat.materialize(marker: marker)
                guard case .wrote = result else {
                    Issue.record("expected .wrote, got \(result)")
                    return
                }
                let after = try String(contentsOf: targetURL, encoding: .utf8)
                #expect(after.contains("# top comment"))
                #expect(after.contains("DEBUG=true"))
                #expect(after.contains("PORT=3000"))
                #expect(after.contains("API_KEY=sk-live"))
                // The original bytes must appear as a prefix (line preservation).
                #expect(after.hasPrefix("# top comment\nDEBUG=true\nPORT=3000\n"))
            }
        }
    }

    @Test("materialize on a mixed file replaces owned lines in place, preserves non-owned exactly")
    func materializeReplacesInPlace() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "sk-new", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                // API_KEY is owned; DEBUG and PORT are not.
                let original = "# comment\nDEBUG=true\nAPI_KEY=sk-new\nPORT=3000\n"
                try original.write(to: targetURL, atomically: true, encoding: .utf8)

                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let result = try mat.materialize(marker: marker)
                // Owned value already matches vault; canonical form matches file → unchanged.
                #expect(result == .unchanged(path: targetURL))
                let after = try String(contentsOf: targetURL, encoding: .utf8)
                #expect(after == original)
            }
        }
    }

    @Test("materialize returns .unchanged when the file already matches the vault")
    func materializeUnchanged() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "sk-live", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "API_KEY=sk-live\n".write(to: targetURL, atomically: true, encoding: .utf8)
                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let result = try mat.materialize(marker: marker)
                #expect(result == .unchanged(path: targetURL))
            }
        }
    }

    @Test("materialize returns .diffPending when owned key values differ and overwriteDrift is false")
    func materializeDiffPending() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "vault-value", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "API_KEY=file-value\n".write(to: targetURL, atomically: true, encoding: .utf8)
                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let result = try mat.materialize(marker: marker)
                guard case .diffPending(let diff) = result else {
                    Issue.record("expected .diffPending, got \(result)")
                    return
                }
                #expect(diff.ownedKeysDiffering == ["API_KEY"])
                // File not modified — still has original bytes
                let after = try String(contentsOf: targetURL, encoding: .utf8)
                #expect(after == "API_KEY=file-value\n")
            }
        }
    }

    @Test("materialize with overwriteDrift=true replaces the file value")
    func materializeOverwriteDrift() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "vault-value", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "API_KEY=file-value\n".write(to: targetURL, atomically: true, encoding: .utf8)
                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                let result = try mat.materialize(marker: marker, overwriteDrift: true)
                guard case .wrote = result else {
                    Issue.record("expected .wrote, got \(result)")
                    return
                }
                let after = try String(contentsOf: targetURL, encoding: .utf8)
                #expect(after == "API_KEY=vault-value\n")
            }
        }
    }

    @Test("materialize preserves comment placement before a rewritten owned key")
    func materializePreservesCommentPlacement() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "new", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "# this is API_KEY\nAPI_KEY=old\n".write(to: targetURL, atomically: true, encoding: .utf8)
                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                _ = try mat.materialize(marker: marker, overwriteDrift: true)
                let after = try String(contentsOf: targetURL, encoding: .utf8)
                #expect(after == "# this is API_KEY\nAPI_KEY=new\n")
            }
        }
    }

    @Test("materialize preserves trailing newline exactly when file ends with one")
    func materializePreservesTrailingNewline() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "sk", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "API_KEY=sk\n".write(to: targetURL, atomically: true, encoding: .utf8)
                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                _ = try mat.materialize(marker: marker)
                let after = try String(contentsOf: targetURL, encoding: .utf8)
                #expect(after.hasSuffix("\n"))
            }
        }
    }

    @Test("materialize preserves no-trailing-newline when file did not have one")
    func materializePreservesNoTrailingNewline() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "sk", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "API_KEY=sk".write(to: targetURL, atomically: true, encoding: .utf8)
                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                _ = try mat.materialize(marker: marker)
                let after = try String(contentsOf: targetURL, encoding: .utf8)
                #expect(!after.hasSuffix("\n"))
            }
        }
    }

    @Test("materialize canonical rewrite: bare-safe value emits bare, spaces/# emit double-quoted")
    func materializeCanonicalRewrite() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("SIMPLE", value: "bareword", inScope: "kanyo-dev")
            try core.addSecret("WITH_SPACE", value: "has space", inScope: "kanyo-dev")
            try core.addSecret("WITH_HASH", value: "has#hash", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                _ = try mat.materialize(marker: marker)
                let after = try String(contentsOf: targetURL, encoding: .utf8)
                #expect(after.contains("SIMPLE=bareword"))
                #expect(after.contains("WITH_SPACE=\"has space\""))
                #expect(after.contains("WITH_HASH=\"has#hash\""))
            }
        }
    }

    @Test("materialize inserts appended owned keys BEFORE a trailing blank line, preserving structure")
    func materializeAppendsBeforeTrailingBlank() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("A", value: "1", inScope: "kanyo-dev")
            try core.addSecret("B", value: "2", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                // File has A plus a blank spacer line, then a trailing newline.
                // B is owned but missing — should be appended BEFORE the trailing blank.
                try "A=1\n\n".write(to: targetURL, atomically: true, encoding: .utf8)
                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                _ = try mat.materialize(marker: marker)
                let after = try String(contentsOf: targetURL, encoding: .utf8)
                #expect(after == "A=1\nB=2\n\n")
            }
        }
    }

    @Test("materialize creates the target's parent directory when it does not exist yet")
    func materializeCreatesParentDirectory() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "sk", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                // Target is inside a nested directory that doesn't exist yet.
                let marker = ScopeMarker(
                    scope: "kanyo-dev",
                    materializeTo: "./config/env/.env",
                    markerURL: markerURL
                )
                let mat = Materializer(vaultCore: core, vaultURL: vault)
                _ = try mat.materialize(marker: marker)
                let expectedURL = project.appendingPathComponent("config/env/.env")
                #expect(FileManager.default.fileExists(atPath: expectedURL.path))
                let contents = try String(contentsOf: expectedURL, encoding: .utf8)
                #expect(contents.contains("API_KEY=sk"))
            }
        }
    }
}
