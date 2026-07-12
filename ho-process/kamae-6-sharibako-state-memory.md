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
- **COMPLETED** — **ho-06.5 (right-side action panel + flat palana grounds) EXECUTED, GATED, CLOSED 2026-07-11** (branch `panel-chrome`, PR opened at close). The forward-only replacement for 06.2's failed toolbar+overflow chrome: new `ActionPanel.swift` — a collapsible trailing column on flat `panelGround`, every Workshop verb always-titled in Scope/Vault/Add groups, System/Light/Dark control at the base (same `@AppStorage` as Settings); toolbar emptied to the panel toggle; collapse persists. **The whole window moved to flat palana grounds** (`ground` panes incl. the flattened sidebar, `groundDeep` status surface/footer/chips, `panelGround` for the .env preview) — the vibrancy materials are gone; the 06.4 `ground*` tokens are now SPENT. Two gate-fix rounds: (1) confirmation dialogs are untintable (rust ignored; roleless button rendered system-BLUE) → dialogs stay fully system-rendered, recorded as a platform constraint (operator: "not thrilled, but OK"); (2) **Edit Notes now authenticates on demand** via the synchronous `reveal` intent — prompts Touch ID when unrevealed, opens prefilled, never edits blind. 731 tests, 94.78% coverage (`ActionPanel` CI-excluded with justification), warnings-as-errors clean, both linters strict, zero CLI/Core files. Signed-install gate passed both appearances; sidebar fallback never fired.
- **NEXT** — **ho-06.3** (first-run wizard, age-key gen + backup nudge, GUI ingest — the Checkpoint-2 gate) after a **K4 overview pass** that marks 06.5 closed and places the new owed **delete-scope ho** (see below).
- **ACTION ITEMS / BLOCKS** — none blocking. **NEW owed ho (gate finding, operator wants it tracked): delete-scope across all three surfaces** — no delete verb exists ANYWHERE (not GUI, not CLI, not `SharibakoCore`; the system design assumed a Vault Core deletion action that ho-01 never built; only path today is hand-deleting the scope dir + commit). It is also destructive-rust's first real in-window consumer — rust is defined but has NO consumers (the census found zero in-window destructive affordances; dialogs can't take it). Still owed: **ho-06.3** (the NEXT), **ho-06.6** (multi-root scan management — the panel is its natural home, unchanged), unlinked-markers rows UI-unverified (need a gate with a stray `.sharibako`), the CLI ho (scriptable `init`, `git init`, non-atomic `ingest`), the "plain/not-secret" flag schema Think (parked, Kamae-2). Noted, unscheduled: a custom in-window confirmation surface if system dialogs keep rankling. `ScopeType` confirmed tag-only (sidebar sectioning + ingest default; no behavior). **GUI build/dogfood path:** committed `xcode/Sharibako.xcodeproj` → signed `Sharibako.app` in `/Applications`, launched from there explicitly (NOT `swift run`, NOT `install.sh`; Spotlight resurfaces stale DerivedData builds).
- **PROJECT LIFECYCLE** — `dev`

_Updated 2026-07-11 after ho-06.5 CLOSED (panel + flat grounds, gate passed, PR opened). Previous entry: ho-06.4 merged (PR #14, `60f78f2`). Before that: ho-06.2 close (PR #13); ho-06.1 (merged 2026-07-10)._
