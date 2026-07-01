# Sharibako — Architecture

A public extract of Sharibako's architecture. Component shape, data model, and key technical decisions. The full design document — including evaluation traces, deferred decisions, and the build sequence — lives in the project's `ho-process/` directory.

_Last revised 2026-07-01 to reflect two decisions from the same session: the injection decision (`ho-process/kamae-2.1-sharibako-injection-decision.md`) added `sharibako run` as a peer output verb alongside `sharibako materialize`; the ownership decision (`ho-process/kamae-2.2-sharibako-ownership-decision.md`) committed sharibako to per-key ownership — sharibako owns only the keys the user selected at ingest, merges owned values into `.env` on materialize, and preserves every non-owned line. A new `update` operation closes the bidirectional loop (`.env` → vault). Security implications are covered in [SECURITY.md](../SECURITY.md)._

---

## Components

Four components, sliced by purpose, not by technical layer.

```
┌────────────────────────────────────────────────────────────────┐
│                        The Surfaces                            │
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
         └──────────────────────┘  └──────────────────┘
```

### The Surfaces

Two products built from one Swift package:

- **The Workshop** — SwiftUI app for macOS Apple Silicon. The visual editor and browser.
- **The Tool** — Swift `ArgumentParser` CLI, cross-platform (macOS + Linux). The frictionless retrieval path and the deployment-side runner.

Both products share a common core library that uses the Vault Core, Materializer, and Conduit. The same operations route through the same code regardless of surface.

### The Vault Core

Owns the vault directory on disk. The filesystem is the schema — no sidecar database.

Responsibilities:

- Loading and writing scope and shared files
- Invoking `age` to encrypt and decrypt secret values
- Resolving the link graph (computed at runtime; not materialized as a manifest file)
- Surfacing structural inspection (what scopes exist, what secrets a scope has) without decryption

The Vault Core knows nothing about the user's filesystem outside the vault. It does not know where `.env` files belong.

### The Materializer

Bridges the vault and the user's filesystem — and does so with per-key ownership. Sharibako owns only the keys chosen at ingest (recorded implicitly by which `<KEY>.age` and `<KEY>.link` files exist under `vault/scopes/<id>/`); every other line in the user's `.env` is left alone.

Responsibilities:

- Reading and writing `.sharibako` marker files at project directories
- Walking configured scan roots to find markers
- Computing per-scope state — **live here**, **live elsewhere**, **orphaned**
- Ingesting existing `.env` files into proposed scope schemas for user review, with four decision types per detected key (*import as scope-local secret*, *link to shared*, *move to shared*, *leave alone*)
- **Merging owned values into `.env` on `materialize`** — replaces only the lines whose keys the scope owns; preserves comments, blank lines, non-owned key/value pairs, ordering, and user quote style exactly
- **Reading `.env` back into the vault on `update`** — the bidirectional close; picks up hand-edits to owned keys, ignores non-owned lines
- Retracting owned lines from `.env` (`sharibako clean`) — preserves the rest of the file
- Reporting per-key drift between vault and `.env` (`heal`), for owned keys only

Nothing in the Materializer ever deletes a scope automatically. Deletion is always an explicit user action and only ever touches the vault — markers on other machines become orphans on next scan, surfaced for cleanup but not destroyed. The Materializer also never touches non-owned lines: they are the user's, sharibako doesn't inspect them, doesn't report on them, doesn't delete them.

### The Runner (part of The Tool)

The second output verb. Not a separate component — implemented inside the CLI, using the Vault Core's `get_all_secrets` for its data.

Responsibilities:

- Resolve the scope (from `--scope` flag or from `.sharibako` marker walking up from cwd)
- Unlock the age key (same path as `get` and `materialize`)
- Load all secrets for the scope from the Vault Core, decrypt into memory, resolve `.link` files
- Compose child environment: parent env + scope secrets, scope wins on conflict
- `fork()` + `exec()` the child command with the composed environment
- Forward stdio (inherited FDs) and signals (SIGINT, SIGTERM, SIGHUP) to the child
- Wait for the child, exit with its status
- Best-effort in-memory scrub on all exit paths

Values live only in wrapper and child process memory. No file is written. This is the injection path that closes Class 4 (workspace file-reader) exposure for wrappable consumers. See `SECURITY.md` for the threat-model articulation.

### The Conduit

Wraps `git` for vault sync. Intentionally thin.

Responsibilities:

- `commit`, `push`, `pull`, `status` over the vault directory
- Surfacing merge conflicts when they occur

The file-per-secret structure makes most conflicts impossible by construction (different secrets are different files). Conflicts only occur when the same secret is rotated from two machines between syncs.

---

## Data Model

The filesystem layout is the complete data model. No sidecar databases, no metadata stores.

### Vault directory

```
vault/
├── .git/
├── shared/
│   ├── openai-personal.age
│   └── cloudflare-dns-token.age
└── scopes/
    └── kanyo-dev/
        ├── scope.yaml
        ├── OPENAI_API_KEY.link
        └── DATABASE_URL.age
```

Three file types:

- **`<KEY>.age`** — an age-encrypted file. Its decrypted content is a small YAML document:
  ```yaml
  value: <the actual secret string>
  notes: optional context
  rotated_at: 2026-04-15
  ```
  One file equals one secret plus its metadata. Atomic. Renamed by `mv`. Deleted by `rm`. `git log <file>` is per-secret history.

- **`<KEY>.link`** — a plaintext file, single line, containing a shared entry's ID:
  ```
  openai-personal
  ```
  When a scope's secret is linked, the `.link` file replaces the `.age` file. Resolution is filesystem-relative — the contents map to `vault/shared/<id>.age`.

- **`scope.yaml`** — plaintext per-scope metadata:
  ```yaml
  identity: kanyo-dev
  type: project-dev | project-prod | service | machine | other
  display_name: "Kanyo (dev)"   # optional
  ```

### Marker file

A `.sharibako` file at a project's root, plaintext, portable across machines:

```yaml
scope: kanyo-dev
materialize_to: ./.env    # optional, defaults to ./.env
```

The marker contains no secrets and no machine-specific paths. It is safe to commit to the project's git repository — clone the project on another machine running Sharibako, and the scope is recognized immediately.

The vault location is per-machine app configuration, not per-marker. Each machine's Sharibako app knows where its vault lives.

### Linking and the implicit link graph

The link graph is computed at runtime by walking all `vault/scopes/*/*.link` files and collecting the shared IDs they reference. There is no manifest file. To check what links to `shared/openai-personal`:

```sh
grep -r "openai-personal" vault/scopes/*/*.link
```

Rotating a shared value rewrites `vault/shared/<id>.age`. Every scope with a `.link` file pointing at that ID materializes the new value on its next materialize. The graph is the filesystem.

Linking is opt-in. Adding a secret to a new scope creates a project-local `.age` file by default; sharing across scopes is an explicit action ("link to existing shared"). Bad hygiene is possible but visible — you can see the `.link` files in any scope, and the GUI surfaces what's linked to what.

---

## Core Interaction: `sharibako init`

The init flow exercises every component end to end.

1. **The Surfaces** — the user runs `sharibako init` from a project directory (CLI) or picks a directory in the GUI. The surface hands the path to the Materializer.

2. **The Materializer** — checks for an existing `.sharibako` marker. If found, refuses ("already managed"). Otherwise proposes a scope identity from the directory's basename and parent pattern.

3. **The Vault Core** — requests Touch ID via Keychain (the vault is about to be touched). Checks for name collisions; suggests disambiguation.

4. **The Materializer** — scans the directory for existing `.env`, `.env.local`, falling back to `.env.example` for key schema. Parses found secrets. Asks the Vault Core for shared entries with name matches.

5. **The Surfaces** — present a decision per detected secret: import as project-local, link to existing shared, move to shared, or skip.

6. **The Vault Core** — creates the scope directory under `vault/scopes/`, writes `scope.yaml`, writes each secret as `<KEY>.age` (encrypted) or `<KEY>.link` (plaintext pointer) per the user's decisions.

7. **The Materializer** — writes the `.sharibako` marker file at the project root.

8. **The Materializer** — composes the full `.env` content by walking the scope's secrets and resolving links; writes the materialized file at the marker's target path; shows a diff if it would overwrite an existing different file.

9. **The Conduit** — stages, commits, and pushes the vault changes.

The same architecture handles `rotate`, `link`, `materialize`, and `sync` by composing the same components.

---

## Key Technical Decisions

### age over sops

Sops earned consideration because its value-encryption keeps YAML keys plaintext while encrypting only the values — readable diffs, mergeable across keys within a single file.

The decisive argument against sops: the file-per-secret model removes sops's job entirely. Each secret is its own atomic file; concurrent edits to different secrets are by-construction conflict-free; the value-encryption-keeps-keys-readable property is replaced by the `ls` of a scope directory showing its structure without decryption. Sops becomes a 10MB dependency earning nothing.

Sharibako uses `age` directly, bundled (~3MB), shelled out per encryption operation.

### File-per-secret over single-file scope

The `.eml` vs. `mbox` precedent. Each secret as its own file gives:

- Atomic units. `mv`, `rm`, `git log <file>` Just Work.
- Perfect merge granularity. Different secrets edited concurrently equal different files changed equal zero conflicts.
- Filesystem-level inspection without decryption.
- Renaming a secret equals renaming a file.

The cost is file count — roughly 150–300 small files for a real-scale homelab plus dev projects. The cost is purely aesthetic because the user-facing surfaces never expose the filesystem layout.

Precedent in the wild: `pass`, `gopass`, `sops-secrets-operator`. All file-per-secret.

### Swift + SwiftUI for the Mac GUI

The native Mac feel matches the soul ("calm local place"). Electron is categorically rejected. Tauri reads as morally Electron-shaped (webview-in-a-webview) and was rejected for the same reasons. Python + Qt is proven for cross-platform desktop apps (m4Bookmaker uses it) but Swift is the language target — Sharibako is sized as a first-Swift project (roughly 1,500–3,000 LOC) and serves as a learning vehicle for the Swift toolchain.

The cost of Swift + SwiftUI is platform reach: SwiftUI on Linux doesn't exist. The mitigation is that the CLI half of the same Swift package builds for Linux fine (Foundation, ArgumentParser, Process are all stable on Linux). Mac users get a GUI + CLI; Linux users get a CLI.

### Local-first git-backed substrate

The vault is a plain directory on disk. Git provides sync, history, multi-machine access, and conflict surfacing without secrets ever entering git's textual diff (each `.age` file is opaque ciphertext from git's perspective).

A remote is supported but not required. A vault works fully local; adding a remote is one configuration step.

### macOS Keychain for the age private key

The same threat model SSH keys live under. The age private key is stored in Keychain with access controlled by "Touch ID or password" per access. The vault file on disk is age-encrypted at rest; the age key is Keychain-protected; FileVault is an additional layer on top.

This is FileVault-independent — if FileVault is off, the vault is still age-encrypted and the age key is still Keychain-gated. The only plaintext-on-disk artifacts are materialized `.env` files (opt-in by verb; use `sharibako run` for wrappable consumers to avoid them entirely) and `.sharibako` markers (which contain no secret values). Both are conventionally `gitignore`d for markers of code-consuming projects, though markers may be committed deliberately when the scope name is public.

On Linux, the age key is a passphrase-protected file at a conventional path.

---

## Distribution

- **Mac:** Signed and notarized DMG distributed from the project's Cloudflare Pages site. The `.app` bundles the GUI, the CLI binary, the `age` binary, and license notices. First-run offers a one-click "Install CLI" action that symlinks the bundled CLI to `/usr/local/bin/` or `/opt/homebrew/bin/`.
- **CLI only (Mac or Linux):** Homebrew tap (`brew install sageframe-no-kaji/tap/sharibako`). Formula `depends_on "age"`. A direct `.tar.gz` is also available for users without Homebrew; it bundles `age` inside.
- **Source:** Public GitHub repo, GPL-3.0. `swift build -c release` produces the CLI; the Mac app builds via the Xcode project.

No App Store distribution. No telemetry. No auto-collected metrics. The Mac app checks a release manifest on launch for an update notification; the user clicks through to download manually.

---

## Scope Boundaries

The data model and component contracts encode several decisions that cannot be added later without redesign:

- **Single-user.** The Vault Core has no concept of "user." Multiple humans can share a vault by sharing the age key, but Sharibako does not model them as distinct identities. No permissions, no audit-by-actor, no per-user views.
- **Two output verbs, both first-class.** `materialize` writes a plaintext `.env` on disk for consumers that can't be wrapped. `run` decrypts to memory and spawns a child with values in its environment (nothing on disk). Users pick per situation. See `../ho-process/kamae-2.1-sharibako-injection-decision.md` for the decision and `../SECURITY.md` for the exposure comparison.
- **No reference-based `.env` with a Sharibako-aware loader.** Ships in neither v1 nor any planned iteration. Runtime injection covers the same threat-model territory with less coupling; per-language loader shims would be larger than the rest of v1 combined. Declined categorically.
- **No password-manager fields.** Encrypted file content is `{ value, notes?, rotated_at? }`. No login records, no cards, no identities, no SSH-key entries.
- **Mac GUI is Apple Silicon only.** No Intel Mac, no universal binary.
- **No Linux GUI.** SwiftUI does not port; no Qt/GTK alternative is pursued.
- **No Windows.** Not in v1; not in any current plan.

Future capabilities the architecture accommodates without implementing:

- Multi-root scanning (config field already `[String]`; UI just doesn't expose adding more).
- Additional materialization formats (formatter is a swappable component).
- Remote-host materialization via SSH/SCP push (extension to the Materializer's interface).
- A `sharibako-agent` daemon mirroring `ssh-agent` for CLI Touch ID friction.
- Background filesystem watching for instant marker detection.
- A web frontend wrapping the CLI as a fallback for Linux GUI or Windows users.
