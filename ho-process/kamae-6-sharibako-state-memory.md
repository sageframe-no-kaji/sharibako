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
- **COMPLETED** — **ho-06.9 (the projects surface) BUILT on branch `project-first`, not yet gated** (overnight 2026-11-05→06, three Opus agent tasks under a Fable orchestrator): project-first model (`Selection` of four kinds, `ProjectStatus` ×5, `projectSections`, candidates found in the launch scan, launch selection rule, shared IDs + link graph, keyless candidate preview); `ProjectSidebar` by status with four sections; `ProjectHeader`, `NotProtectedPage`, `ProblemPage`, `SharedSecretPage`; contextual action column (verbs per selection kind, VAULT ×4, one New… menu); ingest chooser retired. Plus **ho-06.10 AT-01**: `SecretClassifier` in Core (rule in order, 28 named reasons, protect-by-default fallback), CLI `init` shows classes and defaults from them, `--yes` prints PROTECT/LEAVE per line, non-interactive without `--yes` refuses. 1009 tests, ~96.8% coverage, linters strict-clean. App package product renamed `SharibakoApp` for Swift 6.4. Earlier the same day: kamae-2.3 ratified and merged (PR #18); PR #17 merged; tree cleaned.
- **NEXT** — **the practitioner's gate on ho-06.9**: (1) `sudo xcodebuild -runFirstLaunch` once, then the signed build from `xcode/Sharibako.xcodeproj` to `/Applications`; or use the ad-hoc dev bundle already at `~/Applications/Sharibako-dev.app` (file key only, no Touch ID). (2) The sandbox is reset and the launchd env points the app at it (`SHARIBAKO_VAULT` / `SHARIBAKO_AGE_KEY` → `~/sharibako-dogfood`; GUI `config.yaml` scan root = the sandbox, backup at `config.yaml.pre-gate.bak`). (3) Try to break it. Then: Reflect + close 06.9, PR from `project-first`, author 06.10 AT-02/AT-03 (bulk protect review screen using the classifier, free-text tags, attach folder, Choose-other registers root), then 06.11.
- **ACTION ITEMS / BLOCKS** — **Xcode 27.1 first-launch components not installed** (admin password needed; blocks `xcodebuild` and therefore the signed app and the notarization path). **Screen capture denied to the tuios/claude host** (System Settings → Privacy → Screen Recording) — the build session could not look at the window. `ci.yml` coverage step expects one test bundle; Swift 6.4 emits one per target (fix when CI moves to 6.4). Sandbox seeding gaps: no CLI verb creates a shared entry or an empty project — create `chumon-host` (New… → Project) and a shared secret (New… → Shared secret) in the app to see the "No folder on this Mac" row and the SHARED SECRETS section. Owed: 06.11 wording sweep (dialog titles, Check-all status lines); the Not-protected page's spinner on preview failure; `init` non-TTY key-generate prompt defaults to yes (CLI ho); Decision 2 rule-2 makes `API_HOST=localhost` a secret by key shape (review flips it; amend if unwanted). Restore hygiene after dogfood: `launchctl unsetenv SHARIBAKO_VAULT SHARIBAKO_AGE_KEY` and restore `config.yaml` from `.pre-gate.bak`. Standing: app icon as asset-catalog `AppIcon`; coverage exclusion-list decision; the 07-19 Keychain-probe anomaly; non-atomic ingest.
- **PROJECT LIFECYCLE** — `dev`


_Updated 2026-11-06 05:50: ho-06.9 built overnight (not gated), ho-06.10 AT-01 built, env findings. Previous: 2026-11-05 (second): kamae-2.3 ratified, K4 overview pass placed the project-first arc (06.9/06.10/06.11/06.6), Checkpoint 2 re-based. Earlier the same day: PR #17 merged, tree cleaned, UX review drafted. Previous: 2026-07-25 ho-06.3 close (first-run wizard + GUI ingest; closed on function, flow findings carried forward as a new arc). Previous entry: 2026-07-16 correction to the cold record. Before that: ho-06.7 close (2026-07-12, PR #16); ho-06.5 close (PR #15); ho-06.4 merged (PR #14, `60f78f2`); ho-06.2 close (PR #13); ho-06.1 (merged 2026-07-10)._
