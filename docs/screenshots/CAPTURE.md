# Screenshot capture procedure

Repeatable process for producing help-page / website screenshots of the
Sharibako Workshop by driving the signed app against a disposable sandbox
vault. First run: 2026-07-19 (ho-06.3 gate session). Re-run whenever the UI
changes, and once per appearance (light/dark via Settings ⌘,).

**The run needs 5–15 minutes of hands-off machine time.** UI scripting sends
real clicks and keystrokes through the window server — it owns the pointer
and focus while it works. There is no invisible/background mode. Schedule it
for a moment nobody is typing.

---

## 1. Sandbox

Everything lives under `/Users/atmarcus/sharibako-dogfood/` — never the real
vault (`~/.sharibako`).

```
sharibako-dogfood/
├── scratch-key.txt      # throwaway age identity (age-keygen -o scratch-key.txt)
├── vault/               # disposable vault — delete freely to reset
└── projects/            # six fake .env-bearing projects (safe to show on screen)
    ├── falcon-watch/            # pyproject; shares ANTHROPIC_API_KEY value w/ nest-cam-api
    ├── nest-cam-api/            # package.json; the shared-entry detection pair
    ├── tools/m4b-scripts/       # one level deep (candidate-walk depth)
    ├── clients/acme/acme-site/  # two levels deep, has .env.example (ignored)
    ├── glassroom-mock/          # parser torture: comments, export, quotes
    └── stray-marker-proj/       # .sharibako marker → scope: ghost-project (orphan row)
```

All values are obviously fake test strings — that is the point: the ingest
sheet shows values on screen, so real projects must never be in frame.

## 2. Environment

The GUI reads env from the launchd domain (a terminal `env VAR=… open` does
NOT reach it):

```
launchctl setenv SHARIBAKO_VAULT   /Users/atmarcus/sharibako-dogfood/vault
launchctl setenv SHARIBAKO_AGE_KEY /Users/atmarcus/sharibako-dogfood/scratch-key.txt
```

`SHARIBAKO_AGE_KEY` (the file-key dev seam) removes every Touch ID prompt —
required for unattended driving.

**Restore the real vault when done** (easy to forget, loud consequence —
the app silently opens the sandbox until you do):

```
launchctl unsetenv SHARIBAKO_VAULT
launchctl unsetenv SHARIBAKO_AGE_KEY
pkill -x Sharibako; open -a Sharibako
```

## 3. Launch / reset recipes

- Launch: `open -a /Applications/Sharibako.app` — **only** this. Running the
  bundle binary directly stopped producing windows on this machine
  (2026-07-19, cause unknown; note in K6).
- Quit: `pkill -x Sharibako`.
- Full first-run reset: `pkill -x Sharibako; rm -rf ~/sharibako-dogfood/vault;
  open -a Sharibako` (re-create `stray-marker-proj/.sharibako` with
  `scope: ghost-project` if a previous run consumed it).
- Workshop shots need a populated vault: seed via CLI
  (`env SHARIBAKO_VAULT=… SHARIBAKO_AGE_KEY=… sharibako …`) so the app opens
  past the wizard.

## 4. Driving method

- Window ID + bounds via `CGWindowListCopyWindowInfo` (swift -e one-liner);
  IDs change per relaunch — re-query every time.
- Capture: `screencapture -l<WINDOWID> NN-name.png` (keeps the shadow).
  PNGs are 2× Retina: image pixels ÷ 2 = screen points.
- **Verify every frame by reading the image back**; retake until it shows the
  intended state.
- Activate first (`tell application "Sharibako" to activate`). Wizard
  Continue = Return (key code 36); Escape (53) dismisses sheets.
- SwiftUI buttons expose no AX names on this machine — click by screen
  coordinates (window origin + offset measured from a fresh screenshot).
  Menu-bar items DO have names (`click menu item "…" of menu "Help" …`).
- Coordinate clicks must be REAL mouse events via `cliclick c:X,Y`
  (`brew install cliclick`; installed 2026-07-19) — System Events
  `click at {x,y}` hit-tests correctly but no click reaches SwiftUI on this
  build. And send every click TWICE: the first click focuses/selects
  visually, the second is what fires the app's state change (2nd-run
  finding). Sidebar re-sorts alphabetically after an ingest — re-measure row
  positions after any mutation instead of reusing stale coordinates.
- Wizard window is fixed 640×480; Workshop min 720×440 (resize to ~1100×700
  for hero shots). Sleep 1–2 s after every action.

## 5. Guardrails (protect real data)

1. **Never** click "Generate a New Key" / "Import Existing Key…", and never
   run `sharibako key generate|import`. The GUI Keychain probe is unreliable
   on this machine (2026-07-19 finding: CLI sees the real key, GUI probe
   reports not-found) and the store is delete-then-add — these actions can
   overwrite the real key.
2. Never touch `~/.sharibako`; deletions only inside the sandbox.
3. Never authenticate an unexpected system dialog — Escape and note it.
4. Wizard pages past the key page are reachable safely only via the
   read-only Help-menu tour ("Welcome to Sharibako…").

## 6. Shot list

01 wizard welcome · 02 wizard key page · 03 workshop overview (hero,
~1100×700) · 04 secret detail (fake value revealed) · 05 ingest chooser ·
06 ingest sheet (per-key decisions + values) · 07 post-ingest (new scope +
status announcement) · 08 orphan-marker row + remediation verbs ·
09–11 tour root/remote/finish · 12 Settings (appearance picker).

## 7. Delegation

The whole run is a Sonnet-class agent task: hand it this file verbatim plus
the shot list and let it verify each frame. A stopped agent keeps its
context — resume rather than restart.
