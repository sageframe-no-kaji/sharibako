---
created: 2026-11-05
status: decided
type: decision
project: sharibako
stage: kamae-2.3
kamae-chain: seed → system-design → injection-decision → ownership-decision → **workshop-project-first** → readme → ho-overview
supersedes: kamae-2 §2 (partial — the Workshop's "scopes grouped by type" sidebar, the Materializer's three-state model as the GUI's state model, and the closed `ScopeType` list); ho-06.3 Decision 6 (ingest as a sheet)
builds-on: kamae-1-sharibako-seed, kamae-2-sharibako-system-design, kamae-2.2-sharibako-ownership-decision, hos/ho-06.3-first-run-and-ingest (Reflect)
next: reflected in README (vocabulary, first session), kamae-4 (a new Phase-4 arc), docs/man (regenerated after the CLI rename)
---

# Sharibako — The Workshop Is Project-First (Kamae 2.3)

_A forward-only decision document. Kamae 2 §2 described the Workshop as a window onto the vault: a sidebar of scopes grouped by type, a list of the selected scope's secrets, a detail pane. Ho-05 through ho-06.7 built exactly that, and ho-06.3's gate found it unusable by its own author: "it's working as it is, but how it is is wrong." This document changes the Workshop's primary noun from the vault's (scope) to the user's (project), names the states a project can be in, fixes one vocabulary for both surfaces, and makes "which lines are secrets" an engine rule. Nothing in the vault's on-disk shape changes._

_Kamae 2's four-component slice, age-per-secret, file-per-secret, filesystem-as-schema, git-backed vault, and Keychain gating all stand. Kamae 2.1 (injection) and 2.2 (per-key ownership) stand unchanged._

---

## The job, in the practitioner's words

> Scan vaults/repos, identify secrets, offer to include them safely. Then, and only then, allow exploration and discovery of stored content, and allow a path for safe injection. It should feel simple.

Three stages in order: **Protect → Browse → Use.** The seed's success criterion 3 (a non-expert, fifteen minutes, unaided) measures the same thing. Every decision below is tested against that sentence.

## What Kamae 2 committed, and why it did not hold

Kamae 2 §2: "Left sidebar: Scopes, grouped by type (Projects, Machines, Services). Each scope shows its live/elsewhere/orphan state with a glyph." That is the vault's inventory. It answers "what is in the box?" The user's first question is "which of my projects are protected?" The two questions have different primary nouns, and a window built on the first cannot answer the second without a modal.

The three-state model (live here / live elsewhere / orphaned) is scope-centric for the same reason: it asks where a vault entry's marker is, not what standing a directory has. In practice one glyph came to cover four unrelated situations, and the state the job starts from, a project seen but not yet protected, had no home at all except inside a sheet.

`ScopeType` is a closed list of five (`project-dev`, `project-prod`, `service`, `machine`, `other`). The sidebar groups by it and the protect screen requires it. For the stated job it is noise a non-expert cannot answer.

## The decision

Five commitments.

### 1. The Workshop's primary noun is the project

The sidebar lists **projects**: folders on disk found under the scan roots, plus vault entries that have no folder on this Mac. Each row carries a **status**. The shared pool is its own section. The vault's internal grouping (scope type) is not a grouping in the window.

The window opens on the Protect stage whenever there is something to protect, and on Browse when there is not. No state requires a modal to see.

### 2. One vocabulary, ten words, both surfaces

| Word | Meaning | Replaces |
|---|---|---|
| **Project** | A folder of yours with code in it, or a vault entry standing in for a machine or service that has no folder here. | scope (in the UI and CLI; the vault directory stays `scopes/`) |
| **Secret** | A line in .env that must be protected. | secret, key |
| **Setting** | A line in .env that is fine in plain text (`PORT=3000`). The tool leaves it alone. | plain / not-really-a-secret (the parked flag) |
| **Shared secret** | One secret used by several projects. Change it once. | shared entry, shared secret, link target |
| **Vault** | The encrypted git repo where secrets live. | vault |
| **Protect** | Read a project's .env and move its secrets into the vault. | ingest, import, init |
| **Status** | Not protected · Protected · Out of date · Problem · No folder here | live here / elsewhere / orphaned / drift / unlinked marker / stray marker |
| **Write .env** | Put a project's secrets back into its .env file, touching only its own lines. | materialize |
| **Run** | Start a program with its secrets in its environment, nothing on disk. | run |
| **Sync** | Back the vault up to its git remote. | sync |

Words that no longer appear anywhere a user reads: scope, marker, materialize, ingest, drift, reconcile, orphan, stale, live, elsewhere, waymark, heal, recipient. `age` appears once, on the first-run page that installs it.

The CLI renames to match (`sharibako protect`, `sharibako write`, `sharibako status`). Old verbs stay as hidden aliases for one release so scripts keep working. Man pages regenerate from the command tree.

### 3. The states, and where each lives

| Status | Meaning | Home | Verbs offered |
|---|---|---|---|
| **Not protected** | A folder under the scan roots with a .env and nothing in the vault. | Top section of the sidebar, persistent, with a count. | Protect · Protect all |
| **Protected** | In the vault, folder present, .env matches as of the last check. | Sidebar, main section. | Write .env · Run (copy the line) · Open in Finder |
| **Out of date** | In the vault, folder present, .env differs from the vault on a line the vault owns. | Same row, status changed. | Write .env (shows the difference first) · Take the file's version |
| **Problem** | A folder claims a project the vault does not have, or its claim file is unreadable. | Sidebar, "Needs attention" section. | Protect (recreates it) · Forget this folder |
| **No folder here** | In the vault with no folder on this Mac: a server, a machine, or a project that lives elsewhere. | Sidebar, main section, with "no folder" in place of a path. | Browse · Attach a folder |

A folder outside the scan roots is not a state. Choosing one adds its parent root (or the user is asked which root to add). Whether roots are per vault or per Mac is decided in the multi-root ho and is not reopened here.

"Out of date" is checked per selected project when it is selected, inside the Touch ID reuse window, so it reads as ambient without a sweep. A whole-vault check remains as one verb.

### 4. "Which lines are secrets" is an engine rule, shared by both surfaces

When a .env is read, each line is classified as a **secret** or a **setting** before the user sees it. The classification sets the default; the user can flip any line. The rule lives in `SharibakoCore` so the CLI and the Workshop agree.

The rule, in order:

1. A key that matches a shared secret already in the vault → secret, suggested as linked to it.
2. Key shape: ends in `KEY`, `SECRET`, `TOKEN`, `PASSWORD`, `PASSWD`, `CREDENTIALS`, `PRIVATE`, `DSN`, or contains `API_` → secret.
3. Value shape: a URL with user info before `@` → secret. A bare boolean, a small integer, a filesystem path, a bare hostname, or an enum-looking word (`development`, `info`) → setting.
4. Anything else with a value longer than 16 characters and high entropy → secret. Otherwise → setting.

The exact thresholds are a ho-level call with a test corpus; the shape of the rule is decided here. "Secret or setting" is remembered per project so a later protect pass does not re-ask.

**The rule only sets defaults. The user always sees every line.** This is a security program, and a secret misfiled as a setting stays in plain text. So the review screen is never skipped, lists every line of every project including the ones classified as settings, and lets any line be flipped. "Accept the defaults" is a button on that screen after the lines are visible, not a path around it. The CLI's non-interactive mode (`--yes`) applies the defaults without review and says so in its output, line by line, because scripts cannot look.

### 5. Tags are free text with suggestions

`ScopeType` becomes a free string. The five existing values stay valid, so no vault migrates. The Workshop suggests `dev`, `prod`, `service`, `machine` and accepts anything. A tag is an optional detail on the project page, never a required field at protect time, never a grouping in the sidebar. A tag filter can arrive later if wanted.

## The window

```
┌ Projects ─────────────────┐┌ falcon-watch ──────────────────────────────┐┌ Actions ─────────┐
│ NOT PROTECTED        (3)  ││ Protected · up to date · ~/Projects/falcon  ││ Write .env       │
│  ○ acme-site     Protect  ││                                             ││ Run…             │
│  ○ m4b-scripts   Protect  ││ Secrets (3)             Settings left alone ││ Open in Finder   │
│  ○ bento         Protect  ││  ● ANTHROPIC_API_KEY  shared: anthropic     ││ ─────────────    │
│          [Protect all 3]  ││  ● CAMERA_RTSP_URL                          ││ Rescan           │
│                           ││  ● OPENWEATHER_API_KEY                      ││ Sync             │
│ PROJECTS             (4)  ││  · DETECTION_THRESHOLD   setting            ││                  │
│  ● falcon-watch           ││                                             ││                  │
│  ● glassroom-mock         ││ Use these secrets                           ││                  │
│  ▲ nest-cam-api  out of   ││  sharibako run -- <your command>    [Copy]  ││                  │
│                    date   ││  or write them to .env         [Write .env] ││                  │
│  ◌ chumon-host  no folder ││                                             ││                  │
│                           │└─────────────────────────────────────────────┘│                  │
│ NEEDS ATTENTION      (1)  │                                               │                  │
│  ? ghost-project          │                                               │                  │
│                           │                                               │                  │
│ SHARED SECRETS       (2)  │                                               │                  │
│  anthropic · openai       │                                               │                  │
└───────────────────────────┘                                               └──────────────────┘
```

The action column is contextual: three or four verbs for the selection, two for the vault. Add-by-hand (a project with no folder, a secret typed in, a shared secret) lives under one **New…** verb, not three windows.

## Protect, the flow

1. Rescan finds folders with a .env and no claim. They appear under Not protected.
2. **Protect all** classifies every line in every folder by the rule, then shows one review screen: projects down the side, every line of each with its secret/setting default, flips allowed, settings shown rather than hidden. Shared-secret matches are pre-suggested. The screen cannot be bypassed; "Accept defaults" is on it.
3. One Touch ID. Every project is created, every secret encrypted, every claim file written. One status line reports the count.
4. The projects move to the main section as Protected.

Single Protect is the same screen for one project. This replaces ho-06.3's sheet and the CLI's one-project-at-a-time `init` as the dominant path.

## What stays the same

- The vault's files on disk: `scopes/<id>/`, `<KEY>.age`, `<KEY>.link`, `shared/`, `scope.yaml`, the `.sharibako` claim file in the project. No migration.
- Every engine operation: scan, ingest, materialize, run, update, heal, link, sync, delete. They are renamed at the surfaces, not changed.
- Per-key ownership (2.2), injection (2.1), Touch ID gating, the first-run wizard's six pages (vocabulary edited), the palette and the flat grounds (06.4, 06.5), delete (06.7).
- Linking UX (shared-secret browser, link/unlink from the Workshop) stays Phase 5.

## Reflected in

- **README**: the Vocabulary section becomes the ten-word table; the first-session vignette is rewritten GUI-first.
- **kamae-4**: a new Phase-4 arc (below), placed and numbered by an overview pass.
- **docs/man**: regenerated after the CLI rename ho.
- **docs/architecture.md**: the Workshop paragraph.

## Open items handed to downstream hos

In order. Numbers are assigned by the K4 pass; `ho-06.8` was informally claimed once and is not reused.

1. **Mock gate (no ho).** Wireframes of the window above and the Protect review screen, walked by the practitioner against three scripted jobs: protect fourteen repos; find which projects use the OpenAI key; give one app its keys and run it. No dandori opens until the practitioner can narrate every row and verb without reading code.
2. **Ho A — The projects surface.** Sidebar by status, the five states with homes, contextual actions, shared section, New…. Supersedes 06.3 Decision 6.
3. **Ho B — Protect.** The classification rule in Core with a test corpus; bulk protect, one review, one Touch ID; choosing a folder outside the roots registers the root; attach a folder to a no-folder project.
4. **Ho C — Browse and Use, and the words.** The project page with both output paths; per-project up-to-date check on selection; every string in the Workshop moved to the ten words; the CLI rename with aliases; man pages and README regenerated.
5. **ho-06.6 — Multiple scan roots**, now with a surface to live in, carrying the per-vault vs per-Mac decision.
6. **The test.** No outside user is available. The checkpoint becomes: the practitioner's cold run on the scripted sandbox (`docs/screenshots/CAPTURE.md`), narrated, passes; then a beta release asks for outside help. Checkpoint 2 in kamae-4 is amended forward-only to say so.

Not in this arc: restyling, new engine capabilities, linking UX.

---

_Drafted 2026-11-05 from the UX rectification review, the ho-06.3 Reflect, and the practitioner's own statement of the job. Ratified the same day with one change: line-by-line review is never skipped._
