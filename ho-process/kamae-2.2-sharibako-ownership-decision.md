---
created: 2026-07-01
status: decided
type: decision
project: sharibako
stage: kamae-2.2
kamae-chain: seed → system-design → injection-decision → **ownership-decision** → readme → ho-overview
supersedes: kamae-2 §2 (partial — the "materialize writes .env at the marker's target" line and the implicit whole-file-ownership assumption)
builds-on: kamae-1-sharibako-seed, kamae-2-sharibako-system-design, kamae-2.1-sharibako-injection-decision
next: reflected in kamae-1 seed, kamae-4 (ho-03 entry gains the `update` verb), README, SECURITY.md, docs/architecture.md
---

# Sharibako — Ownership Decision (Kamae 2.2)

_A forward-only decision document. Kamae 2's Materializer description read as "sharibako writes the `.env` file at the marker's target," which is compatible with either whole-file ownership or per-key ownership. The current document commits to a specific model: sharibako owns a per-scope set of keys made explicit by the vault's filesystem, and merges owned keys into the user's `.env` without touching non-owned lines. A new operation, `update`, closes the bidirectional loop._

_This document is authoritative for the ownership model. Kamae 2 §2's Materializer description is superseded here. All other Kamae 2 commitments (age-per-secret, file-per-secret in the vault, filesystem-as-schema, git-backed, four-component slice) stand unchanged. Kamae 2.1's injection commitments also stand unchanged._

---

## What Kamae 2 originally left ambiguous

Kamae 2 §2 described `materialize(scope_id)` as:

> reads scope from Vault Core (decrypting all `.age` and resolving all `.link`), writes `.env` at the marker's target; shows a diff if there's drift

That reads as "sharibako owns the whole `.env` file." The README's first-session vignette reinforced the reading: `bento` had three secrets — `OPENAI_API_KEY`, `DATABASE_URL`, `DEBUG` — all three imported to the vault, all three materialized to `.env`. Ho-03 would have implemented it that way.

The assumption is wrong for real `.env` reality. Real files hold both secrets and non-secret config:

```
OPENAI_API_KEY=sk-...        # secret, sharibako should manage
DATABASE_URL=postgres://...  # secret, sharibako should manage
DEBUG=true                   # not a secret; a boolean toggle
PORT=3000                    # not a secret; a port number
NODE_ENV=development         # not a secret; an environment flag
LOG_LEVEL=info               # not a secret; a config knob
```

A whole-file-ownership model forces the user through sharibako for every edit, including edits of non-secrets. That breaks the natural workflow (open editor, toggle `DEBUG=true` to `false`, save) and puts sharibako in charge of things it doesn't need to be in charge of.

## What changed

Two independent pushes surfaced the same fork:

1. **The `.env` reality above.** Users have non-secret config mixed with secrets. Sharibako should own only the parts that need encryption and rotation discipline; the rest is the user's territory.
2. **The git-tracked-`.env` use case.** For some practitioners' workflows, sharibako as the git-tracked home of `.env` (including non-secret config) is *desirable* — it turns `.env` (usually gitignored) into a versioned, syncable, encrypted-at-rest artifact. That value shouldn't disappear just because per-key ownership is the safer default.

Both are real. The decision below serves both without introducing a mode field.

## The decision

**Sharibako owns a per-scope set of keys, made explicit by which files exist in the scope's vault directory. Owned keys are merged into `.env` on materialize; non-owned lines are preserved exactly. A bidirectional `update` operation reads `.env` back into the vault when the user has hand-edited owned values.**

Concretely:

- **Ownership is filesystem-derived.** The scope's owned key set is the union of the `<KEY>.age` and `<KEY>.link` files in `vault/scopes/<id>/`. No schema field, no `scope.yaml` addition. The vault filesystem is the ownership manifest.
- **`materialize(scope_id)` merges.** Reads the existing `.env` at the marker's target (if any), parses to lines, replaces the value for each owned key, preserves all other lines exactly (comments, blank lines, non-owned key/value pairs, ordering, quote style within reason). If the file doesn't exist, writes a new file containing only the owned keys.
- **`ingest(directory)` offers four choices per detected key.** *Import as scope-local secret*, *link to shared*, *move to shared*, or *leave alone*. Keys marked "leave alone" stay in `.env` and are never touched by sharibako. This is a new fourth option compared to what Kamae 2 originally implied.
- **`update(scope_id)` is new.** Reads the current `.env` at the marker's target. For each key sharibako owns for this scope, if the file's value differs from the vault's value, updates the vault. Non-owned keys are ignored. Structurally symmetric to materialize: materialize is vault→file for owned keys; update is file→vault for owned keys.
- **`heal(scope_id)` reports drift on owned keys only.** Non-owned lines are invisible to sharibako. A drift report only surfaces "OPENAI_API_KEY differs" — never "DEBUG differs," because sharibako doesn't own DEBUG.
- **`clean(scope_id)` removes owned lines only.** Deletes the lines whose keys the scope owns; leaves the rest of `.env` intact. If, after cleaning, the file is empty or contains only whitespace and comments, delete it. Otherwise leave it.

## The two workflows this serves

Both workflows use the same code path. The difference is entirely at ingest.

### Workflow A — "just the secrets"

The default workflow for most projects.

1. User runs `sharibako init` in a project directory.
2. Ingest shows the keys in `.env`: `OPENAI_API_KEY`, `DATABASE_URL`, `DEBUG`, `PORT`, `NODE_ENV`.
3. User picks the two API keys as scope-local secrets, leaves the rest alone.
4. Vault now has `OPENAI_API_KEY.age` and `DATABASE_URL.age` under `scopes/<id>/`.
5. `materialize` writes those two values into `.env`, preserves everything else.
6. User can freely edit `DEBUG=true` to `DEBUG=false` in their editor. Sharibako doesn't notice, doesn't care.

### Workflow B — "git-track the whole `.env`"

For practitioners who want their full project config encrypted, versioned, and syncable.

1. User runs `sharibako init` in a project directory.
2. Ingest shows the keys. User hits *Import all* (or clicks every checkbox).
3. Vault now has all five keys as `<KEY>.age` files.
4. `materialize` writes the whole `.env` from the vault. The file may look identical to what was there — because sharibako owns everything.
5. User edits `DEBUG=false` in their editor. Runs `sharibako update <scope>`. Vault picks up the change. `sharibako sync` pushes it to the git remote. Full history preserved.
6. On another machine, `sharibako sync` + `sharibako materialize` gets the same config.

Both workflows work end-to-end without a `management_mode` field, without branching in the Materializer, without a UI switch. The user's decision at ingest determines which workflow they get.

## Why not the alternative shapes

Three shapes were considered. The one chosen is above. The other two are declined, with reasoning preserved for future readers.

### Declined: explicit `management_mode: full | partial` in `scope.yaml`

Rejected because:

- **Two code paths.** The Materializer would branch on mode, and every operation (materialize, heal, clean) would need to know both paths. Twice the testing surface for the same value.
- **The mode is a lie.** "Full mode" is definable as "every key in `.env` at ingest time was imported." "Partial mode" is definable as "some subset was imported." These are the same mechanism with a different starting checklist. Encoding them as a field pretends they're different mechanisms.
- **Migration awkwardness.** A user who starts in "partial" and wants to convert to "full" would need a mode-flip command. Under the unified model, they just import the missing keys — no flip.

### Declined: inline marker comments in `.env`

Sharibako-managed lines fenced by `# sharibako-begin` / `# sharibako-end`. Every marker-touched materialize edits between the fences and leaves everything else alone.

Rejected because:

- **Fences are fragile.** Users edit `.env` in editors, on remote machines, in scratchpad copies. Fences get mangled. A missing `# sharibako-end` silently changes what's owned.
- **Ownership is not spatial.** Sharibako's ownership is per-key, not per-line-range. Fences try to make it spatial. The filesystem model already answers "what does sharibako own?" — adding fences duplicates that answer in a more fragile form.
- **Order matters visually to humans; not to sharibako.** Fences would force sharibako to preserve the fence range's internal order, which is one more constraint for no gain.

### Declined: separate `.env.sharibako` sidecar file

Sharibako owns `.env.sharibako`; the user's loader concatenates `.env` + `.env.sharibako`.

Rejected because:

- **Breaks the "your loader just reads `.env`" ergonomic.** Users would have to configure dotenv or docker-compose to merge two files. That's the exact shape kamae-2.1 declined for reference-based loaders.
- **Duplication risk.** A key can be in both files with different values; loader precedence would decide which wins. Silent shadowing is a bug source.
- **Doesn't serve Workflow B cleanly.** The user's `.env` is still where they'd want the git-tracked config, not the sidecar.

## Implementation shape

### The Materializer's operations

Signatures (Swift, for `SharibakoCore`):

```swift
public struct Materializer: Sendable {
    public init(vaultCore: VaultCore, vaultURL: URL)

    // Filesystem-side operations
    public func scan(roots: [URL]) throws -> [ScopeMarker]
    public func status(scopeID: String) throws -> ScopeState
    public func heal(scopeID: String) throws -> DriftReport
    public func clean(scopeID: String) throws

    // Bidirectional flow
    public func materialize(scopeID: String, overwriteDrift: Bool = false) throws -> MaterializeResult
    public func update(scopeID: String) throws -> UpdateResult

    // Ingest
    public func ingest(directory: URL) throws -> ProposedScope
    public func acceptIngest(_ proposal: ProposedScope, decisions: [KeyDecision]) throws
}

public enum ScopeState: Sendable, Equatable {
    case liveHere(materialPath: URL)
    case liveElsewhere
    case orphaned(reason: String)
}

public struct DriftReport: Sendable, Equatable {
    public let scopeID: String
    public let materialPath: URL
    public let owned: [KeyDrift]        // one per owned key
    // Non-owned lines are absent; sharibako doesn't inspect them.
}

public enum KeyDrift: Sendable, Equatable {
    case match(key: String)                                  // vault == file
    case fileMissing(key: String)                            // vault has it; file doesn't
    case fileValueDiffers(key: String, vaultSha256: String, fileSha256: String)
    // We do NOT surface the plaintext values in the report — surfaces retrieve
    // them explicitly with `get` if the user wants to see them.
}

public enum MaterializeResult: Sendable, Equatable {
    case wrote(path: URL, keysWritten: Int)
    case unchanged(path: URL)
    case diffPending(diff: MaterializeDiff)                  // returned when drift would be overwritten and overwriteDrift == false
}

public struct MaterializeDiff: Sendable, Equatable {
    public let scopeID: String
    public let path: URL
    public let ownedKeysDiffering: [String]  // just the names; values retrieved on demand
}

public enum UpdateResult: Sendable, Equatable {
    case updated(keysUpdated: [String])
    case noChanges
    case fileMissing(path: URL)              // marker present, `.env` absent
}
```

Names are provisional; ho-03 Think phase confirms them.

### `.env` parsing and preservation

`materialize`'s merge implementation, precisely:

1. Read the current file at the target path. If absent, treat as empty.
2. Parse into a list of `EnvLine` values, one per line, preserving each line's exact text.
3. For each owned key (from the vault filesystem):
   - Find the first line that parses as `KEY=...` for that key. Replace its rendered form with the vault's value, in a canonical `KEY=value` shape (with escaping applied per the parser's rules).
   - If no such line exists, append it at the end (after a blank-line separator if the file already had content).
4. Write the composed lines back atomically.

Non-owned lines pass through byte-for-byte. Comments, blank lines, and quote styles the user chose all survive.

### `update`'s implementation

1. Read the current `.env` at the target path.
2. Parse.
3. For each owned key: extract its parsed value from the file.
4. For each key whose file value differs from its vault value: call the Vault Core's rotate-equivalent operation. (Note: this is a value change, not a rotation-with-audit-history; it uses the same code path as `sharibako rotate` internally.)
5. Return the list of updated keys.

The `updated_at` field on the encrypted content is updated (matching `rotated_at`'s semantics). Every value change is git-committed by the caller of `update` — the Materializer itself does not touch the Conduit; commits happen at the surface layer per existing pattern.

### Ingest returns four decision types, not three

```swift
public struct ProposedScope: Sendable, Equatable {
    public let scopeID: String
    public let detectedKeys: [DetectedKey]
    public let suggestedKeysNeedingValues: [String]  // keys from .env.example with no value
    // ... other fields for name-matched shared suggestions ...
}

public enum KeyDecision: Sendable, Equatable {
    case importAsLocal(key: String, value: String)
    case linkToShared(key: String, sharedID: String)
    case moveToShared(key: String, value: String, newSharedID: String)
    case leaveAlone(key: String)   // NEW — sharibako never touches this key
    case skip(key: String)         // ambiguous fourth option — user hasn't decided; ingest re-prompts
}
```

The distinction between `leaveAlone` and `skip`: leaveAlone is a permanent decision recorded (informally, in the user's memory or a GUI checkbox state) that this key is not sharibako's business. skip is "come back to this one later." At the library level they resolve identically (no vault write), but the surfaces present them differently — leaveAlone is a confident non-choice; skip is a deferral.

## The four Q1–Q4 answers land unchanged

Locked from prior conversation (2026-07-01):

- **Q1 — drift behavior:** Refuse to overwrite silently; return `diffPending(diff:)` from `materialize` when the file has diverged on owned keys. Surface re-invokes with `overwriteDrift: true` after user confirmation. GUI presents options; CLI presents a diff and prompts.
- **Q2 — `.env.example` fallback:** Suggest as a checklist (returned in `suggestedKeysNeedingValues`), do not insert empty entries into the vault. User provides values later.
- **Q3 — name-matching for shared suggestions:** Exact match only. No fuzzy, no case-insensitive.
- **Q4 — malformed `.env` lines:** Keep going, collect warnings, surface them at the end. Do not fail ingest on a bad line.

## What stays the same

Everything not listed above stands:

- Four components: Surfaces, Vault Core, Materializer, Conduit.
- Filesystem-as-schema. `<KEY>.age` and `<KEY>.link` files under `vault/scopes/<id>/`.
- age via bundled binary, Keychain gating, git-backed vault.
- Both output verbs from kamae-2.1: `materialize` (writes file) and `run` (spawns child).
- Nothing about the Vault Core, Conduit, or the CLI's already-committed verb set changes.

## Reflected in

- **kamae-1** — `.env` framing tightened where whole-file assumption crept in. See `kamae-1-sharibako-seed.md`.
- **kamae-2** — top-of-doc pointer now names kamae-2.2 in addition to kamae-2.1. Body preserved.
- **kamae-4** — ho-03 entry updated: `update` is now a Materializer operation; ingest gains the four-way decision (with `leave alone`); materialize's contract clarifies "merges owned keys, preserves everything else." See `kamae-4-sharibako-ho-overview.md`.
- **README** — the `bento` vignette rewritten to model both workflows; CLI examples add `sharibako update`; "How Sharibako Works" paragraph clarifies the merge model. See `README.md`.
- **docs/architecture.md** — Materializer's responsibilities updated; new `update` operation surfaced. See `docs/architecture.md`.
- **SECURITY.md** — small addition on what sharibako does not touch; materialize's exposure clarified as owned-lines-only. See `SECURITY.md`.

## Open items handed to downstream hos

None blocking. Ho-03 owns:

- Confirming the exact struct/enum names above through the Think phase.
- The `.env` parser's specifics (quoting rules, `export` prefix handling, malformed-line warnings).
- Whether `EnvLine` is public or internal (probably internal; only the parsed key/value view is public).
- Whether the "leave alone" decision is persistent (recorded somewhere) or ephemeral. Ephemeral is simpler; persistent needs a `scope.yaml` field. Ho-03 Think phase decides.

Ho-04 (CLI) owns:

- The `sharibako update <scope>` command. Bare `sharibako update` without a scope: walk all local markers.
- The interactive four-option ingest matrix. Terminal ergonomics for the "leave alone" choice.

Ho-06 (GUI polish) owns:

- The ingest decision matrix as a SwiftUI flow with four choices per row.
- The drift resolver modal.

---

_Decision committed. Downstream documents updated in the same session. This file is a permanent record; not to be edited except for typographical fixes._
