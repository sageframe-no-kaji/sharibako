# Sharibako

*Sharibako is disciplined so you don't have to be.*

> Sharibako is a reliquary for digital secrets. A native Mac app and CLI that hold your API keys and env vars in a calm, age-encrypted vault — local, git-backed, and shaped to how you actually work: by project and by machine. Edit secrets in the workshop or grab them from the terminal. Materialize them as `.env` files at the right paths. Linked secrets share a value across projects — rotate once, every place updates. Good hygiene is the easy default; bad hygiene is possible but visible.

**Status:** v1 in active development. Source open under GPL-3.0. Signed binary release coming with v1.0.

---

## What's Broken

Secrets scatter because no storage you have is shaped like how you actually work.

API keys land in iCloud Keychain. Database URLs end up in `.env` files in repos. Tokens get exported in shell config. The Cloudflare DNS key lives in three places, none of them canonical. The OpenAI key gets pasted into a Claude conversation because retrieval from anywhere else is slower than typing it, and then you're supposed to rotate it — but rotation means hunting down every place it's stored, and you don't, and now it's a key you haven't rotated.

Underneath all of it is hygiene. The friction of doing it right is higher than the friction of doing it wrong. Reusing one OpenAI key across eight projects is easier than generating eight scoped keys. Pasting into a transcript is easier than retrieving from Keychain. Leaving a leaked key un-rotated is easier than rotating it. Every tool makes the wrong path the easier path.

## What Sharibako Does

A small local vault that holds your secrets in a shape that matches how you work — by **project** and by **machine**. Sharibako owns only the keys you tell it to own; the rest of your `.env` stays yours, untouched.

Two output verbs and one bidirectional-sync verb:

- **`sharibako materialize <scope>`** — merges the scope's owned keys into `.env` at the marker's target path, preserving every non-owned line (comments, blank lines, `DEBUG=true`, `PORT=3000`, whatever you have). For consumers that can't be wrapped: docker-compose services on a homelab host, systemd units, cron jobs.
- **`sharibako run [--scope <id>] -- <cmd>`** — decrypts to memory, spawns your command with the owned values set in its environment, exits when it exits. Nothing on disk. This is the right verb for interactive dev — `npm run dev`, `python app.py`, `cargo run`, `docker-compose up`.
- **`sharibako update <scope>`** — reads the current `.env`, notices which owned keys the user hand-edited in an editor, and updates the vault to match. Bidirectional close: `materialize` goes vault→file; `update` goes file→vault.

All three share the same age-decrypt path and the same Touch ID gating. Use `run` when you can; use `materialize` when the consumer needs a file; use `update` after you've been hand-editing `.env`. See [SECURITY.md](SECURITY.md) for the exposure trade-off between materialize and run.

Vocabulary:

- **Scope.** A unit that owns a set of secrets and a materialize target. A scope is a project (`kanyo-dev`), a deployed service (`paperless-on-jodo`), or a machine (`chumon-host`).
- **Secret.** A named value (encrypted) inside a scope, or in the shared pool.
- **Shared.** A pool of secrets used by more than one scope. A scope can either own a secret outright or link to one in the shared pool.
- **Link.** A pointer from a scope's secret to a shared value. Rotate the shared value once; every scope that links to it materializes the new value.
- **Marker.** A `.sharibako` file at a project's root, declaring which scope this directory belongs to and where to materialize. Committable to the project's repo — clone the project on another machine, and Sharibako there knows the scope immediately.
- **Materialize.** Write a scope's `.env` file at the marker's target path.

Each secret is an age-encrypted file in a git-backed vault. The vault is a directory on your disk you control. The age private key lives in macOS Keychain, unlocked with Touch ID — the same model as Apple Passwords and SSH keys.

## Your First Session

You drag `Sharibako.app` to Applications and open it. It asks where you keep your code — you point at `~/Projects/`. It asks where the vault should live — you accept the default. It asks for a remote git URL — you paste in your private repo, or skip.

Touch ID. The app opens to an empty vault.

In Terminal, you `cd` into a project that already has a `.env` — say `bento`, your weekend Python app. Its `.env` has five keys: `OPENAI_API_KEY`, `DATABASE_URL`, `DEBUG`, `PORT`, `NODE_ENV`. You run `sharibako init`. It reads the `.env` and asks what to do with each. For `OPENAI_API_KEY` you choose *move to shared*; `DATABASE_URL` you import as project-local; `DEBUG`, `PORT`, and `NODE_ENV` you *leave alone* — they're not secrets, and sharibako stays out of them. A `.sharibako` file appears next to `.env`. Two secrets are now in the vault, encrypted. Your other three lines in `.env` are untouched; you can still toggle `DEBUG=false` in your editor at 3 a.m. without sharibako in the loop.

A week later you start a new project, `momiji`, which also wants `OPENAI_API_KEY`. You `sharibako init` there. This time sharibako sees the shared entry and suggests linking. You accept. Both projects now point at the same value.

Tomorrow OpenAI mails you about a quota refresh and you mint a new key. You open the workshop, find `shared/openai-personal`, paste the new value, hit save. Both `bento` and `momiji` show "stale" beside their materialized `.env`. You hit *Materialize all stale*. Sharibako rewrites the `OPENAI_API_KEY` line in each project's `.env` — nothing else — and leaves your `DEBUG`, `PORT`, `NODE_ENV` as they were.

The vault commits the change. You sync. On your homelab box that pulls the vault on a cron and runs `sharibako materialize` for the services living there, the same key flows out within the hour.

_A different practitioner might import all five keys into the vault at ingest, giving sharibako the whole `.env` as a git-tracked, encrypted, sync-across-machines artifact. After editing `.env` in a scratchpad on a different machine, they'd run `sharibako update <scope>` and the vault picks up the change. Same code path, different starting checklist. Whichever pattern fits your project is the right one._

## What Sharibako Is Not

- **Not a password manager.** No website logins, no cards, no identity records, no SSH key management. Keychain and 1Password keep their jobs.
- **Not a team tool.** No RBAC, no SSO, no per-user audit log. Two humans CAN share a vault by sharing the age key — the same way SSH keys get shared — but Sharibako does not model them as distinct identities.
- **Not a reference-based `.env` loader.** Sharibako does not require project files to contain `shari://` references or ship a Sharibako-aware loader shim per language. Runtime injection via `sharibako run` covers the same ground with less coupling.
- **Not cross-platform GUI.** Mac app on Apple Silicon only. CLI on Mac + Linux. No Windows. No Linux GUI. No Intel Mac.
- **Not a key issuer.** Sharibako stores what you put in. It does not call provider APIs to mint Stripe secrets, register OAuth apps, or generate tokens.

## How Sharibako Differs

**Against PassStore** — the closest tool in market. PassStore is a polished local Mac vault for developer secrets: workspaces, environments, secret types, Touch ID, Keychain, biometric unlock. Sharibako differs on substrate and mechanism. PassStore's vault is a proprietary local database; if PassStore disappears you have a data-recovery problem. Sharibako's vault is a plain directory of `age`-encrypted files that any `age` binary can decrypt. PassStore is Mac-only; Sharibako's CLI runs on Mac and Linux, which matters for homelab deployment. And PassStore does not offer runtime injection — you copy values out of it. Sharibako's `run` verb never puts values on disk in the first place.

**Against 1Password `op run`** — the reference-and-inject pattern proven in market. `op://vault/item/field` in `.env`; `op run` resolves and injects. Sharibako learns from the *shape* of the pattern (values in memory, not on disk when possible) but rejects the account/vault-server substrate and the subscription. Ships injection without a cloud account.

**Against Infisical** — closest in spirit for developer-secret framing: self-hostable, env-var-shaped, organized by project. Structural differences: Sharibako is local-first (no service to deploy, no Postgres), git-backed by design (the vault IS a git repo of encrypted files — no database "with git as an export target"), and shaped for single-user scale (no team features, no audit-compliance overhead).

**Against dotenvx** — encrypts individual `.env` files. Sharibako manages the secrets *behind* many `.env` files, across projects and machines, with a linking model for shared values and both materialize and inject as output verbs.

**Against sops + age (CLI only)** — Sharibako builds on `age` directly (dropping sops as an intermediate layer; see docs/architecture.md), and adds the workshop UX that sops doesn't try to provide.

**Not in the same category:** Vaultwarden and 1Password (right shape for website logins, not env vars); HashiCorp Vault (enterprise scale); Doppler and EnvKey (SaaS, off the table).

## Naming

**Sharibako** (舎利箱) — *reliquary box.* A small container for sacred Buddhist relics, especially śarīra: the remaining fragments associated with an awakened teacher.

The project is a reliquary box for digital secrets. API keys, tokens, certificates, and environment variables are tiny fragments, but they carry real power — access, authority, cost, risk, and continuity. Sharibako fits because the tool is not a giant enterprise vault and not a bare command-line ritual. It is a right-sized, local, careful container for the small charged things that make your systems come alive.

A second reading lands just as cleanly. **shari** (シャリ) is also the prepared sushi rice — the container the chef reaches into for every single dish, the underlying of all preparation. Secrets play exactly that role in software: nothing ships without them, every project reaches into them, the box sits within arm's reach of the workstation. Both readings hold and both are intended. Reliquary names the *preciousness* of what's inside. Shari names the *constancy* of the reaching.

## Where Sharibako Sits

**Sageframe.** Sharibako is part of [Sageframe](https://atmarcus.net), a broader body of self-built tools, infrastructure, and methodology by Andrew Marcus.

**Ho System.** Sharibako was designed and is being built using the [Ho System](https://github.com/sageframe-no-kaji/ho-system), a structured methodology for human-AI collaborative development. The human makes every design decision; the AI implements under direction; there is verification at every step. The project's seed, system design, and ho overview live in its `ho-process/` directory.

**Dandori.** Individual build sessions are scoped by [dandori](https://github.com/sageframe-no-kaji/ho-system) — surgical agent task specs that an autonomous coding agent reads to execute one bounded unit of work, generated from the ho overview. Sharibako's hos descend into dandori specs.

**M4Bookmaker.** Sharibako follows the distribution lineage of [m4Bookmaker](https://m4bookmaker.sageframe.net) — native desktop app, signed and notarized, free source + paid binary, no App Store, a static site on Cloudflare Pages for downloads. The Swift stack and Xcode workflow are the native-Mac counterpart of m4Bookmaker's Python + Qt approach.

## How It Works

Each secret is an [age](https://github.com/FiloSottile/age)-encrypted file in a git repository. Scopes (projects, machines, services) are directories of those files; the filesystem itself is the schema, no sidecar database. Linked secrets are plaintext pointer files (`<KEY>.link`) that name a shared entry; rotation propagates through link resolution at materialize time. The age private key lives in macOS Keychain, gated by Touch ID. Sharibako shells out to the `age` binary for every encryption operation — installed from Homebrew today, bundled with the distributed app at release, the same pattern m4Bookmaker uses to wrap `ffmpeg`.

## Architecture

Four components, sliced by purpose:

- **The Surfaces.** The Workshop (SwiftUI Mac app) and the Tool (Swift CLI, cross-platform). Two products built from one Swift package, sharing the same core.
- **The Vault Core.** Owns the vault directory on disk. Handles age invocation, schema, link resolution. Knows nothing about anything outside the vault.
- **The Materializer.** Bridges the vault and the user's filesystem. Manages `.sharibako` markers, ingests existing `.env` files, writes materialized `.env` files, detects drift.
- **The Conduit.** Wraps `git` for vault sync. Knows nothing about secrets.

Full architecture extract in [`docs/architecture.md`](docs/architecture.md).

## Tech Stack

- **GUI:** Swift + SwiftUI (macOS Apple Silicon)
- **CLI:** Swift + ArgumentParser (Mac + Linux)
- **Encryption:** [age](https://github.com/FiloSottile/age) (BSD-2-Clause), shelled out; bundled with the release builds
- **Storage:** filesystem + git
- **Auth:** macOS Keychain (Mac) with Touch ID per operation; file-based age key elsewhere (see [SECURITY.md](SECURITY.md))
- **Distribution:** Signed and notarized DMG for the Mac app; Homebrew tap for the CLI on Mac + Linux

## Current State

| | |
|---|---|
| **Now** | The Tool (CLI) is complete and in daily dogfooding. The Workshop (GUI) shell is landed and dogfooded — the app opens the vault, reveals behind Touch ID, edits, materializes, and syncs. |
| **Next** | Workshop polish (ho-06): async scanning, first-run wizard, three-state glyphs, ingest flow. |
| **Later** | Linking UX across both surfaces (ho-07). Bundling, signing, installer. Website. v1.0 release. |

## What's Ahead

Items the architecture is prepared for but the v1 build does not include:

**Multi-root scanning.** v1 watches a single configured directory for `.sharibako` markers. Adding more is a config-list field that the UI just doesn't expose yet — useful for users who keep code in more than one tree.

**Remote-host materialization.** v1 materializes `.env` files at local filesystem paths only. The architecture supports an SSH/SCP-push variant of `materialize_to` for homelabbers who don't have a config-sync pipeline of their own.

**A sharibako-agent daemon.** Touch ID-per-CLI-invocation is the right model for occasional use; for heavy scripted use, an ssh-agent-style daemon that holds the unlocked age key in memory is the obvious extension.

**Web frontend wrapping the CLI.** If Linux GUI or Windows demand ever materializes, a webview wrapped around the CLI is the honest fallback. The Mac native app remains the canonical experience.

**Additional materialization formats.** v1 writes `.env`. Container secret files, raw config files, and other shapes are formatters that can be added without changing the data model.

## Download

*Not yet. The signed Mac DMG and Homebrew formula ship with v1.0; this section will fill in then. In the meantime, you can build from source — see Development below.*

## Usage

**The Workshop (GUI).** Landed with ho-05. A three-pane window over the same engine the CLI drives: scopes grouped by type in the sidebar, a scope's secrets in the center, and a detail pane where a value reveals behind Touch ID (re-masking when selection changes) with notes and per-secret rotation history from git. Add scopes, secrets, and shared entries; edit a value (a rotation) or its notes (not a rotation) as distinct acts; *Materialize* writes a scope's `.env` and refuses to overwrite drift without showing the diff; *Sync* commits and pushes; *Rescan* finds project markers. First-run setup, the three-state glyphs, and the ingest flow are ho-06; the linking picker is ho-07. Build it from `xcode/Sharibako.xcodeproj` — the signed bundle is what makes Touch ID work.

**The Tool (CLI).**

```sh
# Generate an age key (Keychain on macOS; file with --age-key)
sharibako key generate

# Bootstrap the current directory as a scope (interactive)
sharibako init

# Add a secret to a scope
sharibako add kanyo-dev DATABASE_URL --value "postgres://..."

# Print a value (Touch ID required)
sharibako get kanyo-dev OPENAI_API_KEY

# Rotate a value; rotating a linked key rotates the shared entry,
# so every scope linked to it picks up the new value
sharibako rotate momiji OPENAI_API_KEY --value "sk-new-value"

# Rotate a shared entry directly (works even when no scope links it yet)
sharibako rotate --shared openai-personal --value "sk-new-value"

# Link a scope's key to a shared entry / break the link (keeps the value)
sharibako link kanyo-dev OPENAI_API_KEY openai-personal
sharibako unlink kanyo-dev OPENAI_API_KEY

# Materialize a scope's .env (merges owned keys, preserves non-owned lines)
sharibako materialize kanyo-dev

# Run a command with the scope's owned secrets in its environment (nothing on disk)
sharibako run -- npm run dev
sharibako run --scope kanyo-dev -- docker-compose up

# Show which secrets `run` would set, without values (safe to share with an AI agent)
sharibako run --dry-run -- npm run dev

# Pull hand-edits to .env back into the vault
sharibako update kanyo-dev

# Remove sharibako-owned lines from a scope's .env (preserves user's other lines)
sharibako clean kanyo-dev

# git pull + push the vault
sharibako sync

# Find .sharibako markers below a directory (defaults to the current one)
sharibako scan ~/Projects

# List scopes and shared entries; status of the vault or one scope
sharibako list
sharibako status kanyo-dev

# Report drift between a scope's vault values and its .env (names only)
sharibako heal kanyo-dev
```

Two flags carry the CLI's consent grammar: `--force` authorizes a command's destructive variant (`add --force` overwrites an existing key, `materialize --force` overwrites drifted lines, `key generate --force` replaces your age key), and `--yes` skips an interactive confirmation (`clean --yes`, `key generate --yes`). `key generate` takes both — one to authorize the replacement, one to skip the ask. Commands that confirm interactively require `--yes` when stdin is not a terminal; declining a confirmation exits `130`.

For the difference between `materialize` and `run` and the security implications of each, see [SECURITY.md](SECURITY.md).

## Requirements

- **For the Mac app:** macOS 14+ on Apple Silicon (M1/M2/M3/M4). FileVault recommended.
- **For the CLI only:** macOS 14+ (Apple Silicon) or Linux x86_64/arm64. `age` binary (installed automatically by Homebrew; bundled in the `.tar.gz`).
- **For development:** a Swift 6 toolchain (Xcode 16+ on macOS).

## Development

```sh
git clone https://github.com/sageframe-no-kaji/sharibako.git
cd sharibako
swift build -c release
```

The CLI binary lands at `.build/release/sharibako`. On macOS, `scripts/install.sh` builds, signs, and installs it wrapped in a thin app bundle — the signed bundle is what lets the Keychain entitlement (Touch ID) work. The Workshop builds from `xcode/Sharibako.xcodeproj` (a committed, hand-authored project over the same Swift package); `swift build` still type-checks the app sources headlessly for CI. Both surfaces read the same Keychain item — a vault set up from the CLI opens in the Workshop with no re-keying.

## License

Sharibako is open source under [GPL-3.0](LICENSE). You can clone the repository, build from source, and run it freely — forever.

The signed and notarized Mac `.dmg` and the Homebrew formula are the commercial product. They're the convenience of not building it yourself and trusting an Apple-notarized binary: download, drag to Applications, open. Pricing for the binary distribution lands with the v1.0 release.

This pattern follows [m4Bookmaker](https://m4bookmaker.sageframe.net), which Sharibako uses as its distribution sibling. Open source under a non-permissive license that protects the work; paid binaries for the people who'd rather pay than build. No App Store. No telemetry. No upsell.

---

*Sharibako is a [Sageframe](https://atmarcus.net) project by [Andrew Marcus](https://atmarcus.net), built with the [Ho System](https://github.com/sageframe-no-kaji/ho-system). Last meaningful update: 2026-07-03.*
