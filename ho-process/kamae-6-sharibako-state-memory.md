---
created: 2026-07-09
type: state-memory
project: sharibako
kamae: 6
status: living
---

# Sharibako — State Memory (Kamae 6)

This file is the build's living cross-session memory. It is hot and non-canonical: mutable, written raw, and always subordinate to the cold canonical record (git history, per-ho Reflect sections, the K4 ho overview). When this file and the cold record disagree, the cold record wins and this file is corrected to match.

---

**STATE-SUMMARY**
- **COMPLETED** — ho-05 (The Workshop: SwiftUI shell), executed 2026-07-10 on branch `ho-05`: three agent tasks (AT-01 foundation — hand-authored `xcode/Sharibako.xcodeproj`, GUI Keychain adapter, `WorkshopModel`, sidebar; AT-02 read + reveal — secret list, detail, Touch-ID reveal, `Conduit.log`; AT-03 write + actions — add/rotate/`updateNotes`, materialize with drift gate, sync, rescan). Signed-install + Touch-ID dogfood gate PASSED (shared Keychain item confirmed both directions). Gate-driven fixes landed: notes display (`getSecretContent` seam), test-isolation leak into live config.yaml, outcome messages for rescan/materialize/sync. 641 tests / 77 suites, coverage 94.02%, zero `SharibakoCLI` files changed. PR #11 MERGED to main 2026-07-10 (`7376885`); README + K4 updated to post-ho-05 truth (`cf47b8a`).
- **NEXT** — Open ho-06 (Workshop polish: first-run wizard, three-state glyphs, ingest flow, heal surface) — start from the candidate list in ho-05's Reflect, headlined by async scan/materialize (main-thread beach ball: the ratified synchronous-v1 premise failed for tree scans) and the waymarking cluster (vault-path indicator, jump-to-directory button, status light, visible labels).
- **ACTION ITEMS / BLOCKS** — Practitioner's production vault was git-initialized BY HAND this session (it predated the ho-04.14 scaffold fix); vault scaffolding must `git init` unconditionally — fold into the owed scriptable-`init`/`createVaultLayout` ho along with non-atomic `ingest` (both still owed, non-gating). Vault remote wired 2026-07-10: private `sageframe-irori/sharibako-vault`, pushed; Workshop/CLI sync now backs up for real. (Machine gotcha: `~/.ssh/config`'s `Host *` sets `User atmarcus` and first-match wins, so GitHub remotes on this machine must spell `git@github-<account>:` explicitly.) A per-entry "plain/not-secret" flag surfaced at the gate — schema decision, needs its own Think phase.
- **PROJECT LIFECYCLE** — `dev`

_Updated 2026-07-10 at ho-05 close (Fable-driven session, three delegated agent tasks). Previous entry: seeded 2026-07-09 from git history by a fleet pass._
