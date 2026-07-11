import Foundation
import Testing

@testable import SharibakoCore

/// Tests for `Materializer.preview(marker:)` (ho-06.1 AT-03, Decision 5).
///
/// `preview` reuses the same private composer as `materialize` — these tests
/// prove the two never drift apart (byte-equality against the write path's
/// output) and that `preview` never touches the filesystem, including on the
/// drift case where `materialize` itself would refuse to write.
@Suite("Materializer Preview")
struct MaterializerPreviewTests {
    @Test("preview matches materialize output byte-for-byte when creating a new file")
    func previewMatchesMaterializeForNewFile() throws {
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

                let previewed = try mat.preview(marker: marker)

                guard case .wrote(let path, _) = try mat.materialize(marker: marker) else {
                    Issue.record("expected .wrote")
                    return
                }
                let written = try String(contentsOf: path, encoding: .utf8)
                #expect(previewed == written)
            }
        }
    }

    @Test("preview matches materialize output byte-for-byte when merging into an existing file")
    func previewMatchesMaterializeForExistingFile() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "sk-new", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                let original = "# comment\nDEBUG=true\nPORT=3000\n"
                try original.write(to: targetURL, atomically: true, encoding: .utf8)

                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)

                let previewed = try mat.preview(marker: marker)

                guard case .wrote(let path, _) = try mat.materialize(marker: marker) else {
                    Issue.record("expected .wrote")
                    return
                }
                let written = try String(contentsOf: path, encoding: .utf8)
                #expect(previewed == written)
                #expect(previewed.contains("# comment"))
                #expect(previewed.contains("API_KEY=sk-new"))
            }
        }
    }

    @Test("preview creates no file and modifies no existing file")
    func previewWritesNothing() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "sk-live", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)

                _ = try mat.preview(marker: marker)

                #expect(!FileManager.default.fileExists(atPath: targetURL.path))
                let siblings = try FileManager.default.contentsOfDirectory(atPath: project.path)
                #expect(!siblings.contains { $0.contains("sharibako-tmp") })
            }
        }
    }

    @Test("preview does not modify an existing target's mtime or contents")
    func previewLeavesExistingFileUntouched() throws {
        try VaultTestSupport.withEphemeralVaultAndKey { vault, fixture in
            try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
            let core = try VaultCore(vaultURL: vault, ageKeyURL: fixture.privateKeyURL)
            try core.addSecret("API_KEY", value: "sk-new", inScope: "kanyo-dev")

            try VaultTestSupport.withEphemeralProjectDirectory { project in
                let markerURL = project.appendingPathComponent(".sharibako")
                let targetURL = project.appendingPathComponent(".env")
                try "API_KEY=sk-old\n".write(to: targetURL, atomically: true, encoding: .utf8)
                let beforeAttrs = try FileManager.default.attributesOfItem(atPath: targetURL.path)
                let beforeMtime = beforeAttrs[.modificationDate] as? Date
                let beforeContents = try String(contentsOf: targetURL, encoding: .utf8)

                let marker = ScopeMarker(scope: "kanyo-dev", materializeTo: "./.env", markerURL: markerURL)
                let mat = Materializer(vaultCore: core, vaultURL: vault)

                // The vault value differs from the file's — a drift case for
                // `materialize`. `preview` still composes and returns the
                // vault-side text without writing.
                let previewed = try mat.preview(marker: marker)
                #expect(previewed == "API_KEY=sk-new\n")

                let afterAttrs = try FileManager.default.attributesOfItem(atPath: targetURL.path)
                let afterMtime = afterAttrs[.modificationDate] as? Date
                let afterContents = try String(contentsOf: targetURL, encoding: .utf8)
                #expect(afterMtime == beforeMtime)
                #expect(afterContents == beforeContents)
            }
        }
    }

    @Test("preview renders the vault-side composition on the drift case, unlike materialize which refuses to write")
    func previewRendersVaultSideOnDrift() throws {
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

                // materialize refuses to write on undeclared drift...
                guard case .diffPending = try mat.materialize(marker: marker) else {
                    Issue.record("expected .diffPending")
                    return
                }
                // ...but preview still shows what WOULD land, matching what
                // materialize(overwriteDrift: true) would actually write.
                let previewed = try mat.preview(marker: marker)
                #expect(previewed == "API_KEY=vault-value\n")

                guard case .wrote(let path, _) = try mat.materialize(marker: marker, overwriteDrift: true)
                else {
                    Issue.record("expected .wrote")
                    return
                }
                let written = try String(contentsOf: path, encoding: .utf8)
                #expect(previewed == written)

                // The file on disk is still untouched by the plain preview call
                // above — only the explicit overwriteDrift materialize wrote it.
                #expect(written == "API_KEY=vault-value\n")
            }
        }
    }

    @Test("preview returns .unchanged-equivalent text when the file already matches the vault")
    func previewMatchesUnchangedCase() throws {
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

                let previewed = try mat.preview(marker: marker)
                #expect(previewed == "API_KEY=sk-live\n")
                #expect(try mat.materialize(marker: marker) == .unchanged(path: targetURL))
            }
        }
    }
}
