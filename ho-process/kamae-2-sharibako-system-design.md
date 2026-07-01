---
created: 2026-06-30
status: draft
type: system-design
project: sharibako
stage: kamae-2
kamae-chain: seed → **system-design** → injection-decision → readme → ho-overview
builds-on: kamae-1-sharibako-seed
next: kamae-3-sharibako-readme
superseded-in-part-by: kamae-2.1-sharibako-injection-decision (§7 "No runtime injection" line only; all other commitments stand)
---

# Sharibako — System Design (Kamae 2)

> **Reader's note (2026-07-01):** §7's line "No runtime injection... The Materializer's only output verb is `materialize`" has been superseded by [`kamae-2.1-sharibako-injection-decision.md`](kamae-2.1-sharibako-injection-decision.md). `sharibako run` is now a peer output verb alongside `sharibako materialize`, with a fourth threat-model class (workspace file-readers) documented in [`../SECURITY.md`](../SECURITY.md). All other commitments in this document — four-component slice, age-per-secret, filesystem-as-schema, git-backed, macOS Keychain gating — stand unchanged. This document is preserved as-authored to record what was decided when.

**Sharibako is disciplined so you don't have to be.**

> Sharibako is a reliquary for digital secrets. A native Mac app and CLI that hold your API keys and env vars in a calm, age-encrypted vault — local, git-backed, and shaped to how you actually work: by project and by machine. Edit secrets in the workshop or grab them from the terminal. Materialize them as `.env` files at the right paths. Linked secrets share a value across projects — rotate once, every place updates. Good hygiene is the easy default; bad hygiene is possible but visible. It is disciplined so you don't have to be.

---

## 1. Architecture Overview

Four components, sliced by purpose, not by technical layer.

```
┌────────────────────────────────────────────────────────────────┐
│                        The Surfaces                             │
│  ┌─────────────────────┐         ┌─────────────────────────┐   │
│  │  The Workshop       │         │   The Tool              │   │
│  │  SwiftUI Mac app    │         │   Swift CLI             │   │
│  │  Apple Silicon only │         │   Mac + Linux           │   │
│  └──────────┬──────────┘         └────────────┬────────────┘   │
└─────────────┼──────────────────────────────────┼───────────────┘
              │                                  │
              └────────────────┬─────────────────┘
                               │
                               ▼
                ┌──────────────────────────────┐
                │     The Vault Core           │
                │  Owns vault/ on disk.        │
                │  age encryption, schema,     │
                │  link graph resolution.      │
                └──────┬───────────────┬───────┘
                       │               │
                       ▼               ▼
         ┌──────────────────────┐  ┌──────────────────┐
         │  The Materializer    │  │   The Conduit    │
         │  Markers, ingest,    │  │  git pull/push   │
         │  materialize, heal.  │  │  of the vault.   │
         │  Bridges vault and   │  │  Knows nothing   │
         │  user filesystem.    │  │  of secrets.     │
         └──────────────────────┘  └──────────────────┘
```

One-line per component:

- **The Surfaces.** Two products (GUI on Mac; CLI on Mac + Linux) over one shared core library. Owns user interaction.
- **The Vault Core.** Owns the vault directory on disk — encrypted secrets, link graph, schema. Knows nothing about projects outside the vault.
- **The Materializer.** The bridge between the vault and the user's filesystem — markers, ingest of existing `.env` files, materialize, heal. Knows where `.env` files belong.
- **The Conduit.** Wraps `git` for vault sync. Doesn't know anything about secrets.

---

## 2. Component Breakdown

### The Surfaces

Two products from one Swift package, sharing a common library that uses Vault Core, Materializer, and Conduit.

**The Workshop (GUI).**

SwiftUI app for macOS Apple Silicon. The calm local place. A three-pane window:

- **Left sidebar:** Scopes, grouped by type (Projects, Machines, Services). Each scope shows its live/elsewhere/orphan state with a glyph.
- **Center:** the selected scope's secrets — name, link/value indicator, materialize_to target, last rotated.
- **Right (slide-in):** secret detail — value (toggle to reveal), notes, link target if any, rotation history (git log of this file).

Top-level actions: Add Scope, Add Shared Secret, Rescan, Sync.

**The Tool (CLI).**

Swift ArgumentParser, cross-platform (macOS Apple Silicon + Linux x86_64 + Linux arm64). Frictionless retrieval. Commands:

- `sharibako init` — bootstrap the current directory as a scope
- `sharibako add <scope> <KEY> <value>` — add a secret to a scope
- `sharibako get <scope> <KEY>` — print a value (Touch ID required)
- `sharibako rotate <scope_or_shared_id> <KEY> <new_value>` — rotate a value (propagates to all links)
- `sharibako link <scope> <KEY> <shared_id>` — link a scope's secret to a shared entry
- `sharibako materialize <scope>` — write the scope's `.env` at its marker's target
- `sharibako sync` — git pull + push the vault
- `sharibako scan` — rescan configured roots for markers
- `sharibako status [<scope>]` — show live/elsewhere/orphan and drift

Both products authenticate to the age key via macOS Keychain (Mac) or a passphrase-protected age key on disk (Linux). All operations route through the same shared core code.

### The Vault Core

Owns: the vault directory on disk. The filesystem IS the schema.

```
vault/
├── .git/
├── shared/
│   ├── openai-personal.age
│   ├── cloudflare-dns-token.age
│   └── tailscale-auth-key.age
└── scopes/
    ├── kanyo-dev/
    │   ├── scope.yaml
    │   ├── OPENAI_API_KEY.link
    │   ├── DATABASE_URL.age
    │   └── DEBUG.age
    ├── kanyo-prod-on-chumon/
    │   ├── scope.yaml
    │   ├── OPENAI_API_KEY.link
    │   └── ...
    └── chumon-host/
        ├── scope.yaml
        ├── TAILSCALE_AUTH_KEY.link
        └── ADMIN_PASSWORD.age
```

Three file types:

- **`<KEY>.age`** — age-encrypted YAML. Decrypted content: `{ value, notes?, rotated_at? }`. One file = one secret + its metadata, atomic.
- **`<KEY>.link`** — plaintext, single line, contains a shared entry ID (e.g., `openai-personal`). Replaces `.age` when this slot is linked to a shared value.
- **`scope.yaml`** — plaintext per-scope metadata: `{ identity, type, display_name? }`.

Operations exposed to the surfaces:

- `list_scopes()`, `list_shared()`
- `get_scope(id)` — loads `scope.yaml`, scans the scope directory for `.age` and `.link` files
- `get_value(scope_id, key)` — resolves link if any, invokes age to decrypt
- `add_secret(scope_id, key, value)` — encrypts via age, writes `<KEY>.age`
- `link(scope_id, key, shared_id)` — writes `<KEY>.link`, deletes `<KEY>.age` if it existed
- `unlink(scope_id, key)` — copies current shared value to a new `<KEY>.age`, deletes the `.link`
- `rotate(target_id, key, new_value)` — re-encrypts at the target (scope or shared)
- `inspect(scope_id)` — returns secret names and link/value status without decryption

**Link graph: implicit.** Computed at runtime by walking `scopes/*/*.link` files and collecting references. No manifest file. Orphan detection (a shared entry nothing references) is a cleanup feature.

### The Materializer

Owns: the user's filesystem — markers and materialize_to targets.

**Marker schema** — a plaintext file named `.sharibako` at a project's root:

```yaml
scope: kanyo-dev
materialize_to: ./.env       # optional, relative path, defaults to ./.env
```

Markers are **portable** (no machine-specific paths) and **committable** to the project's repo — cloning the project on another machine reveals its sharibako-managed scope automatically.

Operations:

- `scan(roots) → [marker]` — walks configured scan roots, finds `.sharibako` markers
- `status(scope_id) → live_here | live_elsewhere | orphaned` — by checking for a marker in the user's filesystem
- `ingest(directory) → ProposedScope` — reads existing `.env` / `.env.example`, parses, returns proposed import schema (which secrets, which to link to shared, which to skip) for user review and Vault Core acceptance
- `materialize(scope_id)` — reads scope from Vault Core (decrypting all `.age` and resolving all `.link`), writes `.env` at the marker's target; shows a diff if there's drift
- `heal(scope_id)` — reconciles drift between vault and marker; surfaces issues

The three-state model is computed here: a scope is `live_here` if its marker exists in a configured root; `live_elsewhere` if not (another machine owns it); `orphaned` if a marker references a scope that no longer exists in the vault.

Nothing auto-deletes. Deletion is always an explicit user action and only ever touches the vault — markers on other machines become orphans on next scan, surfaced for cleanup but not destroyed.

### The Conduit

Owns: git operations on the vault directory.

Operations:

- `commit(message)` — stage all changes in vault/, commit
- `push()` — push to configured remote (no-op if none)
- `pull()` — pull from configured remote, surfacing conflicts
- `status()` — local dirty state, remote ahead/behind

The Conduit is intentionally thin. It wraps `git`-the-binary (via `Process`); it doesn't reimplement git. It knows nothing about secrets — every change is just a file change in the vault directory.

Merge behavior: the file-per-secret structure makes most conflicts impossible by construction (different secrets = different files). Conflicts only occur when the same secret is rotated from two machines between syncs — which is rare and the failure mode (one of the rotations needs to be re-applied) is clear.

---

## 3. Core Interaction

`sharibako init` invoked from `~/Vaults/sageframe-no-kaji-dev/kanyo/`. End-to-end:

1. **The Surfaces.** CLI invoked from current working directory (`kanyo/`). GUI does the equivalent via a directory picker. Either way, hands the path to the Materializer.

2. **The Materializer** checks for an existing `.sharibako` marker. None found → proceed (if found → refuse with "already managed").

3. **The Materializer** proposes a scope identity:
   - Basename of directory → `kanyo`
   - Detects type from parent directory pattern (`~/Vaults/sageframe-no-kaji-dev/<this>/` → `type: project-dev`)
   - Asks Vault Core for name collisions; if `kanyo` exists, proposes `kanyo-dev`
   - Surfaces the proposed identity for user confirmation
   - Requests Touch ID via Keychain (vault is about to be touched)

4. **The Materializer** scans for existing secrets:
   - Reads `.env`, `.env.local`; falls back to `.env.example` for key schema if no values present
   - Parses KEY=value pairs
   - Asks Vault Core for `shared/` entries with name matches (e.g., scan finds `OPENAI_API_KEY` → check `shared/openai-personal`)

5. **The Surfaces** present the decision matrix — for each detected secret:
   - Import as new project-local secret
   - Link to an existing shared (name-matched suggestions ranked first)
   - Move to shared (create new shared entry, link this scope to it)
   - Skip

6. **The Vault Core** writes the scope to disk:
   - Creates `vault/scopes/kanyo-dev/`
   - Writes `scope.yaml` with `{ identity: kanyo-dev, type: project-dev }`
   - For each "import as local": writes `<KEY>.age` (age-encrypted `{ value, rotated_at }`)
   - For each "link to existing": writes `<KEY>.link` (plaintext ID)
   - For each "move to shared": writes `shared/<new_id>.age` AND `vault/scopes/kanyo-dev/<KEY>.link`

7. **The Materializer** writes the marker:
   - `.sharibako` (plaintext YAML) at `~/Vaults/sageframe-no-kaji-dev/kanyo/`:
     ```yaml
     scope: kanyo-dev
     ```
   - `materialize_to` omitted (defaults to `./.env`)

8. **The Materializer** rewrites `.env` at the materialize_to path:
   - Walks the scope's secrets, decrypting `.age` files and resolving `.link` targets
   - Composes the full env content
   - Shows a diff against any existing `.env` if changes are non-trivial; confirms before write

9. **The Conduit** stages the vault changes:
   - `git add vault/`
   - `git commit -m "init scope: kanyo-dev"`
   - `git push` if a remote is configured (otherwise no-op)

10. **Done.** CLI prints what was created. GUI navigates to the new scope's view.

The same architecture handles every other action — `rotate`, `link`, `materialize`, `sync` — by composing the same components. The init flow exercises all four.

---

## 4. Data Model

The filesystem layout (vault/ and markers) is the complete data model. No sidecar databases, no metadata stores.

**Marker (`.sharibako`):**

```yaml
scope: kanyo-dev
materialize_to: ./.env    # optional
```

**Scope metadata (`vault/scopes/<id>/scope.yaml`):**

```yaml
identity: kanyo-dev
type: project-dev | project-prod | service | machine | other
display_name: "Kanyo (dev)"    # optional, defaults to identity
```

**Encrypted secret (`vault/scopes/<id>/<KEY>.age` or `vault/shared/<id>.age`):**

Decrypted content:

```yaml
value: <the actual secret string>
notes: |
  Optional free-form context. Where it came from, what it's for.
rotated_at: 2026-04-15    # ISO 8601 date; updated on rotation
```

**Link (`vault/scopes/<id>/<KEY>.link`):**

Plaintext, single line:

```
openai-personal
```

The contents is the shared entry's ID — corresponds to `vault/shared/<id>.age`. Resolution is filesystem-relative.

**App config (per machine, outside the vault):**

```yaml
vault_path: /Users/atmarcus/Vaults/sageframe-no-kaji-dev/sharibako-vault
scan_roots:
  - /Users/atmarcus/Vaults/sageframe-no-kaji-dev
keychain_age_key_label: sharibako-primary-age-key
```

Stored at `~/Library/Application Support/Sharibako/config.yaml` on Mac; `~/.config/sharibako/config.yaml` on Linux.

---

## 5. Technology Stack

| Element | Choice | Rationale |
|---|---|---|
| GUI | Swift + SwiftUI | Native Mac feel; calm-workshop aesthetic; first Swift project as learning vehicle. Electron rejected categorically. Tauri rejected as morally Electron-shaped. Python + Qt rejected because Swift is the language Andrew has been waiting for. |
| CLI | Swift + ArgumentParser | Same codebase as the GUI. Swift on Linux is mature for CLI work (Foundation, ArgumentParser, Process all stable). |
| Encryption | age (BSD-2-Clause) | Modern, focused, well-audited. Chosen over sops to drop a 10MB layer and simplify the crypto path. File-per-secret model needs no sops; the linking is filesystem-native. |
| Storage substrate | git + plain filesystem | Filesystem IS the schema (the .eml precedent). git provides sync, history, conflict surfacing — without secrets ever entering git's textual diff (each `.age` file is opaque ciphertext). |
| Authentication | macOS Keychain on Mac; passphrase on Linux | Touch ID per vault open mirrors Apple Passwords. Same threat model SSH keys live under, well-understood, accepted. |
| Distribution (Mac GUI) | Signed/notarized DMG via Cloudflare Pages | M4Bookmaker pattern. Direct download, paid binary. No App Store. |
| Distribution (CLI) | Homebrew tap | `brew install sageframe-no-kaji/tap/sharibako` — works on Mac and Linux. Formula declares `depends_on "age"` so Homebrew handles age installation. Direct `.tar.gz` for non-Homebrew users (bundles age inside). |
| Bundled binaries (Mac DMG) | age binary in `Sharibako.app/Contents/Resources/` | Same pattern as M4Bookmaker bundling ffmpeg. Xcode signs as part of the bundle during notarization. |
| Signing | Existing Apple Developer Program | Reused from M4Bookmaker; same cert can sign multiple products. |

**Non-obvious evaluations:**

- **age over sops.** Sops earned consideration because of value-encryption (keys plaintext in YAML, only values encrypted — readable `git diff`, mergeable across keys within a file). The decisive argument: file-per-secret removes sops's job entirely. Each secret is its own atomic file; concurrent edits to different secrets are by-construction conflict-free; the value-encryption-keeps-keys-readable property is replaced by the `ls` of a scope directory showing its structure. Sops becomes a 10MB dependency earning nothing.
- **File-per-secret over single-file scope.** The `.eml` vs. `mbox` precedent: atomic, filesystem-native, perfect merge granularity, drop-in operations (rename, delete, log per-file). Cost is file count — ~150-300 small files at Andrew's scale — but the user-facing surfaces (GUI, CLI) abstract the filesystem entirely. Cost is purely aesthetic when nothing browses the raw directory.
- **Swift over Python + Qt or Rust + something.** Python + Qt is proven (M4Bookmaker), but Swift is the deliberate learning target. Rust's GUI ecosystem (Tauri, egui, Iced) is not where SwiftUI is for native Mac feel. Sharibako is sized as a first-Swift-project learning vehicle (~1,000–3,000 LOC).

---

## 6. Deployment Model

**Mac (GUI + CLI):**
- Signed and notarized DMG distributed from `sharibako.sageframe.net` (Cloudflare Pages).
- `.app` bundles: the Swift GUI binary, the `sharibako` CLI binary, the `age` binary, license notices.
- First-run: user is offered a one-click "Install CLI" action that symlinks `Sharibako.app/Contents/Resources/sharibako` to `/usr/local/bin/sharibako` (or `/opt/homebrew/bin/sharibako` if it exists).
- Updates: app checks a release manifest on Cloudflare Pages on launch; in-app "Update Available" with download link.

**CLI only (Mac or Linux):**
- Homebrew tap at `sageframe-no-kaji/tap`. Install: `brew install sageframe-no-kaji/tap/sharibako`. Formula `depends_on "age"`.
- Direct `.tar.gz` from `sharibako.sageframe.net` for non-Homebrew users. Contains: `sharibako` binary, `age` binary (architecture-specific), README, LICENSE, NOTICES.

**Distribution shape:**
- Open source on `github.com/sageframe-no-kaji/sharibako`, GPL-3.0.
- Source build: `swift build -c release` from a clone. Free.
- Paid signed DMG: download from the website. The signed/notarized convenience is the commercial product.
- Pricing TBD — deferred to a Ship-phase ho.

**Signing infrastructure:**
- Apple Developer Program (already active for M4Bookmaker). Same Developer ID cert signs sharibako's builds.
- Notarization via the existing M4Bookmaker workflow, adapted for native Xcode (replacing PyInstaller's notarization shape).

**No App Store distribution.** No sandboxing constraints. Bundled executables are allowed and signed as part of the notarized bundle.

---

## 7. Scope Boundaries

The seed's scope list, restated as architectural commitments — what the code structurally prevents.

### MVP Architectural Commitments

- **Single-user data model.** The Vault Core has no concept of "user." Permissions, audit-by-actor, and identity management cannot be added without a schema redesign. Multiple humans CAN share a vault by sharing the age key (the SSH-keys-shared-among-humans model); they are not distinguished by sharibako.
- **No runtime injection.** The Materializer's only output verb is `materialize` (write `.env` file). It exposes no API for injecting env vars into running processes.
- **No password-manager fields.** Schema for an encrypted file is `{ value, notes?, rotated_at? }`. No login records, cards, identities, SSH key fields. Cannot be added without expanding the schema.
- **Single scan root.** Config field is `[String]` but UI only exposes adding one. Multi-root deferred to a specific ho.
- **Mac GUI is Apple Silicon only.** The GUI build target excludes Intel. No universal binary.
- **No Windows.** No Swift-on-Windows build is attempted.
- **No Linux GUI.** SwiftUI is not portable; no GTK/Qt alternative is pursued.
- **No materialization format other than `.env`.** The Materializer hardcodes the formatter for v1. Adding new formats requires extending its interface.

### Architecturally Prepared For (Not Built)

- **Multi-root scanning.** `scan_roots: [String]` already in config; UI just doesn't expose adding more than one.
- **Background filesystem watching** (FSEvents on Mac). The `scan` operation is invokable from anywhere; MVP just triggers it manually (app launch, "Rescan" button).
- **Additional materialization formats.** The Materializer's formatter is a swappable component; new formats can be added without schema changes.
- **Remote-host materialization.** The Materializer's interface could grow `materialize_to_remote(host, path)` operations that SSH out. Not in MVP — sageframe-config-style deploy pipelines handle this externally.
- **A `sharibako-agent` daemon.** Mirroring `ssh-agent` for CLI Touch-ID-per-invocation friction. Can be added without changing the data model — the daemon would just hold the unlocked age key in memory and answer requests over a local socket.
- **Web frontend wrapping the CLI** (Tauri-shaped). If Windows / Linux GUI demand ever materializes, a webview around the CLI is a real fallback. Not pursued.
- **Cross-vault sharing.** A scope could theoretically reference a value in a different vault repo. Not modeled, but the filesystem layout doesn't prevent it.

---

## Provisional Ho Sequence

Subject to refinement in Kamae 4 (Ho Overview). Phases:

| Ho | Stage | Title | Purpose |
|---|---|---|---|
| ho-00 | setup | Project scaffolding | Swift package, signing setup, GitHub repo, CI, baseline tests |
| ho-01 | shu | Vault Core — schema + age | Filesystem layout, age invocation, encrypt/decrypt round-trips, scope/secret operations (no UI) |
| ho-02 | shu | The Conduit — git wrapping | git pull/push/commit/status over the vault directory |
| ho-03 | ha | The Materializer — markers, ingest, materialize | Marker read/write, `.env` parsing, ingest flow, `.env` writing, drift detection |
| ho-04 | ha | The Tool (CLI) — first usable shape | `init`, `add`, `get`, `materialize`, `sync`, `scan`, `status` commands wired to the core |
| ho-05 | ha | The Workshop (GUI) — MVP shell | SwiftUI window, scope sidebar, secret editing, materialize button, sync button |
| ho-06 | ha | GUI polish — three-state UI, ingest flow, first-run | Live/elsewhere/orphan glyphs, ingest decision matrix, first-run setup wizard, age key generation + backup nudge, heal surface |
| ho-07 | ri | Linking semantics — UI + CLI | Link/unlink commands, GUI link target picker, shared-secret browser, rotation propagation surface |
| ho-08 | ri | Bundling, signing, installer | Xcode notarization workflow, DMG with bundled age, Homebrew formula, Linux .tar.gz |
| ho-09 | ri | Website + first release | sharibako.sageframe.net (Cloudflare Pages), release manifest, in-app update check, v1.0 release |

Estimated total scope: ~1,500–3,000 LOC of Swift across all hos. Calibrated to a first-Swift learning curve.

---

## Deferred Decisions

Each open question is assigned to a specific ho with evaluation criteria.

| # | Question | Deferred to | Evaluation criteria |
|---|---|---|---|
| 1 | Pricing model for the signed DMG | ho-09 (Website + release) | Survey of comparable indie Mac tools; choose one of one-time / donation / patron / per-major-version |
| 2 | Backup nudge UX for age key generation | ho-06 (GUI polish) | Mockup in hand; test against vibe-coder usability (15-minute install success criterion) |
| 3 | `sharibako-agent` daemon for CLI Touch ID friction | Post-MVP | Need CLI to be in regular use first; defer until friction is felt |
| 4 | Multi-root scanning UI | Post-MVP | Single root is sufficient until proven otherwise by personal use |
| 5 | Additional materialization formats beyond `.env` | Post-MVP | Wait for concrete user request with a non-`.env` consumer |
| 6 | Remote-host materialization (SSH/SCP push) | Post-MVP | `sageframe-config-sync` and equivalents cover this externally; revisit if vibe-coder audience needs it |
| 7 | Conflict resolution UI for git pulls | ho-02 (Conduit) | Basic surfacing in ho-02; UI polish if and when conflicts happen in practice |
| 8 | Shared-vault use documentation (silent vs. explicit) | ho-09 (Website + release) | Content decision, not architecture. Default plan: document it briefly as "two humans sharing one age key works fine; no team features." |
| 9 | First-run experience full design | ho-06 (GUI polish) | "Where do you keep code?" + "Where should the vault live?" + "Optional remote" — design in mockup |
| 10 | Import flows from Vaultwarden / iCloud Keychain | Post-MVP | `.env` ingest is the v1 import story; other sources are second-wave |
| 11 | Auto-update mechanism specifics | ho-09 | Simple manifest-on-Cloudflare check on launch; defer Sparkle vs. custom decision until ho-09 |

---

_System Design complete. Next document: Kamae 3 (README), to be drafted in a fresh session against this document._
