---
created: 2026-07-10
status: complete
type: ho-document
project: sharibako
ho: "05"
kamae: 5
shape: ha
builds-on:
  - ho-process/kamae-2-sharibako-system-design.md
  - ho-process/kamae-4-sharibako-ho-overview.md
  - docs/architecture.md
  - ho-process/hos/ho-04.13-run-signal-ownership.md
agent-tasks:
  - Ho-05-AT-01.md
  - Ho-05-AT-02.md
  - Ho-05-AT-03.md
---

# ho-05 — The Workshop: SwiftUI shell

Stand up `Sharibako.app` as a real three-pane SwiftUI window that opens the
existing dogfooded vault, lists it, views and edits secrets, materializes a
scope, and syncs. Every operation routes through `SharibakoCore` — the same
engine the CLI drives. This is the first surface built on top of the library
that isn't the CLI; the discipline for the whole ho is *the GUI is a surface,
not a second implementation.*

Phase 3 (the CLI) is closed and hardened through ho-04.15. ho-05 does not
reopen it. The one architectural pull toward the CLI — the Keychain reveal path
lives in `SharibakoCLI` — is resolved by giving the GUI its own small adapter
against the public `SharibakoCore` seam, touching zero CLI files (Decision 1).

**Out of scope** (all ho-06 or later):
- Three-state sidebar glyphs (live-here / live-elsewhere / orphaned) — ho-06.
- Ingest decision matrix as a GUI flow — ho-06.
- First-run wizard (vault location, scan root, remote, age-key generation +
  backup nudge) — ho-06.
- Heal / drift surface — ho-06.
- The link *target picker* and shared-secret browser — ho-07 (Phase 5). ho-05
  *displays* an existing link and can *create* a shared entry, but does not wire
  the linking interaction.
- App icon and final visual polish — a placeholder icon is fine for v0.4.

**Resolves deferred decisions** (from the ho-overview's ho-05 entry):
- macOS deployment target — 14+ (already the package floor).
- SwiftUI navigation idiom — `NavigationSplitView`.
- Secret value reveal idiom — Touch ID to reveal, stays revealed until
  selection changes (Decision 4).
- Git-log rendering for rotation history — shell out through the Conduit
  (Decision 6).

---

## Phase 1 — Think

Eight decisions before the spec lands. The heaviest is Decision 1 (it decides
the target graph and keeps the closed CLI closed); the rest follow from it.

### Decision 1 — Keychain reveal: the GUI owns a thin adapter; the CLI is untouched

The GUI's reveal/decrypt path needs the age key. The Keychain retrieval
(`KeychainAgeKeyProvider`, `AgeKeyProvider`, `KeychainProbe`, `TempKeySignalGuard`)
and vault-path resolution (`VaultLocator`) all live in `SharibakoCLI` — an
executable target the GUI cannot and should not depend on. `SharibakoCore` is
deliberately portable (Linux-buildable, no `LocalAuthentication` / `Security`).

Three options were weighed:

- **A — extract a shared macOS-auth library target** both surfaces depend on.
  The DRY answer, but it *reopens a closed, hardened, dogfooded surface* to move
  files — a real change to the CLI target for a modest de-duplication. Rejected:
  it violates forward-only for a gain that doesn't earn the risk.
- **B — fold the macOS auth into `SharibakoCore` under `#if os(macOS)`.**
  Rejected: pollutes the portable core with platform authentication and drags a
  macOS-only concern into the one target that must keep building on Linux.
- **C — the GUI owns its own thin Keychain reveal. Chosen.** The genuinely
  shared engine — vault ops, materialize, heal, sync — is *already* in
  `SharibakoCore` and the GUI reuses it as-is via the public
  `VaultCore(vaultURL:ageKeyURL:)` seam. What the CLI holds that the GUI can't
  see is a ~40-line *platform-auth adapter* (a `SecItemCopyMatching` with an
  `LAContext`, a `0600` temp file, cleanup), not vault logic. The GUI writes its
  own copy of that adapter, against the same shared Keychain item and access
  group so both surfaces unlock the same age key for the same vault. **Zero CLI
  files change.**

The duplication is a small, stable, security-reviewed adapter — accepted because
the alternative is editing a closed target. If the Keychain query ever needs to
change in both places at once, that is the moment to reconsider extraction; not
before.

**Shared Keychain item.** The GUI reads the same item the CLI writes: service
`sharibako`, account `sharibako.age-key`, access group
`3N8F759K8D.net.sageframe.sharibako`. The GUI's entitlement declares that access
group. Consequence: a vault set up via the CLI opens in the Workshop with no
re-keying, and vice versa.

### Decision 2 — App state: one `@Observable`, `@MainActor` root model

A single `WorkshopModel` (Observation framework's `@Observable`, macOS 14+),
`@MainActor`, injected once via `.environment`. It owns the resolved
configuration and constructs `VaultCore` / `Materializer` / `Conduit` per
operation from the resolved vault URL. Views read published state and call the
model's intent methods; no view touches `SharibakoCore` types directly beyond
displaying them. This is where all testable logic concentrates (Decision 8).

### Decision 3 — Vault and scan-root resolution: no wizard, no guessing

The GUI has no command-line flags and no first-run yet (first-run is ho-06), but
must find a vault and a scan root.

- **Vault path.** The GUI's own resolver mirrors the CLI's precedence, minus the
  flag: `SHARIBAKO_VAULT` environment variable, else the default
  `~/.sharibako/vault/`. If the resolved path is not an existing vault, the
  window shows a plain "no vault found" empty state naming the path it looked
  for — not a wizard, not silent creation.
- **Scan roots** (needed so Materialize can find a scope's `.sharibako` marker):
  read `scan_roots` from `~/Library/Application Support/Sharibako/config.yaml`
  if present; if absent, the Rescan action opens an `NSOpenPanel` directory
  picker and persists the chosen root to that config file. This gives a working
  Rescan and Materialize now and leaves the *default scan-root suggestion*
  (`~/Projects` vs `~/Vaults`) exactly where the overview parks it — ho-06's
  first-run design.

### Decision 4 — Secret reveal idiom: Touch ID, stays until selection changes

Values render masked by default. Revealing a value triggers Touch ID (through
the Decision 1 adapter) and the plaintext stays visible while that secret is
selected; changing selection (a different secret, a different scope) re-masks
it, and re-revealing re-authenticates. No auto-hide timer, no clipboard-clear —
those are ho-06 refinements. This matches the overview's v1 default.

### Decision 5 — Mutation boundary: CRUD and both output verbs; linking is ho-07

ho-05 carries these writes, each a direct call into `SharibakoCore`:

- Add Scope → `createScope(_:type:displayName:)`
- Add Secret (value, optional notes) → `addSecret(_:value:inScope:notes:)`
- Add Shared Entry → `addSharedEntry(_:value:notes:)`
- Edit value → `rotate(_:inScope:newValue:)` (the engine has no separate
  "edit"; changing a value *is* rotation, which is correct — it stamps
  `rotated_at`)
- Edit notes → `updateNotes(...)` (new; Decision 6)
- Materialize → `Materializer.materialize(...)`
- Sync → `Conduit.commit` + `push` / `pull`
- Rescan → `Materializer.scan(roots:)`

The **link target picker** (browse `shared/`, search, "what links here?") and the
shared-secret browser stay ho-07 — that is the parti-defining rotation-propagation
feature and Phase 5 exists to build it right across both surfaces. ho-05 *shows*
that a key is a link (from `inspect`'s `.link(sharedID:)`) and can *create* a
shared entry; it does not let you bind a scope key to a shared entry from the UI.

### Decision 6 — Two small Core additions: `Conduit.log` and `VaultCore.updateNotes`

The detail pane's rotation history and its notes editing each need a capability
the library doesn't expose yet. Both are small, belong in Core (not the view
layer), and get their own unit tests.

- **`Conduit.log(fileURL:) -> [CommitInfo]`.** Shells `git log --follow
  --format=… -- <path>` for one file and returns structured commits (short SHA,
  ISO date, subject). Keeps git inside the Conduit; the view renders the array.
  `CommitInfo` is a new `Sendable` value type in `ConduitTypes.swift`.
- **`VaultCore.updateNotes(_:inScope:notes:) throws`.** Mirrors `rotate`, but
  swaps `notes` while **preserving `value` and `rotatedAt`** — because a
  notes-only edit is not a rotation and must not bump the rotation date.
  (Overwriting via `addSecret` would re-stamp `rotated_at`; that would corrupt
  the one signal rotation tracking depends on.)

### Decision 7 — Xcode project, signing, and the file-key dev loop

- **The project.** Scaffold `xcode/Sharibako.xcodeproj` as an app target that
  depends on the local SwiftPM package's `SharibakoCore` product (Local Package
  Reference) and compiles the app's SwiftUI sources. `Package.swift` stays
  canonical for the library and the CLI; the `Sharibako` SwiftPM executable
  target is kept as a **headless compile-check** (CI and `swift build` still
  type-check the app sources without Xcode). The `.xcodeproj` is the only thing
  that produces a runnable, signable `.app` with the Keychain entitlement.
- **Signing is once per ho, not once per test.** Touch-ID reveal needs the
  signed bundle (the `keychain-access-groups` entitlement is honoured only inside
  a signed bundle — the ho-04.3 as-built lesson). But the day-to-day loop never
  signs: unit tests and an unsigned debug build both run against a **file-based
  age key** (the GUI equivalent of the CLI's `--age-key <path>`), exercising
  reveal / edit / materialize with the Keychain path bypassed. Signing +
  Keychain + Touch ID is the *final dogfood gate*, run once to close the ho.
- Signing identity, team, provisioning, and the notarization app-password come
  from `~/Vaults/sageframe-no-kaji-dev/palana`; wire them in AT-01, not before.

### Decision 8 — Coverage: logic in the model is tested; `View` structs are excluded

All branching logic lives in `WorkshopModel` and small pure helpers, unit-tested
to the project's ≥90% floor. SwiftUI `View` structs (declarative body, hard to
drive headlessly) are coverage-excluded by extending ci.yml's named-`EXCLUDED`
regex, the same convention `KeychainAgeKeyProvider|ExecReplace|TerminalDetector|
SecureValuePrompt` already uses. The GUI's own Keychain adapter joins that
excluded set (dogfood-only, like the CLI's). Every exclusion is a named file with
a comment saying why.

### Discovery (deferred to execution) — how the `.xcodeproj` is generated

Hand-authoring a `pbxproj` is error-prone; the realistic options are a
committed project created once through Xcode's own new-app template, or a
generator (XcodeGen / Tuist) checked in as the source of truth. AT-01 picks the
lightest path that yields a reproducible, committed project and does **not**
add a heavyweight build dependency without surfacing it first — see AT-01's Stop
Condition. The constraint is fixed regardless of tool: the project references
the local package, and `Package.swift` stays canonical for CLI/CI.

---

## Phase 2 — Execute

Branch `ho-05` off `main`. Three agent tasks, executed and verified in order —
each has a verification dependency on the one before (the model can't be built
without the target graph; the actions can't be tested without the read surface).

### Ho-05-AT-01 — Foundation: Xcode project, GUI Keychain adapter, WorkshopModel, sidebar
Xcode project + entitlements; the GUI's own Keychain reveal adapter (Decision 1);
`WorkshopModel` with vault/scan-root resolution (Decisions 2–3); the scope
sidebar grouped by `ScopeType`. Model: `claude-opus-4-8`.
→ `ho-process/agent-tasks/Ho-05-AT-01.md`

*Verifiable:* the app opens against the real vault (file-key dev path), lists its
scopes grouped by type, or shows the "no vault" empty state when the path is empty.

### Ho-05-AT-02 — Read + reveal: secret list, detail pane, Touch-ID reveal, history
Center secret list (from `inspect`); detail slide-in with masked value, Touch-ID
reveal (Decision 4), notes, link-target display, and rotation history via the new
`Conduit.log` (Decision 6). Model: `claude-sonnet-4-6`.
→ `ho-process/agent-tasks/Ho-05-AT-02.md`

*Verifiable:* select a scope, view its secrets, reveal a real value with the
file-key dev path, read the secret's git history.

### Ho-05-AT-03 — Write + actions: add/rotate/notes, materialize, sync, rescan
Add Scope / Add Secret / Add Shared Entry; edit value (`rotate`) and notes
(`updateNotes`, new — Decision 6); Materialize, Sync, Rescan (Decisions 3, 5).
Model: `claude-sonnet-4-6`.
→ `ho-process/agent-tasks/Ho-05-AT-03.md`

*Verifiable:* full round-trip against the vault, then the signed-install dogfood
gate (the only proof the real Keychain reveal works).

### Testing and iteration approach

Per task: the verification rhythm — `swift build -Xswiftc -warnings-as-errors` →
`swift-format lint --strict` → `swiftlint --strict` → `swift test` → coverage
≥90%. `WorkshopModel` and the Core additions (`Conduit.log`, `updateNotes`) carry
the coverage; `View` structs and the Keychain adapter are excluded by name
(Decision 8). Run `swift package clean` before Swift-touching commits — the known
SwiftPM incremental-link bug after `SharibakoCore` changes bites this ho every
time the shared model changes.

The whole session iterates against a **file-based age key and the real
(read-only-until-you-mutate) dogfooded vault**, unsigned. The signed build is
built once, at AT-03's gate.

### Done means

- The Workshop opens the existing vault, lists scopes grouped by type, and shows
  the "no vault" empty state when the resolved path holds none.
- A secret's value reveals behind Touch ID and re-masks on selection change; its
  notes, link target, and rotation history display.
- Add scope / add secret / add shared / edit value / edit notes / materialize /
  sync / rescan all work against the vault, each through `SharibakoCore`.
- No vault logic is reimplemented in the view layer; the only new non-Core code
  is the GUI Keychain adapter (Decision 1) and the view/model layer.
- **Zero files under `Sources/SharibakoCLI/` change.**
- `Conduit.log` and `VaultCore.updateNotes` exist in Core with unit tests.
- The full lint/build/test/coverage rhythm is green; coverage ≥90% with
  `View` structs + the GUI Keychain adapter excluded by name in ci.yml.
- **Dogfood gate passed** (below).

### Verification and the dogfood gate

1. The rhythm above, green, on the `ho-05` branch.
2. **Dogfood gate (signed install + Touch ID — the only thing that proves the
   real reveal path):** build and sign the `.app` (identity from palana),
   install it, open the existing vault, and reveal a real secret through Touch
   ID — not the file-key bypass. Confirm the shared-Keychain-item claim: a value
   the CLI can `get` reveals in the Workshop with the same age key, no
   re-keying. Materialize a scope from the GUI and confirm the `.env` matches
   `sharibako materialize`. Not done until this passes.

---

## Phase 3 — Reflect

*Executed 2026-07-10: three agent tasks (AT-01 Opus 4.8; AT-02/03 Sonnet 4.6)
driven sequentially by a Fable orchestrator, with the practitioner at the two
human gates. The dogfood gate ran three build-fix-rebuild rounds before
passing.*

- **Did the design hold?** Mostly — with one ratified premise failing outright.
  Decision 2's "vault ops are local and fast; keep v1 synchronous on
  `@MainActor`" is true for single-file encrypt/decrypt and false for anything
  that walks a scan root: Materialize re-resolves the scope marker by
  recursively scanning the whole configured root on the main thread, and the UI
  beach-balls for the duration. The synchronous posture is the headline
  "decision that didn't hold"; ho-06 owns moving scans off the main thread and
  caching scan results between actions. The Xcode-project discovery resolved
  cleanly: a hand-authored, committed `.pbxproj` (objectVersion 77, filesystem-
  synchronized source group), no generator dependency — AT-02/03 added files
  without touching the project, validating the choice.
- **Decision 1 review.** Held completely. The GUI adapter stayed a single file
  mirroring `loadIdentity` + a file-key dev provider; zero CLI files changed
  across all three tasks (`git diff --name-only main -- Sources/SharibakoCLI/`
  empty at every commit). The shared-Keychain-item claim proved out both
  directions at the gate: a CLI-written key revealed in the Workshop, and a
  GUI-written secret decrypted via `sharibako get` — no re-keying. No
  duplication pressure appeared; extraction stays unconsidered.
- **The dogfood gate.** Caught four real defects the green suite could not,
  reconfirming ho-04.13's lesson at GUI scale:
  1. **Notes were never displayed** — decrypted and discarded; the placeholder
     hint described a feature that didn't exist. Fixed with `revealedNotes` +
     a new public `VaultCore.getSecretContent` seam, unit-tested.
  2. **The test suite leaked into the live user config** — every `swift test`
     run appended a temp-dir scan root to the real
     `~/Library/Application Support/Sharibako/config.yaml`. Fixed by deriving
     `configURL` from the injected home; verification now includes proving the
     live config survives a test run byte-identical.
  3. **Silent outcomes read as broken buttons** — rescan, materialize
     (`.unchanged`), and sync (nothing-to-commit) all did the right thing and
     said nothing; the operator concluded three features were broken. Fixed
     with a `statusMessage` surface speaking the CLI's own vocabulary
     ("Already up to date: <path>", "Nothing to commit; no remote configured").
  4. **The production vault was never git-initialized** (the known ho-04.14-era
     scaffold gap, met in the wild): first Sync surfaced `fatal: not a git
     repository`. Repaired by hand; vault scaffolding must `git init`
     unconditionally — folded into the owed scaffold/init ho.
- **Coverage.** 94.02% total at close (floor 90%); `WorkshopModel` 91.19%,
  `WorkshopConfig` 100%. Excluded by name in ci.yml, each with a justification
  comment: `GUIAgeKeyProvider` (Keychain/dogfood-only, like the CLI's),
  `WorkshopWindow`, `ScopeSidebar`, `App.swift`, `SecretList`, `SecretDetail`,
  `AddScopeSheet`, `AddSecretSheet`, `AddSharedEntrySheet` (declarative `View`
  bodies, not headlessly drivable; their branch logic lives tested in
  `WorkshopModel`). 641 tests / 77 suites at close.
- **Followups for ho-06** (gate-driven, in rough priority):
  - Async scan/materialize + scan-result caching (the beach ball).
  - Waymarking: show the vault path/remote ("which repo am I on"), the scope's
    marker target in the detail pane, and a **jump-to-directory** button
    (own toolbar block, left of Sync) opening the marker directory in Finder.
  - Status bar announce: brief green pulse on success / red on error; align the
    status line's left edge with the sidebar's section labels.
  - Reveal ergonomics: LAContext reuse window (~2 min) so repeated reveals
    don't re-prompt; scope-level "reveal all" / materialized-`.env` preview;
    show-while-typing eye on secure input fields; consider prefilling the
    rotate field only when the value is already revealed.
  - A per-entry "plain / not really a secret" flag (URLs and container names
    are config, not secrets) — a schema decision; needs its own Think phase,
    composes with ingest-as-backup.
  - Feedback for shared-entry creation (created ✓ toast) until ho-07's browser
    makes them visible; movable/non-modal Add dialogs; visible button labels
    (hover tooltips exist but failed the operator in practice); a less
    search-like Rescan icon.
  - First-run: vault scaffolding insists on git init (with the owed scriptable
    `init`/`createVaultLayout` ho on the CLI side).

  The "no vault" empty state and `NSOpenPanel` Rescan stood in adequately —
  no pull toward building the wizard early; the pull is toward *visibility*
  (waymarking, feedback), not toward more setup flow.

---

## Appendix — fresh-session bootstrap

To execute this ho in a new Claude Code session, load and run:

```
Execute ho-05 (Think is ratified — do NOT relitigate the decisions, especially
Decision 1: the GUI owns its Keychain adapter and the CLI is NOT touched). Read:
  @ho-process/hos/ho-05-workshop-shell.md            (this doc — the plan)
  @ho-process/agent-tasks/Ho-05-AT-01.md             (foundation)
  @ho-process/agent-tasks/Ho-05-AT-02.md             (read + reveal)
  @ho-process/agent-tasks/Ho-05-AT-03.md             (write + actions)
  @Sources/Sharibako/App.swift                        (the placeholder to replace)
  @Sources/SharibakoCore/VaultCore.swift  @Sources/SharibakoCore/VaultCore+Encryption.swift
  @Sources/SharibakoCore/Materializer.swift  @Sources/SharibakoCore/Conduit.swift
  @Sources/SharibakoCLI/Support/KeychainAgeKeyProvider.swift  (the adapter to MIRROR, not import)
  @CLAUDE.md  @~/.claude/modules/languages-swift.md   (conventions)

Execute AT-01 → AT-02 → AT-03 in order (verification dependency). Signing
details come from ~/Vaults/sageframe-no-kaji-dev/palana at AT-01. Run
`swift package clean` before Swift-touching commits. Verify each task with the
lint/build/test/coverage rhythm; close the ho with the signed-install + Touch-ID
dogfood gate. Branch ho-05 off main; PR-based. Do not sign commits or PRs.
```

---

_Authored 2026-07-10 (Think phase ratified same day). Executed and reflected
2026-07-10: three agent tasks on branch `ho-05`, closed with the signed-install
+ Touch-ID dogfood gate._
