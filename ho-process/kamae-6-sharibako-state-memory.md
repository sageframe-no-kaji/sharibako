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
- **COMPLETED** — **ho-06.9 CLOSED 2026-11-08** after the practitioner's gate (four in-ho gate fixes: forget-folder race, app-wide appearance, age error words, Protect a folder…). **ho-06.10 BUILT, gate open** (branch `project-first`, draft PR #19): AT-01 `SecretClassifier` + CLI `init` defaults; AT-02 project-lines model (vault keys ∪ `.env` lines, status per line, classifier defaults with session flips, Protect one/recommended/all behind one Touch ID, scope ID from the folder name, ingest sheet retired); AT-03 the one project page (red octagon + Protect N, secrets first, settings folded, `LineDetail` with the four plain-words choices, context menus, Protect all on the section header); AT-04 Unprotect, Use shared / Make shared after the fact, resilient Check all with value match against the shared pool (`VaultCore.getSharedValue`), Remote…, Scan folders… (06.6's core, pulled in), pane-local errors with a next step (`Conduit.removeRemote` added). 1076 tests, ~96.8% coverage, linters strict-clean. Signed build installed at `/Applications/Sharibako.app`, pointed at the sandbox.
- **NEXT** — **the practitioner's gate on ho-06.10**: try to break the one project page and the new verbs against the sandbox (`~/sharibako-dogfood`, env via launchd; external folder `~/sharibako-dogfood-extra/side-project`; stray marker at `projects/stray2`). Unverified on screen: the settings `DisclosureGroup` inside the selectable list (fallback: a toggled section below the list). Then Reflect + close 06.10, mark PR #19 ready, and author **ho-06.11** (the words: dialog titles "Drift detected…" / "Delete scope" / "Reconcile drifted scopes", "Materializing…", Check-all lines; CLI rename with aliases; man pages; README vocabulary + GUI-first first session). 06.6 keeps only the per-vault vs per-Mac roots decision.
- **ACTION ITEMS / BLOCKS** — none blocking. Carried: a folder with only settings sits under Not protected forever (AT-02 deviation 8 — needs a status word, e.g. "Nothing to protect"); `init` non-TTY key-generate prompt defaults to yes (CLI ho); `ci.yml` coverage step expects one test bundle (Swift 6.4 emits one per target); appearance switching "a little janky"; sandbox `acme-site` / `falcon-watch` encrypted to the July key (Delete project + protect again, or leave as the unreadable-project test case). Restore hygiene after dogfood: `launchctl unsetenv SHARIBAKO_VAULT SHARIBAKO_AGE_KEY`; `config.yaml` from `.pre-gate.bak`. Standing: app icon as asset-catalog `AppIcon`; coverage exclusion-list decision; 07-19 Keychain-probe anomaly; non-atomic ingest.
- **PROJECT LIFECYCLE** — `dev`


_Updated 2026-11-08 evening: ho-06.9 closed, ho-06.10 built (AT-01–04), gate open. Previous: 2026-11-06 05:50: ho-06.9 built overnight (not gated), ho-06.10 AT-01 built, env findings. Previous: 2026-11-05 (second): kamae-2.3 ratified, K4 overview pass placed the project-first arc (06.9/06.10/06.11/06.6), Checkpoint 2 re-based. Earlier the same day: PR #17 merged, tree cleaned, UX review drafted. Previous: 2026-07-25 ho-06.3 close (first-run wizard + GUI ingest; closed on function, flow findings carried forward as a new arc). Previous entry: 2026-07-16 correction to the cold record. Before that: ho-06.7 close (2026-07-12, PR #16); ho-06.5 close (PR #15); ho-06.4 merged (PR #14, `60f78f2`); ho-06.2 close (PR #13); ho-06.1 (merged 2026-07-10)._
