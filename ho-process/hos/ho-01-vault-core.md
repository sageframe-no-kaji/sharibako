---
created: 2026-06-30
status: draft
type: ho-document
project: sharibako
ho: "01"
kamae: 5
shape: ha
builds-on:
  - kamae-1-sharibako-seed.md
  - kamae-2-sharibako-system-design.md
  - README.md
  - docs/architecture.md
  - kamae-4-sharibako-ho-overview.md
  - ho-process/hos/ho-00-orientation.md
agent-tasks:
  - Ho-01-AT-01.md
  - Ho-01-AT-02.md
---

# ho-01 — The Vault Core: schema, age, link resolution

The vault's complete data model in code. `SharibakoCore` gets the nine operations the system design specifies — every vault read and write — with thorough tests and no user-facing surface attached. By the end of this ho, an ephemeral vault can be created, populated with linked and unlinked secrets, round-trip encrypted with a real age key, and read back cleanly.

**Out of scope:** git operations (ho-02), Touch ID / Keychain integration (ho-04), the `.sharibako` marker (ho-03), any CLI or GUI surface.

**Resolves deferred decisions** (from the ho-overview and CLAUDE.md):
- `age` binary acquisition for tests
- Age key location during development

---

## Phase 1 — Think

### Decision 1 — Shared-entry ID representation: plaintext slug

Committed. The system design uses slugs throughout (`openai-personal`, `cloudflare-dns-token`). `SharibakoCore` treats the shared entry ID as an opaque non-empty string — it becomes both the filename (`vault/shared/<id>.age`) and the content of any `.link` file referencing it. No character restrictions beyond what the filesystem permits (Unix: anything except `/` and null byte).

### Decision 2 — YAML library: Yams + Codable

`scope.yaml` and decrypted `.age` content are both fixed-schema YAML. Yams (`github.com/jpsim/Yams`) provides the parser; Swift's `Codable` protocol provides the schema binding. Define typed structs that match each file's shape and let `YAMLDecoder` fill them in:

```swift
struct ScopeMetadata: Codable {
    let identity: String
    let type: ScopeType
    let displayName: String?
}
// Decode: try YAMLDecoder().decode(ScopeMetadata.self, from: yamlString)
```

Raw YAML node traversal is reserved for dynamic schemas. Sharibako's schema is fixed by the system design. Yams is added as a `Package.swift` dependency.

### Decision 3 — Process wrapper: Shell.run() internal utility

Every call to `age` (this ho) and `git` (Conduit, ho-02) uses `Foundation.Process`. One internal function in `SharibakoCore` abstracts the setup rather than repeating it at each call site:

```swift
// Internal to SharibakoCore
enum Shell {
    static func findExecutable(_ name: String) throws -> URL
    static func run(_ executableURL: URL, _ arguments: [String]) throws -> ShellResult
}
struct ShellResult { let exitCode: Int32; let stdout: String; let stderr: String }
```

`findExecutable` probes known Homebrew and system paths (`/opt/homebrew/bin/`, `/usr/local/bin/`, `/home/linuxbrew/.linuxbrew/bin/`, `/usr/bin/`) in order, returning the first hit. Throws `VaultError.shellNotFound(name:)` if the binary is absent. `Shell.run` throws on `Process` launch failure; callers inspect `ShellResult.exitCode` and `ShellResult.stderr` for non-zero exits.

### Decision 4 — Error type: single VaultError enum

One typed enum for all `SharibakoCore` failures. The CLI and GUI switch over it to produce user-facing messages without string parsing:

```swift
public enum VaultError: Error {
    case vaultNotFound(path: URL)
    case scopeNotFound(id: String)
    case secretNotFound(scope: String, key: String)
    case scopeAlreadyExists(id: String)
    case sharedEntryNotFound(id: String)
    case linkTargetMissing(id: String)
    case ageInvocationFailed(exitCode: Int32, stderr: String)
    case yamlEncodeError(path: URL, underlying: Error)
    case yamlDecodeError(path: URL, underlying: Error)
    case fileSystemError(path: URL, underlying: Error)
    case shellNotFound(name: String)
}
```

Eleven cases for the v1 library. Not burdensome to maintain; surfaces all the failure modes the surfaces need to handle.

### Decision 5 — `age` binary acquisition: require on PATH, document, CI installs

`age` and `age-keygen` must be on PATH to run the encryption tests (`VaultCoreEncryptionTests`). Pure-filesystem tests (`VaultCoreFilesystemTests`) need no external binaries.

Two documentation points, both mandatory:

1. **CLAUDE.md** gets a "Development prerequisites" section listing `age` alongside swift-format and swiftlint. If it's missing, contributors hit obscure test failures — not acceptable.
2. **CI workflow** (`ci.yml`) adds `age` to the `brew install` step so CI never silently fails on the encryption tests.

`Shell.findExecutable`'s behavior prevents silent failures locally: a missing binary surfaces `VaultError.shellNotFound(name: "age")` immediately as a clear test error, not a confusing downstream assertion.

Ephemeral key generation for tests uses `age-keygen` (ships in the same Homebrew `age` package). Each test session generates a fresh key pair into a temp directory.

### Deferred to execution — age binary path probe edge cases

`Shell.findExecutable`'s probe list covers the common Mac and Linux Homebrew paths. Non-standard environments may need additional paths. AT-02 tests will surface any gaps; the probe strategy can be expanded without changing the function signature.

---

## Phase 2 — Execute

Two tasks with a clean seam at the encryption boundary.

### Ho-01-AT-01 — Filesystem primitives and pure-filesystem operations

`Shell.run()` utility, `VaultError` enum, `ScopeMetadata` and `SecretInfo` models (Yams + Codable), vault directory layout helpers, and the five operations that don't require decryption: `listScopes`, `listShared`, `getScope`, `inspect`, `link`. Plus link graph resolution and orphan detection (walking `scopes/*/*.link`). All tests use ephemeral temp directories; no `age` on PATH required.

→ `ho-process/agent-tasks/Ho-01-AT-01.md`

### Ho-01-AT-02 — age invocation and encryption operations

`SecretContent` model, `AgeKeyFixture` test helper (generates ephemeral age key pairs via `age-keygen`), age encrypt/decrypt wiring through `Shell.run()`, and the four operations that require decryption: `getValue`, `addSecret`, `rotate`/`rotateShared`, `unlink`. Round-trip tests. Orphan detection verified with real encrypted content. CI and CLAUDE.md documentation for the `age` PATH requirement.

→ `ho-process/agent-tasks/Ho-01-AT-02.md`

### Testing and iteration approach

AT-01 completes and passes before AT-02 opens. AT-02's tests build directly on AT-01's filesystem primitives — no parallel execution.

Coverage after AT-02:

```bash
swift test --enable-code-coverage
xcrun llvm-cov report \
  -instr-profile=.build/debug/codecov/default.profdata \
  .build/debug/SharibakoCorePackageTests.xctest/Contents/MacOS/SharibakoCorePackageTests \
  --ignore-filename-regex=".build|Tests"
```

90% floor. Identify any uncovered lines before marking done.

### Done means

- All nine vault operations have passing tests including link-graph resolution and orphan detection
- Round-trip verified: `addSecret` then `getValue` returns the same value
- An ephemeral vault can be created, populated with linked and unlinked secrets, encrypted and decrypted
- `VaultError` is the sole error type surfaced from `SharibakoCore`'s public API — no untyped errors
- `age` documented in `CLAUDE.md` as a development prerequisite
- CI runs clean with `age` on the runner
- Coverage at or above 90%

---

## Phase 3 — Reflect

*To be filled in after execution.*

- **Did the filesystem layout hold?** Any edge cases in scope directory scanning or link file format?
- **age invocation.** What exit codes does `age` use on failure? Did the encrypt/decrypt invocation pattern match the spec, or did the actual binary interface differ?
- **YAML parsing.** Any mismatch between the Codable structs and what Yams produces or expects?
- **VaultError coverage.** Were eleven cases sufficient, or did execution surface missing failure modes?
- **Coverage.** What lines hit the 90% floor challenge — and were they covered or deliberately excluded?
- **ho-01.1/01.2 in retrospect.** If AT-02's `age` work hit the "fussier than expected" threshold the ho-overview warned about, note it here as evidence for future ho splits.
- **Followups for ho-02.** What does the Conduit need from `Shell.run()` or `VaultCore` that wasn't anticipated?

---

_Authored: 2026-06-30 (Think phase)._
_Execution and Reflect: pending._
