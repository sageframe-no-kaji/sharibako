---
created: 2026-07-01
status: draft
type: ho-document
project: sharibako
ho: "03"
kamae: 5
shape: ha
builds-on:
  - kamae-1-sharibako-seed.md
  - kamae-2-sharibako-system-design.md
  - kamae-2.1-sharibako-injection-decision.md
  - kamae-2.2-sharibako-ownership-decision.md
  - README.md
  - docs/architecture.md
  - SECURITY.md
  - kamae-4-sharibako-ho-overview.md
  - ho-process/hos/ho-00-orientation.md
  - ho-process/hos/ho-01-vault-core.md
  - ho-process/hos/ho-02-conduit.md
agent-tasks:
  - Ho-03-AT-01.md
  - Ho-03-AT-02.md
---

# ho-03 — The Materializer: markers, ingest, materialize, update, heal

The bridge between the vault and the user's filesystem. `SharibakoCore` grows a third public type alongside `VaultCore` and `Conduit`: a `Materializer` value type that reads and writes `.sharibako` markers, walks scan roots, parses `.env` files, merges owned-key values into `.env` without touching non-owned lines, reads `.env` back into the vault via `update`, retracts owned lines via `clean`, and reports per-key drift via `heal`. Kamae 2.2's per-key ownership commitment is honored throughout: sharibako owns only the keys the user selected at ingest — expressed by which files exist under `vault/scopes/<id>/` — and everything else in `.env` is user territory that passes through byte-for-byte.

**Out of scope:**
- CLI subcommands (`sharibako materialize`, `sharibako update`, `sharibako ingest`, `sharibako clean`, `sharibako heal`, `sharibako scan`) — that's ho-04
- Any GUI surface — ho-05 / ho-06
- Multi-root scanning UI (config field is `[String]`; v1 exposes single root, deferred decision #4)
- Additional materialization formats beyond `.env` (deferred decision #5)
- Remote-host materialization (deferred decision #6)
- Background filesystem watching (FSEvents) — manual `scan` only in v1
- Persistent recording of the "leave alone" decision (ephemeral in v1; see Decision 8)

**Resolves deferred decisions** (from the ho-overview + kamae-2.2 conversation):
- `.env` parser strictness (Q4 in kamae-2.2)
- Materialize-on-drift behavior (Q1 in kamae-2.2)
- Ingest fallback for `.env.example` (Q2 in kamae-2.2)
- Ingest name-matching for shared entries (Q3 in kamae-2.2)
- Default `materialize_to` when the marker omits it
- Materializer public type shape

---

## Phase 1 — Think

### Decision 1 — Public type shape: `public struct Materializer`

Parallel to `VaultCore` and `Conduit`. Not an extension on `VaultCore`, not a namespace of static functions.

```swift
public struct Materializer: Sendable {
    public let vaultCore: VaultCore
    public let vaultURL: URL

    public init(vaultCore: VaultCore, vaultURL: URL)
    // …operations…
}
```

The Materializer holds a reference to the `VaultCore` because it needs to call vault operations (list scope keys, get values, add/update secrets during ingest and update). The `vaultURL` is redundant with `vaultCore.vaultURL` but kept for interface clarity — the Materializer's identity is "the bridge for this vault."

Extension pattern matching `Conduit` / `Conduit+Remote`:

- `Materializer.swift` — the type, initializer, write path (markers, `scan`, `status`, `materialize`, `clean`, `heal`)
- `Materializer+Ingest.swift` — the read path (`.env` parsing, `ingest`, `acceptIngest`, `update`)

Same reasoning as Decision 1 in ho-02: keeping the seam visible at the type level, room to grow without refactoring, small enough that both files stay readable.

### Decision 2 — Owned keys are derived from the vault filesystem

Per kamae-2.2. The scope's owned key set is the union of `<KEY>.age` and `<KEY>.link` files in `vault/scopes/<id>/`. No new `scope.yaml` field. `VaultCore` already exposes an `inspect` (or equivalent read) operation from ho-01 that returns the scope's keys and their link/value state; the Materializer calls that.

**Consequence:** adding a key to a scope's ownership is the same operation as adding a secret (`VaultCore.add_secret` or `link`). Removing ownership is the same as removing the secret. There is no separate "manage this key" toggle — ownership and existence are the same fact.

### Decision 3 — Marker schema: exactly what kamae-2 says, no additions

`.sharibako` at the project root, plaintext YAML:

```yaml
scope: kanyo-dev
materialize_to: ./.env    # optional; defaults to ./.env when omitted
```

Decoded into a small `Codable` struct:

```swift
public struct ScopeMarker: Sendable, Equatable, Codable {
    public let scope: String
    public let materializeTo: String?    // nil → default ./.env

    // Marker's own path on disk (not encoded)
    public let markerURL: URL

    // Convenience: the absolute target path for materialize/update/clean
    public var targetURL: URL {
        let raw = materializeTo ?? "./.env"
        return URL(fileURLWithPath: raw, relativeTo: markerURL.deletingLastPathComponent()).standardizedFileURL
    }
}
```

`materialize_to` remains a relative path in the file. Absolute paths would break the marker's "portable across machines" property (kamae-2 §2). The Materializer resolves the relative path against the marker's directory at read time.

### Decision 4 — `.env` parser: line-preserving structured parse

The parser produces a list of `EnvLine` values, one per input line. Each preserves the original line's exact text and identifies which kind of line it is:

```swift
internal enum EnvLine: Sendable, Equatable {
    case blank(text: String)                         // whitespace-only or empty
    case comment(text: String)                       // starts with `#` (leading whitespace allowed)
    case keyValue(key: String, value: String, rawText: String)
    case malformed(text: String, reason: String)     // preserved as-is; surfaced in warnings
}
```

- `rawText` preserves the entire line including any leading whitespace, quoting, comments-after-value. Materialize's merge writes the whole `rawText` back for non-owned key/value pairs.
- Malformed lines are preserved byte-for-byte and never touched. The reason string appears in `ParseWarnings` for the surface layer to display.

Q4 resolved: skip malformed lines with warnings, do not fail ingest.

Multi-line values (`KEY="line1\nline2"` or `KEY="""...` heredoc styles) — reject in v1 by classifying them as malformed. Warning message: "multi-line value at line N; sharibako v1 does not support these."

`export FOO=bar` — accept and treat as `FOO=bar`. The `export` prefix is normalized away at parse time (rawText still preserves it for non-owned lines; for owned lines materialize's canonical rewrite drops the `export`).

Quoting: v1 supports the three common styles — no quotes (`KEY=value`), double quotes (`KEY="value with spaces"`), single quotes (`KEY='value with $vars'`). Escaping inside double quotes: `\\`, `\"`, `\n`, `\t`. Anything more exotic (backslash line continuations, `$(...)`, `${...}` interpolation) — rejected as malformed with a warning.

### Decision 5 — `materialize(scopeID:, overwriteDrift: Bool = false)`: line-preserving merge

Signature and return type:

```swift
public enum MaterializeResult: Sendable, Equatable {
    case wrote(path: URL, keysWritten: [String])
    case unchanged(path: URL)
    case diffPending(diff: MaterializeDiff)
}

public struct MaterializeDiff: Sendable, Equatable {
    public let scopeID: String
    public let path: URL
    public let ownedKeysDiffering: [String]  // just names; plaintext retrieved on demand
    public let ownedKeysMissingFromFile: [String]
}

public func materialize(scopeID: String, overwriteDrift: Bool = false) throws -> MaterializeResult
```

Algorithm:

1. Load the scope marker (walk up from cwd to find `.sharibako`, or take marker URL directly — deferred to execution which interface fits better).
2. Read the target file if present; parse to `[EnvLine]`. If absent, treat as empty array.
3. Load the scope's owned keys and current vault values via `VaultCore` (existing operations).
4. Compute the merge plan:
   - For each owned key present in the file: if the file value differs from the vault value, it's a drift entry.
   - For each owned key absent from the file: it's a missing entry (will be appended).
   - For each non-owned line: unchanged, will pass through.
5. If any drift entries exist AND `overwriteDrift == false`, return `.diffPending(MaterializeDiff(...))` without writing.
6. Otherwise, build the output `[EnvLine]`:
   - For each `EnvLine.keyValue(key: k, ...)` where `k` is owned: replace with a canonical `KEY=value` line built from the vault value.
   - For all other lines: pass through unchanged.
   - For owned keys not present in the file: append at the end (with one blank line before them if the file was non-empty and didn't already end in a blank line).
7. Write the composed text atomically (write to temp file, rename over target — same durability pattern used elsewhere).
8. Return `.wrote(path:, keysWritten:)` listing every owned key whose line was written (drift + newly-added). If nothing needed writing, return `.unchanged`.

Q1 resolved: `overwriteDrift: false` is the default; `diffPending` is what a surface layer catches to render options.

**Canonical rewrite quoting:** when the Materializer writes an owned line, it quotes the value if the value contains spaces, special shell characters, or a `#`. Otherwise it writes bare `KEY=value`. This mirrors what dotenv writers commonly emit; users hand-editing to add quotes are respected on next `update` (their quoting choice becomes the file's, then the Materializer preserves it for non-owned lines and re-emits its own choice on next materialize for owned lines).

### Decision 6 — `update(scopeID:)`: bidirectional close

```swift
public enum UpdateResult: Sendable, Equatable {
    case updated(keysUpdated: [String])
    case noChanges
    case fileMissing(path: URL)
    case parseWarnings(warnings: [ParseWarning], keysUpdated: [String])
}

public func update(scopeID: String) throws -> UpdateResult
```

Algorithm:

1. Load the scope marker + target path.
2. If the file doesn't exist: return `.fileMissing(path:)` (not an error — user might not have materialized yet).
3. Parse the file. If warnings occur, collect them.
4. Load the scope's owned keys via VaultCore.
5. For each owned key present in the parsed file: extract its parsed value. Compare against the current vault value.
6. For each key that differs: call VaultCore's rotate-equivalent (from ho-01) — re-encrypts and writes `<KEY>.age`. Update `rotated_at`.
7. Non-owned lines: ignored entirely (never even read as values — only the parser sees their raw text for preservation).
8. Return the list of updated keys, or `.noChanges` if nothing differed. If parse warnings occurred, return `.parseWarnings(...)` even if some keys still updated successfully.

Update is a Materializer-driven convenience over `VaultCore.rotate`. The Materializer does not commit — surface layers call `Conduit.commit` afterward, matching ho-02's precedent that the Materializer never talks to git.

### Decision 7 — `ingest(directory:)` returns four decision types

The read-path pipeline. Reads existing `.env`, `.env.local`, and `.env.example` from the passed directory; classifies each key; returns a proposal:

```swift
public struct ProposedScope: Sendable, Equatable {
    public let directory: URL
    public let suggestedScopeID: String        // from directory basename + collision avoidance
    public let detectedKeys: [DetectedKey]
    public let suggestedKeysNeedingValues: [String]  // from .env.example when no value present
    public let parseWarnings: [ParseWarning]
}

public struct DetectedKey: Sendable, Equatable {
    public let key: String
    public let value: String
    public let sourceFile: URL                 // which file it came from
    public let nameMatchedSharedID: String?    // set if an exact-match shared entry exists
}

public enum KeyDecision: Sendable, Equatable {
    case importAsLocal(key: String)                                  // value comes from DetectedKey
    case linkToShared(key: String, sharedID: String)
    case moveToShared(key: String, newSharedID: String)              // value comes from DetectedKey
    case leaveAlone(key: String)                                     // sharibako records nothing
    case skip(key: String)                                           // defer decision; ingest surfaces this again next run
}

public func ingest(directory: URL) throws -> ProposedScope
public func acceptIngest(_ proposal: ProposedScope, decisions: [KeyDecision]) throws
```

`ingest` is pure read — no vault writes, no marker writes. `acceptIngest` is the write-back: for each decision, calls the appropriate `VaultCore` operation and finally writes the `.sharibako` marker.

Q3 resolved: `nameMatchedSharedID` uses exact case-sensitive match only. `.env` has `OPENAI_API_KEY`; nameMatched is set iff `vault/shared/OPENAI_API_KEY.age` exists literally.

Q2 resolved: keys detected only in `.env.example` (no corresponding `.env` value) go to `suggestedKeysNeedingValues`, not `detectedKeys`. Surfaces render them as a "you'll need values for these" checklist. Nothing enters the vault empty.

### Decision 8 — "Leave alone" is ephemeral in v1

A key marked `.leaveAlone` during ingest results in no vault write, no marker entry, nothing. If the user runs `sharibako init` again in the same directory (or via a "Rescan" GUI action), that key resurfaces as detected and offered again. The user hits "leave alone" again.

Persistent "leave alone" — remembering "sharibako, this key is definitely not mine, don't ask about it again" — would require adding a `left_alone_keys: [String]` field to `scope.yaml`. Rejected for v1:

- **Adds a schema field for a small ergonomic gain.** Ingest is a one-time-per-scope-boundary action. Re-offering a key on rescan is the correct behavior for the "user changed their mind" case anyway.
- **Introduces a persistent negative claim.** The vault would carry state saying "sharibako doesn't own this," which is different from "sharibako doesn't own this because it's not in the vault." Two truths for the same fact; a small consistency risk.
- **Post-v1 refinement if real use shows the friction.** Trivial to add later.

`.skip` vs `.leaveAlone` at the library level: identical (no write). At the surface level: `.leaveAlone` is a confident non-choice ("this is not a secret, move on"); `.skip` is "come back to this one later." Surfaces render them differently; the Materializer records neither.

### Decision 9 — `heal(scopeID:)` returns a structured `DriftReport` — no automatic fix

```swift
public struct DriftReport: Sendable, Equatable {
    public let scopeID: String
    public let path: URL
    public let owned: [KeyDrift]
    public let parseWarnings: [ParseWarning]
}

public enum KeyDrift: Sendable, Equatable {
    case match(key: String)                                     // vault == file
    case fileMissing(key: String)                               // vault has it; file doesn't
    case fileValueDiffers(key: String, vaultSha256: String, fileSha256: String)
    // NOTE: no case for "file has a key vault doesn't own" — non-owned lines are invisible to heal
}

public func heal(scopeID: String) throws -> DriftReport
```

`heal` never rewrites files. It only reports. Surfaces read the report and offer:

- Re-materialize (accept vault as truth, overwrite drifted file lines): `materialize(scopeID:, overwriteDrift: true)`
- Update from file (accept file as truth, push into vault): `update(scopeID:)`
- Do nothing (user resolves manually)

Same pattern as `Conduit.pull()`'s `abortedConflict(conflicts:)` — the Materializer detects, the surfaces resolve. SHA-256 rather than plaintext in the diff avoids surfacing secret values in log-like structures. Surfaces retrieve plaintext with `VaultCore.get_value` when they need to display it.

### Decision 10 — `clean(scopeID:)` removes owned lines only; deletes file if empty

```swift
public enum CleanResult: Sendable, Equatable {
    case cleaned(path: URL, keysRemoved: [String], fileStillExists: Bool)
    case fileMissing(path: URL)                                 // nothing to clean
}

public func clean(scopeID: String) throws -> CleanResult
```

Algorithm:

1. Load the scope's marker + target path.
2. If the file doesn't exist: `.fileMissing`.
3. Parse the file to `[EnvLine]`.
4. Load the scope's owned keys.
5. Filter out every `EnvLine.keyValue(key: k, ...)` where `k` is owned. Preserve everything else (comments, blank lines, non-owned pairs, malformed lines).
6. If the resulting list is empty OR contains only `.blank` and `.comment` entries: delete the file. `fileStillExists = false`.
7. Otherwise: write the filtered content atomically. `fileStillExists = true`.

`clean` never asks for confirmation at the library level — surfaces (CLI, GUI) confirm before calling. The library assumes the caller made the decision.

### Decision 11 — Scan uses `FileManager` enumeration; scope resolution walks up from cwd

`scan(roots:)` uses `FileManager.enumerator(at:)` to walk each root, filtering for `.sharibako` files. Returns `[ScopeMarker]` — one entry per marker found. Ordering is stable (breadth-first, then alphabetical within a depth).

Scope resolution helper — for `materialize`, `update`, `clean`, `heal` called without an explicit marker — walks up from cwd (or a passed-in URL) looking for a `.sharibako` file. Stops at the user's home directory or the filesystem root, whichever comes first. Same pattern as git's `.git/` discovery.

Both helpers live in `Materializer.swift` (write-path file).

### Decision 12 — Errors: extend `VaultError` with three cases

```swift
case markerNotFound(path: URL)               // Scope resolution walked up without finding a .sharibako file
case markerMalformed(path: URL, reason: String)  // .sharibako found but the YAML doesn't parse
case envParseFailed(path: URL, reason: String)   // Truly unrecoverable parse (empty warnings + no lines usable). Currently unused — every real .env failure surfaces as ParseWarnings from Decision 4. Reserved for edge cases like unreadable file.
```

Three new cases only. The rest of the ho's failure modes live inside enum-returning operations (`MaterializeResult`, `UpdateResult`, `CleanResult`) or in `ParseWarnings` embedded in success returns — consistent with the ho-02 precedent that "state" and "error" are distinguished at the type level.

### Deferred to execution

- Whether the marker's `materializeTo` accepts `~/` expansion. v1 rejects `~/` (returns markerMalformed) — resolving `~/` at parse time bakes in the host user, which breaks marker portability. But an existing widely-adopted `.env` convention may push us to reconsider. Leave for AT-01 to hit and surface.
- The `EnvLine` internal enum's exact fidelity for tricky files (Windows line endings, BOM markers, trailing whitespace variants). v1 handles them if they appear in the test fixtures; refinements are agent-task-time.
- Whether `ingest` also reads `.env.production`, `.env.staging`, etc. Kamae 2 named only `.env`, `.env.local`, `.env.example`. v1 follows kamae-2. Post-v1 might add scope-typed environment reading.
- The exact SHA-256 domain-separation for `KeyDrift.fileValueDiffers`. Just SHA-256 of UTF-8 bytes is enough for v1 (no need for HMAC or namespace prefix — the SHAs are compared internally, not published).
- Whether `update` should be idempotent-observable (repeat call returns `.noChanges` after the first) — yes; falls out of the algorithm naturally, but worth explicit test coverage in AT-02.

---

## Phase 2 — Execute

Two agent tasks with a clean seam between the write path and the read path. AT-01 completes and passes before AT-02 opens.

### Ho-03-AT-01 — Write path: Materializer type, markers, materialize, clean, heal

Everything in `Materializer.swift`. The type, initializer, marker read (`ScopeMarker` struct + Codable decode), `scan(roots:)`, scope resolution helper, `status(scopeID:)`, `materialize(scopeID:, overwriteDrift:)`, `clean(scopeID:)`, `heal(scopeID:)`. Plus the `.env` parser (`EnvLine` enum, parse function) — AT-02 uses this same parser for ingest and update, so it lives with the write path where it's first needed. Plus the three new `VaultError` cases and the four new public return types (`MaterializeResult`, `MaterializeDiff`, `DriftReport`, `KeyDrift`, `CleanResult`, `ScopeState`).

→ `ho-process/agent-tasks/Ho-03-AT-01.md`

### Ho-03-AT-02 — Read path: ingest, acceptIngest, update, four-way decision matrix

Everything in `Materializer+Ingest.swift`. `ingest(directory:) → ProposedScope`, `acceptIngest(_:, decisions:)` writing through to VaultCore, `update(scopeID:) → UpdateResult`. Plus `ProposedScope`, `DetectedKey`, `KeyDecision`, `UpdateResult`, and the ingest-specific scope-ID suggestion helper (basename + collision avoidance via `VaultCore.list_scopes`). Tests exercise the full four-way decision matrix plus round-trip (materialize → hand-edit non-owned + owned → update → materialize) integrity.

→ `ho-process/agent-tasks/Ho-03-AT-02.md`

### Testing and iteration approach

AT-01 completes and passes before AT-02 opens. AT-02 imports AT-01's parser and marker types. Coverage floor stays at the 90% enforced in CI. No new binary dependencies — the Materializer uses `Foundation` and `Yams` (already in `Package.swift` from ho-01). Integration tests use the same `withEphemeralGitVault` fixture from ho-02, extended with helper functions for populating `.env` files in a temp project directory.

### Done means

- All Materializer operations (`scan`, `status`, `materialize`, `update`, `clean`, `heal`, `ingest`, `acceptIngest`) have passing tests
- Line-preservation round-trip test: create `.env` with a mix of owned and non-owned lines, materialize, hand-edit non-owned and owned separately, run `update`, run `materialize` again — assert non-owned lines survive byte-for-byte and owned drift is picked up
- Four-way ingest decision matrix exercised: each decision type resolves to the correct VaultCore action (import-local writes `.age`; link writes `.link`; move-to-shared writes `shared/<id>.age` + `.link`; leave-alone writes nothing)
- Drift report exposes SHAs but never plaintext values
- Multi-machine simulation for `status`: vault has a scope; marker present on machine A → `.liveHere(materialPath:)`; absent on machine B → `.liveElsewhere`; marker present but vault scope missing → `.orphaned(reason:)`
- `clean` deletes only owned lines; deletes the file if only whitespace/comments remain; preserves the file otherwise
- Malformed `.env` lines are collected as warnings and surfaced in return types, not raised as errors
- CI runs clean, coverage stays ≥ 90%

---

## Phase 3 — Reflect

_To be filled in after AT-01 and AT-02 complete._

---

## Followups tracked for future hos

Deliberate hand-offs to later work. Not code changes; things the later hos should read here and pick up.

### For ho-04 (The Tool / CLI)

- **Subcommand surface for every Materializer operation.** `sharibako materialize <scope>`, `sharibako update <scope>`, `sharibako clean <scope>`, `sharibako heal <scope>`, `sharibako scan`, `sharibako ingest <directory>` (or fold into `init`). Each maps 1:1 to a Materializer method plus surface-appropriate error handling.
- **Interactive ingest matrix in the terminal.** The four-way decision (`importAsLocal`, `linkToShared`, `moveToShared`, `leaveAlone`) needs a terminal-native UX. Probably a prompt-per-key with the four options + `s` for skip. Consider batching for large `.env` files (30+ keys).
- **`materialize` on `.diffPending`.** CLI receives `.diffPending(diff:)`, presents the diff (owned keys differing, keys missing from file), asks user to confirm re-materialize with `--force` (or `y/n` prompt). Consider a `--json` output for scripting.
- **`update` on `.parseWarnings`.** CLI prints warnings after the "N keys updated" message.
- **`sharibako heal <scope>` output format.** DriftReport is structured; CLI needs a human-readable format that names owned keys with drift, marks matching keys as green, marks missing-from-file as yellow.
- **Scope-ID collision suggestion.** `ingest` returns a `suggestedScopeID`; if the CLI wants to disambiguate visibly (e.g., append `-dev` when a same-named scope exists), it can override the suggestion — Materializer is happy to accept any scope ID.

### For ho-05 / ho-06 (The Workshop / GUI polish)

- **Ingest decision matrix as a SwiftUI flow.** Each detected key is a row with a segmented picker (Import / Link / Move / Leave Alone). "Import all" bulk-action button. "Move to shared" reveals a small text field for the new shared ID (with the detected key as a default suggestion).
- **Materialize drift resolver modal.** When `materialize` returns `.diffPending`, show a modal listing owned keys differing (with the option to reveal plaintext values via Touch ID) and buttons for "Overwrite from vault" (re-materialize with force), "Update from file" (run `update`), and "Cancel."
- **Heal surface.** DriftReport in a per-scope sidebar section. Match/differs/missing as glyphs. "Fix all" runs materialize with force for `fileValueDiffers` and `fileMissing`.
- **Suggested-keys-needing-values state.** For scopes with `.env.example` keys but no `.env` value: sidebar badge "N keys need values," clicking opens a filled-in-list view where user types values.
- **"Rescan .env" per-scope button.** Runs `update` when the user has hand-edited `.env` in an editor.

### For ho-04.5 (`sharibako run`, `clean`, SECURITY.md)

- **`clean` CLI command wires to `Materializer.clean(scopeID:)`.** Confirms deletion unless `--force`.
- **`clean --all` walks every scope with a live marker.** Post-v1 refinement if the single-scope case turns out cramped in real use.
- **`run` scope resolution** uses the same walk-up-from-cwd helper the Materializer uses. Consider hoisting to a shared internal helper if it turns out both files want it.

### Post-MVP

- **Persistent "leave alone" state.** If users report that repeated ingest offers of the same "not a secret" keys become annoying, add a `left_alone_keys: [String]` field to `scope.yaml` and thread it through `ingest`. Decision 8 preserved the analysis.
- **Additional environment files.** `.env.production`, `.env.staging`, etc. as first-class ingest sources. Kamae 2 named only three; expanding is post-v1.
- **Non-`.env` materialization formats.** Kamae 2 §7 (as revised by 2.2 for ownership) — the Materializer's formatter is a swappable component; new formats can plug in without changing the schema.

---

_Authored: 2026-07-01._
_Execute and Reflect: pending._
