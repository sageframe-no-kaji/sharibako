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

A small local vault that holds your secrets in a shape that matches how you work — by **project** and by **machine** — and writes them out as `.env` files where your code expects them.

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

In Terminal, you `cd` into a project that already has a `.env` — say `bento`, your weekend Python app. You run `sharibako init`. It reads the `.env`, sees three secrets — `OPENAI_API_KEY`, `DATABASE_URL`, `DEBUG` — and asks what to do with each. `OPENAI_API_KEY` name-matches a shared entry you don't have yet, so you choose *move to shared*; the other two you import as project-local. A `.sharibako` file appears next to `.env`. The secrets are now in the vault, encrypted.

A week later you start a new project, `momiji`, which also wants `OPENAI_API_KEY`. You `sharibako init` there. This time it sees the shared entry and suggests linking. You accept. Both projects now point at the same value.

Tomorrow OpenAI mails you about a quota refresh and you mint a new key. You open the workshop, find `shared/openai-personal`, paste the new value, hit save. Both `bento` and `momiji` show "stale" beside their materialized `.env`. You hit *Materialize all stale*. Done.

The vault commits the change. You sync. On your homelab box that pulls the vault on a cron and runs `sharibako materialize` for the services living there, the same key flows out within the hour.

## What Sharibako Is Not

- **Not a password manager.** No website logins, no cards, no identity records, no SSH key management. Keychain and 1Password keep their jobs.
- **Not a team tool.** No RBAC, no SSO, no per-user audit log. Two humans CAN share a vault by sharing the age key — the same way SSH keys get shared — but Sharibako does not model them as distinct identities.
- **Not a runtime injector.** Sharibako materializes `.env` files. Reading those into running processes is your loader's job (`dotenv`, `direnv`, docker-compose, whatever you use today).
- **Not cross-platform.** Mac app on Apple Silicon only. CLI on Mac + Linux. No Windows. No Linux GUI. No Intel Mac.
- **Not a key issuer.** Sharibako stores what you put in. It does not call provider APIs to mint Stripe secrets, register OAuth apps, or generate tokens.

## How Sharibako Differs

The closest existing tool in spirit is **Infisical** — self-hostable, env-var-shaped, organized by project. The differences are structural:

- **Sharibako is local-first.** No service to deploy. No Postgres. The vault is a directory on your disk.
- **Sharibako is git-backed by design.** The vault IS a git repo of encrypted files. History, sync, multi-machine, and backup all happen through git the way you already use it. There's no database "with git as an export target."
- **Sharibako is shaped for single-user scale.** No team features, no audit-compliance overhead, no enterprise complexity around the tool itself.
- **Sharibako is a native Mac app + CLI**, not a web app behind a self-hosted service.

Tools like sops, age, chezmoi, and git-crypt occupy the substrate Sharibako sits on top of. Vaultwarden and 1Password are the right shape for website logins, not env vars. HashiCorp Vault is enterprise scale. Doppler and EnvKey are SaaS.

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

Each secret is an [age](https://github.com/FiloSottile/age)-encrypted file in a git repository. Scopes (projects, machines, services) are directories of those files; the filesystem itself is the schema, no sidecar database. Linked secrets are plaintext pointer files (`<KEY>.link`) that name a shared entry; rotation propagates through link resolution at materialize time. The age private key lives in macOS Keychain, gated by Touch ID. Sharibako shells out to the bundled `age` binary for every encryption operation — the same pattern m4Bookmaker uses to wrap `ffmpeg`.

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
- **Encryption:** [age](https://github.com/FiloSottile/age) (BSD-2-Clause), bundled
- **Storage:** filesystem + git
- **Auth:** macOS Keychain (Mac) with Touch ID-per-vault-open; passphrase-protected age key (Linux)
- **Distribution:** Signed and notarized DMG for the Mac app; Homebrew tap for the CLI on Mac + Linux

## Current State

| | |
|---|---|
| **Now** | System design committed. Build scaffolding underway. |
| **Next** | Vault Core (schema, age invocation, link resolution). The Conduit (git wrapping). The Tool (CLI). |
| **Later** | The Workshop (GUI). Linking semantics across both surfaces. Bundling, signing, installer. Website. v1.0 release. |

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

**The Workshop (GUI).** Open the app. Pick or create a vault. Touch ID. Browse scopes in the sidebar; edit secrets in the center pane. Hit *Materialize* on a scope to write its `.env`. Hit *Sync* to push and pull.

**The Tool (CLI).**

```sh
# Bootstrap the current directory as a scope (interactive)
sharibako init

# Add a secret to a scope
sharibako add kanyo-dev DATABASE_URL "postgres://..."

# Print a value (Touch ID required)
sharibako get kanyo-dev OPENAI_API_KEY

# Rotate a shared value (propagates to all linked scopes)
sharibako rotate shared/openai-personal "sk-new-value"

# Materialize a scope's .env
sharibako materialize kanyo-dev

# git pull + push the vault
sharibako sync

# Rescan configured roots for markers
sharibako scan

# Status of a scope (live here / live elsewhere / orphaned)
sharibako status kanyo-dev
```

## Requirements

- **For the Mac app:** macOS 14+ on Apple Silicon (M1/M2/M3/M4). FileVault recommended.
- **For the CLI only:** macOS 14+ (Apple Silicon) or Linux x86_64/arm64. `age` binary (installed automatically by Homebrew; bundled in the `.tar.gz`).
- **For development:** Swift 5.9+, Xcode 15+ for the Mac app build.

## Development

```sh
git clone https://github.com/sageframe-no-kaji/sharibako.git
cd sharibako
swift build -c release
```

The CLI binary lands at `.build/release/sharibako`. The Mac app is built via the Xcode project — see `ho-process/` for the build flow as it lands.

## License

Sharibako is open source under [GPL-3.0](LICENSE). You can clone the repository, build from source, and run it freely — forever.

The signed and notarized Mac `.dmg` and the Homebrew formula are the commercial product. They're the convenience of not building it yourself and trusting an Apple-notarized binary: download, drag to Applications, open. Pricing for the binary distribution lands with the v1.0 release.

This pattern follows [m4Bookmaker](https://m4bookmaker.sageframe.net), which Sharibako uses as its distribution sibling. Open source under a non-permissive license that protects the work; paid binaries for the people who'd rather pay than build. No App Store. No telemetry. No upsell.

---

*Sharibako is a [Sageframe](https://atmarcus.net) project by [Andrew Marcus](https://atmarcus.net), built with the [Ho System](https://github.com/sageframe-no-kaji/ho-system). Last meaningful update: 2026-06-30.*
