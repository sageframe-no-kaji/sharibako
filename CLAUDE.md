# Sharibako

A small local vault for API keys and env vars — native Mac app and cross-platform CLI over an age-encrypted, git-backed filesystem vault.

## Languages

@~/.claude/modules/languages-swift.md

## Project-specific rules

- Multi-product Swift package: `SharibakoCore` (library), `Sharibako` (SwiftUI app target), `SharibakoCLI` (`sharibako` CLI binary). The library carries the vault logic; both surfaces depend on it.
- Private prompts in `prompts/` (gitignored).
- `ho-process/` is tracked publicly — Sharibako's README references the Kamae chain as part of the methodology demonstration.
- Distribution: signed/notarized `.dmg` for the Mac app (M4Bookmaker pattern, deferred to ho-08); Homebrew tap for the CLI (deferred to ho-08).
- License: GPL-3.0 (binary-as-paid-convenience pattern, matching M4Bookmaker).

## Project-specific conventions

- The filesystem IS the schema (per system design §2). Vault Core operations write `<KEY>.age` and `<KEY>.link` files directly; no sidecar database. Tests against Vault Core use ephemeral temp-directory vaults.
- `age` binary is shelled out via `Process`, not linked. Test runs need `age` on PATH or bundled in test resources (decision in ho-01).
- Touch ID gating via macOS Keychain happens at the CLI/GUI boundary, not in `SharibakoCore`. Library tests use an ephemeral age key, no Keychain.
- Xcode project deferred to ho-05. Until then, `swift build` / `swift run` from the command line handles all surfaces.

## Development prerequisites

In addition to the Swift toolchain, the following must be on `PATH` to run the full test suite:

- `age` — encryption binary (`brew install age`)
- `age-keygen` — ships with the same `age` Homebrew formula
- `git` — version control, required for `ConduitLocalTests` and `ConduitRemoteTests`; already present on any machine with Xcode Command Line Tools (`xcode-select --install`)

`VaultCoreFilesystemTests` does not require `age`. `VaultCoreEncryptionTests` does. `ConduitLocalTests` and `ConduitRemoteTests` require `git`.

`swift-format` and `swiftlint` are also required for the pre-commit hooks and CI:

- `swift-format` — `brew install swift-format`
- `swiftlint` — `brew install swiftlint`

## Ho process

Ho documents for this project live in `ho-process/` (publicly tracked):

- `ho-process/kamae-1-sharibako-seed.md` — Kamae 1 (parti)
- `ho-process/kamae-2-sharibako-system-design.md` — Kamae 2 (architecture)
- `README.md` (repo root) — Kamae 3 (canonical public document)
- `docs/architecture.md` — Kamae 3 sibling (public architecture extract)
- `ho-process/kamae-4-sharibako-ho-overview.md` — Kamae 4 (build sequence)
- `ho-process/hos/` — per-ho documents (Kamae 5)
- `ho-process/agent-tasks/` — child agent task specs (dandori format)

## References

- Project repo: https://github.com/sageframe-no-kaji/sharibako
- Sibling product (distribution lineage): https://github.com/sageframe-no-kaji/m4bmaker
- Ho System framework: https://github.com/sageframe-no-kaji/ho-system
