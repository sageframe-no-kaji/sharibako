---
created: 2026-06-30
type: teaching-note
project: sharibako
about-ho: "01"
audience: practitioner
---

# ho-01 — what actually happened

A plain-language walkthrough of what was built in the Vault Core session. This is the first ho that ships real functionality. By the end, the vault can be created, populated with secrets, encrypted with a real age key, linked across scopes, and read back cleanly — all through a public Swift API. No user-facing surface yet; that's ho-04 (CLI) and ho-05 (GUI).

Think of ho-01 as building the engine block. It doesn't have a steering wheel or seats. But you can bench-test it under load and confirm every cylinder fires.

---

## The big picture

Sharibako's job is to hold API keys and secrets in an encrypted, git-backed directory. The system design (Kamae 2) said: **the filesystem IS the schema**. There is no database inside Sharibako. What's on disk in `vault/` is the truth. Sharibako's Vault Core is just a well-behaved reader/writer of that on-disk layout.

The layout, restated:

```
vault/
├── shared/                             ← secrets shared across scopes
│   └── openai-personal.age             ← encrypted with age
└── scopes/                             ← one directory per "scope"
    └── kanyo-dev/                      ← a project's dev scope
        ├── scope.yaml                  ← plaintext metadata about this scope
        ├── DATABASE_URL.age            ← encrypted secret local to this scope
        └── OPENAI_API_KEY.link         ← plaintext pointer to shared/openai-personal.age
```

Three file types, three roles:

- **`<KEY>.age`** — the actual encrypted content. Decrypts to `{ value, notes?, rotated_at? }` in YAML.
- **`<KEY>.link`** — a plaintext file containing a shared entry ID. Says: "for this key, use the shared entry named X."
- **`scope.yaml`** — plaintext metadata: `{ identity, type, display_name? }`. Not secret.

ho-01 built the Swift code that reads and writes those files, plus the operations that resolve links, detect orphans, rotate values, and encrypt/decrypt through the `age` command-line tool.

---

## Why we split the work in two

ho-01 has two "agent tasks" (AT-01 and AT-02), executed in sequence.

**AT-01 — filesystem primitives.** Everything that doesn't require running `age`. The vault directory helpers, error types, YAML models, and the five vault operations that read/write only plaintext: `listScopes`, `listShared`, `getScope`, `inspect`, `link`, plus `linkGraph` and `orphanedSharedEntries`. Tests use fake `.age` files (just some placeholder bytes) because we're not decrypting anything.

**AT-02 — encryption operations.** Everything that DOES require `age`. The four operations that encrypt or decrypt: `addSecret`, `getValue`, `rotate`, `rotateShared`, `unlink`. Plus the test helper that generates ephemeral age key pairs.

The seam is clean: AT-01 doesn't need `age` on your machine to build or test. AT-02 does. Splitting them meant AT-01 could complete and commit before AT-02 opened. If AT-02 hit surprises, AT-01's work would already be locked in.

In hindsight, the seam was correct. AT-02 didn't hit surprises. Neither task needed to be split further (the ho-overview flagged possible splits as ho-01.1 / ho-01.2; not needed).

---

## What each file does

The Vault Core lives in `Sources/SharibakoCore/`. Here's what landed and what each piece is for.

### `VaultError.swift` — the error type

A single Swift enum with 11 cases. Every failure the library can produce is one of these:

```swift
public enum VaultError: Error {
    case vaultNotFound(path: URL)              // vault dir missing
    case scopeNotFound(id: String)             // scope dir missing
    case secretNotFound(scope: String, key: String)
    case scopeAlreadyExists(id: String)
    case sharedEntryNotFound(id: String)
    case linkTargetMissing(id: String)         // .link file points at nothing
    case ageInvocationFailed(exitCode: Int32, stderr: String)
    case yamlEncodeError(path: URL, underlying: Error)
    case yamlDecodeError(path: URL, underlying: Error)
    case fileSystemError(path: URL, underlying: Error)
    case shellNotFound(name: String)           // age binary not on PATH
}
```

Why one enum with all cases up front? Because the surfaces (CLI, GUI, later) need to `switch` over these to produce useful error messages. If the enum grew case-by-case as new failures surfaced, every surface's error-handling code would need to add a `default:` arm and break invariants. Defining all 11 in AT-01 means AT-02 and future hos just USE the existing cases.

In practice: every AT-02 throw site fit an existing case. No new case needed to be added. That's a signal we got the taxonomy right.

### `Shell.swift` — the subprocess wrapper

Swift's `Foundation.Process` is the Python-equivalent of `subprocess.run`, but there's no convenience method. You configure a `Process`, hand it `Pipe`s for stdout/stderr, run it, wait for exit, and read the pipes. Every `age` call and (later) every `git` call goes through the same six lines of boilerplate.

`Shell.swift` wraps that boilerplate. Two functions:

```swift
static func findExecutable(_ name: String) throws -> URL
static func run(_ executableURL: URL, _ arguments: [String]) throws -> ShellResult
```

`findExecutable("age")` probes four standard locations for the `age` binary — `/opt/homebrew/bin` (Apple Silicon Homebrew), `/usr/local/bin` (Intel Mac Homebrew), `/home/linuxbrew/.linuxbrew/bin` (Linux Homebrew), `/usr/bin` (system). Returns the URL of the first match, or throws `VaultError.shellNotFound(name: "age")`.

`run(url, args)` invokes the binary and returns a `ShellResult(exitCode, stdout, stderr)`. It doesn't throw on non-zero exit — it just returns the result and lets the caller decide. Because for `age`, exit code 1 might mean "file doesn't exist" or "wrong key" and the caller needs the specific stderr to know.

Both are `internal`, not `public`. This is a private API to the library. The surfaces don't touch it.

The Conduit (ho-02) will use this same `Shell.run` to invoke `git`. Same wrapper, different binary.

### `VaultLayout.swift` — the URL builder

The vault's on-disk paths exist in exactly one place. Every read or write asks `VaultLayout` for the URL:

```swift
VaultLayout.sharedDirectoryURL(in: vault)              // vault/shared/
VaultLayout.scopeDirectoryURL("kanyo-dev", in: vault)  // vault/scopes/kanyo-dev/
VaultLayout.scopeYAMLURL("kanyo-dev", in: vault)       // vault/scopes/kanyo-dev/scope.yaml
VaultLayout.secretURL("OPENAI_API_KEY", inScope: "kanyo-dev", in: vault)  // <scope>/OPENAI_API_KEY.age
VaultLayout.linkURL(...)                                // <scope>/<key>.link
VaultLayout.sharedEntryURL("openai-personal", in: vault)  // vault/shared/openai-personal.age
```

Plus a bootstrap function `createVaultLayout(at:)` that makes `shared/` and `scopes/` in a fresh vault directory.

This is a discipline more than a technical need. It could all be inline path concatenation. But putting it in one file means: if the vault layout ever changes (it won't, but hypothetically), you edit one file. And it means the layout is documented by the function names, not by scattered string concatenations.

### `Models/ScopeMetadata.swift`, `Models/SecretInfo.swift`, `Models/SecretContent.swift` — the shapes

Three `struct`s that model the vault's data:

- **`ScopeMetadata`** — the shape of `scope.yaml`. `identity`, `type` (an enum: `.projectDev`, `.projectProd`, `.service`, `.machine`, `.other`), optional `displayName`.
- **`SecretInfo`** — what `inspect` returns for each secret slot: a `key` and a `kind` (`.value` for a direct `.age`, or `.link(sharedID:)` for a `.link` pointing at a shared entry). Non-decrypting — you get the shape without decrypting anything.
- **`SecretContent`** — the shape of a decrypted `.age` payload. `value`, optional `notes`, optional `rotatedAt` (an ISO date string like `"2026-06-30"`).

All three conform to `Codable` (Swift's built-in serialization protocol) and `Equatable` (compares field-by-field). The YAML parser (Yams) uses `Codable` to fill them in from YAML text.

The mapping from Swift camelCase to YAML snake_case (`displayName` ↔ `display_name`, `rotatedAt` ↔ `rotated_at`) is declared via `CodingKeys` enums inside each struct. Explicit rather than string-substitution-based.

### `VaultCore.swift` — the main type

The public entry point. A `struct` (value type, copies on assignment — safe by default). Two initializers:

```swift
public init(vaultURL: URL) throws                    // AT-01: filesystem only
public init(vaultURL: URL, ageKeyURL: URL) throws    // AT-02: with encryption
```

Both check the vault directory exists (throws `vaultNotFound` if not). The second reads the age private-key file, extracts the recipient public key line (`# public key: age1...`), and caches it so we don't re-read the file on every encrypt call.

Then seven AT-01 methods:

- **`listScopes()`** — walk `scopes/`, decode each `scope.yaml`, return them sorted by identity.
- **`listShared()`** — list `shared/` entries, return their stems (without `.age`), sorted.
- **`getScope(id)`** — read and decode one scope's `scope.yaml`.
- **`inspect(scopeID)`** — enumerate a scope's secrets without decrypting. Returns `[SecretInfo]`.
- **`link(key, inScope:, toShared:)`** — write a `.link` file pointing at a shared entry. Deletes any existing `.age` at that key (a key is either a value or a link, never both).
- **`linkGraph()`** — walk every `.link` file across every scope, build a map: `sharedID → [(scopeID, key)]`. Nothing on disk stores this; it's computed by walking. That's on purpose — no manifest file, no invariant to keep in sync.
- **`orphanedSharedEntries()`** — shared entries that no `.link` file references. Useful for cleanup.

### `VaultCore+Encryption.swift` — the AT-02 extension

Swift lets you extend a type across multiple files. The AT-02 methods live in this "extension" file so `VaultCore.swift` stays under the 300-line body ceiling SwiftLint enforces. Same type, split naturally at the encryption seam.

The five encryption methods:

- **`addSecret(key, value, inScope:, notes:)`** — encrypt a new `<KEY>.age` in the scope. Uses `age --encrypt --recipient <publicKey> -o <target> <tempFile>`. Wraps the YAML-encoded `SecretContent` in a temp file, encrypts, deletes the temp file.
- **`getValue(key, inScope:)`** — resolve link if present, decrypt the target `.age`, YAML-decode, return the `value` field. Uses `age --decrypt --identity <keyFile> <cipher>` and reads plaintext from stdout.
- **`rotate(key, inScope:, newValue:)`** — decrypt the existing `.age` (to preserve notes), re-encrypt with the new value and today's date.
- **`rotateShared(sharedID, newValue:)`** — same, but on a shared entry. Doesn't touch any `.link` files. Every scope linking to this shared entry sees the new value on the next `getValue`.
- **`unlink(key, inScope:)`** — decrypt the shared entry the link points to, write a fresh local `.age` with that value in the scope, delete the `.link`. From that point on, rotating the shared entry no longer propagates to this scope.

Plus three private helpers: `resolveSecretTarget` (follow a `.link` if present), `decryptSecretContent` (shell to `age --decrypt`, YAML-decode), `encryptAndWrite` (YAML-encode, write temp file, shell to `age --encrypt`), and `todayISODate` (returns `"2026-06-30"` format).

---

## The `age` binary — why shell out rather than link

`age` is a small, focused encryption tool (BSD-2-Clause licensed). The system design chose it over sops because:

- sops is 10MB of Go binary that mostly does things Sharibako doesn't need (partial-file encryption of YAML, multiple backends).
- age is a few hundred KB, does one job well, is well-audited.
- Sharibako's file-per-secret model doesn't need any of sops's cleverness. Each `.age` file is opaque ciphertext top to bottom.

We shell out to `age` via `Process` rather than linking a Swift age library. Two reasons:

1. `age` is the reference implementation. Any Swift wrapper is a translation with its own bugs. Shelling out to the official binary means we get exactly the same behavior as anyone else using `age`.
2. Distribution is simpler. The Mac app bundle in ho-08 will include the `age` binary in `Sharibako.app/Contents/Resources/` — same pattern M4Bookmaker uses for `ffmpeg`. The Linux CLI expects `age` on `PATH` (Homebrew handles it via `depends_on "age"`).

The tradeoff: every encrypt/decrypt is a process launch. Slower than an in-process crypto call. Fine for interactive vault operations; would be wrong for a hot loop.

### The age invocation pattern

Two commands:

```
# encrypt: reads plaintext from a file, writes ciphertext to another file
age --encrypt --recipient <public-key> -o <output.age> <plaintext-input-file>

# decrypt: reads ciphertext from a file, writes plaintext to stdout
age --decrypt --identity <private-key-file> <input.age>
```

Both exit 0 on success, nonzero on failure with stderr describing why.

The private key file (generated by `age-keygen`) is three lines:

```
# created: 2026-06-30T23:06:21-04:00
# public key: age1e9lzq5pdlk4fgl4cdgp8v4l7avpvtxxwvkrvglx6w3hhyfksa4rq57z8kn
AGE-SECRET-KEY-1RYD98ULTZKT9A4V2M2CTPN50SXSJ5TWXMKVNLAH23ZPC6H083Y5SSCMPFN
```

We read the second line, strip the `# public key: ` prefix, and cache the result. That cached string is what we pass to `--recipient` on every encrypt call.

### One `age-keygen` gotcha we ran into

`age-keygen -o <path>` refuses to overwrite an existing file. So the test fixture that generates a fresh key pair for each encryption test can't `mktemp` a file first — it has to `mktemp` a *directory*, then let `age-keygen` create the key file inside it. If we'd used the more common "make a temp file, then run the tool" pattern, every test would fail with "file exists."

Worth remembering when we do similar things in future hos.

---

## The linking system — why it's the whole point

The most interesting bit of Vault Core is the link resolution. It's how the same OpenAI API key can live in one place but appear in three different projects' `.env` files.

**Without links** (the naive approach): every scope has its own copy of every secret. Rotating a shared secret means updating N copies. Missing one silently is a landmine.

**With links**: the shared secret lives at `vault/shared/openai-personal.age` (encrypted once). Each scope that needs it has a `.link` file — a plaintext file containing the string `openai-personal`. When Sharibako materializes `.env` for that scope, it reads the `.link`, follows it to the shared `.age`, decrypts, writes the value.

Rotating: one call to `rotateShared("openai-personal", newValue:)`. Zero `.link` files change. Every scope linking to it resolves the new value on next read.

Nothing stores the link graph. It's rebuilt on demand by walking `scopes/*/*.link`. Because the filesystem is the schema, there's no invariant that could drift out of sync.

### The four link-related operations

- **`link(key, inScope:, toShared:)`** — create a link. Writes `<key>.link`, deletes any existing `<key>.age`.
- **`unlink(key, inScope:)`** — break a link and keep the value. Decrypts the shared entry, writes a local `<key>.age`, deletes `.link`. The scope's copy is now independent.
- **`linkGraph()`** — the map from shared ID to referencing (scope, key) pairs. Useful when you want to know "what would break if I rotate this shared entry?"
- **`orphanedSharedEntries()`** — shared entries with zero references. Cleanup candidates.

`getValue` handles link resolution transparently. From the caller's view, a linked key and a direct-value key are indistinguishable — same call, same return.

---

## YAML — why Yams + Codable

Two file types in the vault use YAML:

- `scope.yaml` — plaintext.
- Decrypted `.age` payload — YAML inside the encrypted blob.

We use `Yams`, the de facto Swift YAML library, wired to Swift's `Codable` protocol. The pattern is:

```swift
struct ScopeMetadata: Codable {
    let identity: String
    let type: ScopeType
    let displayName: String?
    enum CodingKeys: String, CodingKey {
        case identity, type
        case displayName = "display_name"
    }
}

// Decode:
let scope = try YAMLDecoder().decode(ScopeMetadata.self, from: yamlString)

// Encode:
let yamlString = try YAMLEncoder().encode(scope)
```

Codable is Swift's built-in serialization protocol. Any format that has a `Decoder`/`Encoder` (JSON, YAML, plist, custom) can drive `Codable` types. It's the same trick Python's `dataclasses`+`marshmallow` play, but built into the standard library.

The alternative would have been raw YAML-node traversal — walking the parsed YAML tree, looking up keys by hand, converting values manually. That's necessary when your schema is dynamic (unknown fields, arbitrary shapes). Sharibako's schema is fixed by the system design. Codable is the right tool.

---

## The tests — how they're built

47 tests total after both ATs + the coverage bump. Three suites:

1. **`SmokeTests`** — leftover from ho-00. Two assertions that the library exists.
2. **`VaultCoreFilesystemTests`** — 25 tests covering AT-01 operations. No `age` required.
3. **`VaultCoreEncryptionTests`** — 20 tests covering AT-02 operations. `age` on PATH required.

All tests use **swift-testing** (Apple's new test framework, macros-based, declarative), not the older **XCTest**. Every `@Test` function is one test case. `#expect(condition)` is the assertion. `#expect(throws: VaultError.self) { … }` asserts that the closure throws a `VaultError`.

### The ephemeral vault pattern

Every test creates a fresh vault directory in the system temp folder, uses it, and deletes it — even if the test fails:

```swift
try VaultTestSupport.withEphemeralVault { vault in
    try VaultTestSupport.writeScope("kanyo-dev", type: .projectDev, in: vault)
    let core = try VaultCore(vaultURL: vault)
    // … do stuff with core …
}
```

The helper handles setup + `defer { try? FileManager.default.removeItem(at: vault) }` cleanup. Tests can't interfere with each other; there's no shared state.

For encryption tests, `withEphemeralVaultAndKey` additionally generates a fresh age key pair via `AgeKeyFixture.generate()`, gives you both the vault URL and the key fixture, then cleans up both.

### Fixture helpers hoisted to their own file

The setup helpers (`writeScope`, `writeLink`, `writeSharedEntry`, etc.) started life inside each test file. Once `VaultCoreFilesystemTests.swift` grew past 300 lines (SwiftLint's `type_body_length` ceiling), we moved them to `Tests/SharibakoCoreTests/Fixtures/VaultTestSupport.swift` as an `enum VaultTestSupport { … }` namespace. Both suites now share the same fixture code.

### Placeholder `.age` files for AT-01

AT-01 tests don't decrypt anything. When they need to prove `inspect` returns a `.age` slot correctly, they just write a few random bytes to a file with an `.age` extension. `writePlaceholderAge` writes `Data([0x00, 0x01, 0x02])`. It's not real ciphertext; it doesn't need to be. AT-01 code never opens it.

AT-02 tests generate real age key pairs and encrypt real payloads. `writeSharedEntry` creates a real shared entry by staging through a throwaway scope: create scope, `addSecret` into it, move the resulting `.age` file into `shared/`, delete the scope. Real ciphertext ends up in `shared/`.

---

## Coverage — what 96.02% means

After AT-01 and AT-02 landed, coverage was 92.26%. Above the 90% floor, so the task was technically complete. You asked me to push it higher and I added 11 more tests targeting reachable code paths I'd left alone. Final: **96.02% line coverage**.

The tests I added were spec-worthy — testing real behaviors of the library — not filler:

- `ScopeMetadata` memberwise init works (was defined but never called by tests).
- `Shell.findExecutable` throws when a binary is missing.
- `VaultCore` init throws when the age key file doesn't exist.
- `link` throws when the scope directory is read-only (`chmod 0555` trick).
- `unlink` throws when the shared entry the link points at is missing.
- `getValue` throws when the decrypted payload isn't valid YAML.
- `listScopes` / `listShared` / `linkGraph` return empty when the vault has no `scopes/` or `shared/` subdirectory yet.
- `addSecret` / `getValue` throw when the vault was opened without an age key.

The remaining 18 uncovered lines are `catch` arms wrapping FileManager calls (`throw VaultError.fileSystemError(path:underlying:)`). To fire them you need the read to succeed AND the following operation to fail — chmod tricks on individual files, which is fragile and platform-dependent. Not earning their weight to chase.

Coverage measurement: `swift test --enable-code-coverage` writes `.build/…/codecov/default.profdata`. Then `xcrun llvm-cov report -instr-profile=<profdata> <test-binary>` prints the table. CI could enforce a floor; we haven't wired that in yet — deferred.

---

## Two lint-config alignments landed as friction

Worth remembering because they'll come back:

1. **Trailing commas.** swift-format required them (`multiElementCollectionTrailingCommas: true`) but SwiftLint forbade them by default. Only surfaced once real code introduced a multi-element literal. Fix: `.swiftlint.yml` gained `trailing_comma: mandatory_comma: true`. The two tools now agree.
2. **Type body length.** SwiftLint caps struct bodies at 300 lines. `VaultCore.swift` crossed it once encryption was added. Fix: split into `VaultCore.swift` (AT-01) + `VaultCore+Encryption.swift` (AT-02) — Swift's extension mechanism lets a type live across files without changing its semantics.

Both are project conventions worth expecting for ho-02 onwards. When adding a large chunk of related methods, split into a `TypeName+Feature.swift` extension file rather than growing the main file.

---

## What ho-01 did NOT do

Explicitly out of scope:

- **No git operations.** The vault is a directory; ho-01 knows nothing about `git`. That's ho-02 (the Conduit).
- **No `.sharibako` marker.** The plaintext file that tags a project directory as sharibako-managed lands in ho-03 (the Materializer).
- **No Touch ID / Keychain.** The age key handling is file-based — you pass a URL to a private key file. Keychain integration lands in ho-04 at the CLI/GUI boundary. `SharibakoCore` never touches Keychain.
- **No CLI, no GUI.** ho-04 (CLI) and ho-05 (GUI). Vault Core has no `main`, no argument parsing, no windows.

---

## Where to look

If you want to touch something concrete:

- **Public API surface:** `Sources/SharibakoCore/VaultCore.swift` — start here. Read the doc comments; they describe every method's contract.
- **Encryption seam:** `Sources/SharibakoCore/VaultCore+Encryption.swift` — the age-shelling-out logic.
- **Error taxonomy:** `Sources/SharibakoCore/VaultError.swift` — the 11 cases.
- **Data shapes:** `Sources/SharibakoCore/Models/` — ScopeMetadata, SecretInfo, SecretContent.
- **Layout:** `Sources/SharibakoCore/VaultLayout.swift` — the URL builder.
- **Tests:** `Tests/SharibakoCoreTests/VaultCoreFilesystemTests.swift` and `VaultCoreEncryptionTests.swift`. Reading tests is often the fastest way to see what the API does.
- **Fixture helpers:** `Tests/SharibakoCoreTests/Fixtures/VaultTestSupport.swift`.
- **The ho itself:** `ho-process/hos/ho-01-vault-core.md` — Think, Execute, Reflect all in one document.

---

## The seam ho-02 will grow onto

The Conduit (ho-02) wraps `git` for vault sync. Two things from ho-01 it inherits:

- **`Shell.run()` is ready for `git`.** The wrapper doesn't care what binary you hand it. `Shell.findExecutable("git")` should just work — `git` is at `/usr/bin/git` on macOS (Xcode Command Line Tools), which is in the probe list.
- **`VaultCore` doesn't know about git.** No dirty/clean state, no branch awareness. The Conduit runs `git status --porcelain` and interprets it itself.

The Conduit will follow the same pattern as `VaultCore+Encryption.swift`: a separate file, a separate type (probably), sharing `Shell` and `VaultError` (which already has `fileSystemError` and `shellNotFound` — likely enough).

---

_Written 2026-06-30, after ho-01 completed._
