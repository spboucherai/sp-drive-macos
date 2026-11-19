<!--
SP Drive — Next Generation
File: docs/next/AUDIT-macOS.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# Audit of the macOS client — baseline 1.0 and state after phase 1 of 2.0

Date: 2026-11-19. Machine: MacBook Pro (Mac17,6), macOS 27.0, Xcode 27.2. Branch `next`.
Everything below was run on the **development variant** ("SP Drive Dev", bundle `ai.spboucher.spdrive.dev`) against the
**local test backend** (`Scripts/backend-dev.sh`, clone at `native-clients` @ 7bd8972, port 8665). The production
account, `/Applications/SP Drive.app` and its Finder location were not touched.

How to read "verified": **T** = Swift package test against the real local backend (`Scripts/t.sh`) ·
**A** = check of the in-app self-test in the signed, sandboxed app (`-spdSelfTest YES`) ·
**F** = Finder scenario through `~/Library/CloudStorage` (`Scripts/finder-scenario.sh`) ·
**S** = picture of the app's own window (`docs/next/shots/`) · **—** = not verified, said in words.

## 1. Baseline (main @ 9e27903, v1.0.0) — re-run before any change

| Check | Result |
|---|---|
| `Scripts/t.sh` | **42 / 42** in 23.5 s |
| `Scripts/build.sh Debug` | BUILD SUCCEEDED |
| Dev Finder location | registered and **enabled** on this Mac (`fileproviderctl dump`: `enabled: yes`) |

### What 1.0 had, from the code

| Area | 1.0 state | Evidence in 1.0 |
|---|---|---|
| Passkey sign-in, device link, sessions, Keychain token, Touch ID lock | implemented | T (server side), device link used daily; Touch ID sheet confirmed by the owner only |
| Browser: list (Table), grid of **system icons** (no thumbnails), breadcrumbs, search + filters | implemented | tour pictures |
| Rename, new folder, move — through **sheets** | implemented | A |
| Quick Look | `quickLookPreview` modifier, Space through `onKeyPress` | never observed on screen (TEST_REPORT §Non vérifié 5) |
| Keyboard | Space and Return through `onKeyPress` on a focusable stack; arrows only what `Table` gives; no type-select, no grid navigation, no ⌘F, no palette | not verified |
| Drag and drop | in: URLs on the browser; inside: `ItemRef` between folders; **out: none** | not verified |
| Windows | a single `Window` scene | — |
| Inspector | a `Form` with metadata; versions and sharing only through sheets | tour picture |
| Menu bar | status, 3 running transfers, quota, pause, shortcuts | never observed on screen |
| Transfers view | list + journal, pause/resume/cancel/retry | T (queue) |
| Conflicts | list with three inline buttons; "keep mine" **trashed the server's file** and renamed the copy (version history of the original left behind) | T |
| Sync engine | journal, change feed pull every 10–120 s, transfer queue with adaptive concurrency (2–6 by throughput only), token-bucket bandwidth caps, pause/resume, priority column (always 0), back-off `2·2ⁿ` s without jitter, resumable verified transfers | T (42) |
| File Provider extension | replicated, thumbnails, pinning by content policy, conflict copies | F 22 / 22 (2026-11-18) |
| Design | system defaults; one gradient mark; `.regularMaterial` cards | — |
| Localisation | French literals only — **no** `.xcstrings`, no `.lproj`: there is no English localisation in 1.0 | `find` on the repo |
| Missing in 1.0 | thumbnails in the app, drag out, command palette, multiple windows, type-select, inline rename, conflict comparison, power awareness, jitter, event listener, user-initiated priority, Finder decorations and actions, drop zone, Spotlight | — |

### Baseline measurements (1.0 Debug build of the dev variant)

| Measure | Value | How |
|---|---|---|
| Cold launch → first window on screen | **212 ms** median of 4 (376, 179, 194, 212) — **signed out** (sign-in window) | `Scripts/measure-launch.swift` (window server polled every 5 ms) |
| Memory at idle | **232 MB** `phys_footprint` (peak 293 MB), signed in, 26 s after the first sign-in and first sync | `footprint -p` |
| Listing 1,000 items from the local mirror | **5.3 ms** best of 10 (`MetadataStore.children(of:)`, unchanged code in 2.0) | test `testListing1000ItemsFromTheMirrorIsFast` |

## 2. After phase 1 (branch `next`)

### Totals

| Suite | 1.0 | Now |
|---|---|---|
| `Scripts/t.sh` (package, real backend) | 42 / 42 | **60 / 60** in ~70 s |
| In-app self-test `-spdSelfTest YES` | 19 / 19 | **45 / 45** |
| Finder scenario on the dev variant | 22 / 22 | **22 / 22** (re-run with the new extension) |
| Tour `-spdTour YES` | 22 screens | **27 screens**, no crash (after the fix of §5.1) |

### Measurements now (Debug build, dev variant, same Mac)

| Measure | Value | Comparable to baseline? |
|---|---|---|
| Cold launch → first window | **183 ms** median of 5 (164–193), signed in | Not strictly: baseline was taken signed out. See the signed-out figure in the final report of the phase |
| Memory at idle | **182 MB** `phys_footprint` 15 s after showing a 1,000-item folder ten times (peak 372 MB during that) | Roughly: different moment of the session. No regression seen; not a controlled comparison |
| Showing a 1,000-item folder (navigation → frame committed) | list **114 ms** median of 5 (104–130); grid **87 ms** (76–94) | New measure (`-spdPerf YES`); 1.0 had no probe |
| Mirror listing of 1,000 items | 5.3 ms | Same code |
| Bandwidth cap 1 MiB/s | upload 4 MiB in 4.1 s; download 6 MiB in 4.4–5.0 s; uncapped upload 0.10 s | test output |

### B. Design system v2

| Item | State | Verified |
|---|---|---|
| Token table (colour roles ×4 variants, type, spacing, radii, elevation, motion) | `docs/next/DESIGN-SYSTEM-V2.md` | — (document) |
| `SPDTheme` implementation, `spdMotion` / `spdAnimate` honouring Reduce Motion, `spdCard`, `SPDPill`, `SPDEmptyState` | `Components/Theme.swift`, used by every new view | S (light appearance) |
| Dark appearance, Increase Contrast, Reduce Motion | implemented in the tokens | **— not looked at on screen** (a launch argument did not switch the appearance; the system setting was not changed on the owner's session) |
| Contrast ratios | — | **not computed** |

### C. Interface

| Feature | State | Verified |
|---|---|---|
| Sidebar: Mon Drive, Récents, Favoris, Hors ligne · Partagés, Portails · Transferts, Conflits (only when there is one), Corbeille · Stockage; Collections and Partagés avec moi exist in code and are hidden (`isAvailable`) | done | S |
| Toolbar: back/forward, add (upload / new folder / portal), download, share, list/grid, sort, palette, inspector, search | done | S |
| Grid with real thumbnails (server thumbnail, disk + memory cache per version; Quick Look thumbnail of an existing local copy otherwise; system icon as fallback), three sizes | done | A (server thumbnail fetched and shown, 240×150), S |
| Compact list (`Table`) with thumbnails as row icons, sortable columns | done | S |
| Path bar: crumbs, folded middle beyond four levels, each crumb a drop target | done | S; folding and drop on a crumb **—** |
| Inspector: preview, quick actions, information, state on this Mac, share links, last versions, integrity | done | S |
| Context menus (items, background, trash) | done | — (not opened by a pointer) |
| Keyboard: arrows and ⇧-extension in the grid, type-select, Return = rename in place, Space = Quick Look toggle, Escape, ⌘↑ ⌘↓ ⌘[ ⌘], ⌘F, ⌘K, ⌘1 ⌘2 ⌘I | done | A for →, ⇧→, type-select, Return (field focused, rename confirmed by the server), Space (panel opens and closes), ⌘K (real menu item), menu enabling by selection. **—** for arrows in the list (left to `Table`), ⌘F, ⌘↑/⌘↓/⌘[/⌘] |
| Command palette (26 commands at the time of the test + items of the mirror) | done | A (commands run for real; a file of the mirror is found and revealed), S |
| Multiple windows (`WindowGroup`, one navigator per window, menus follow the key window) | done | A (second window opens); independent navigation in two windows **—** |
| Quick Look through `QLPreviewPanel`, source frame = the item's picture, panel follows the selection | done | A (panel shown on the selected file; a source frame inside the window is provided). The zoom itself **— not watched** |
| Drag in (Finder → folder, cell, crumb) and drag out (file delivered at drop time, verified) | done | A through the same code paths with item providers (file URLs dropped → uploaded; dragged item → file with the server's SHA-256). **A real pointer drag to and from the Finder was not performed** |
| Animated drop targets, folder transition (direction-aware), Reduce Motion forms | done | — (motion not watched) |
| Empty states with actions (drive, search, recent, favourites, offline with/without Finder location, trash, transfers, conflicts) | done | S (search-empty, recent, offline, trash, conflicts) |
| English localisation | **not done** (and absent from 1.0, contrary to the brief's assumption) | — |

### D. Sync engine 2.0 (`Sync/`, additive)

| Policy | Implementation | Test (all against the local backend unless "unit") |
|---|---|---|
| Adaptive concurrency 1–6 from throughput **and error rate** | `ConcurrencyAdvisor.record(success:)`: ≥ 3 failures and ≥ ⅓ of the last 10 → one slot back, growth waits | unit `testAdvisorGivesSlotsBackWhenTransfersKeepFailing`; live `testOutageRetries…` (measured limit drops below 3 during a real outage) |
| Bandwidth cap | existing token bucket, settings unchanged | `testBandwidthCapHoldsARealUploadAndDownload` |
| Global pause / resume | existing; now also stops the event listener | `testGlobalPauseFreezesTheServerSideOffsetAndResumeFinishes` (server-side offset frozen, same session finished) |
| Priority | `TransferPriority` (background 0, userInitiated 10, urgent 20), pre-emption of a lower running transfer, `setPriority` ("send first"); the app queues everything a person asks for as userInitiated | `testUserInitiatedTransfersPreemptAndPrecedeBackgroundOnes`, `testSendFirstReordersTheQueue` |
| Retry | `RetryPolicy` exponential, cap 10 min, ±25 % jitter | unit `testRetryPolicy…`; live `testOutageRetriesBackOffWithJitterGiveSlotsBackAndRecoverAlone` (recovers with nobody kicking the queue) |
| Battery / Low Power Mode | `PowerState` + `SystemPowerSource` (ProcessInfo + IOKit power sources); LPM or ≤ 10 % → user-initiated only, one at a time; ≤ 20 % → two | unit `testPowerStateShapesConcurrencyAndDefersBackground`; live `testLowPowerModeRunsOnlyWhatThePersonAskedForOneAtATime` with a settable source. **Real Low Power Mode of this Mac was not switched on** |
| Crash-safe resume | unchanged engine | `CrashResumeTests`: the queue runs in another process (`spdrive-cli queue-put/queue-get`), is killed with **SIGKILL** mid-transfer, a new queue finishes the same server session (upload: 5.2 of 12.6 MB already there) or continues the partial file (download: 4.0 MB partial, progress resumes above it) |
| Integrity | unchanged (SHA-256 per block and per file, atomic placement) | existing 8 transfer tests |
| Event listener | `RemoteEventSource` protocol + `EventListener` (stream when plugged in, reconnection 1 → 60 s with jitter, **30 s polling whenever the stream is not live**), `SyncEngine.setEventSource(_:)`, `SyncStatus.events` | unit ×2 with a scripted source; live `testEnginePicksUpRemoteChangesFromThePollingFallbackWithoutBeingPoked`, `testEngineFollowsAPluggedInEventStream`. **The real SSE client is phase 2** |

### E. Conflict resolution

| Item | State | Verified |
|---|---|---|
| Sheet: both versions side by side (date, size and difference, version, fingerprint, picture, Quick Look), "plus récente", identical-content notice | done | S (`E-conflict-sheet.png`, a real conflict made by the Finder scenario), A (presented) |
| Keep both / keep mine **as a new version** / keep the server's | `ConflictResolver.resolveKeepingMineAsNewVersion` | T `ConflictVersionTests` ×2 (real conflict; server version still readable in the history; copy in the trash; identical content resolved without a byte sent); A (real conflict raised by the app's own queue, then settled: 3 versions) |
| Never a silent overwrite | "upload a new version" now names the version the Mac knew (`baseVersionID`): a file changed elsewhere meanwhile raises a conflict instead of being replaced. In 1.0 this action replaced whatever was there | A |
| Second change while the person decides | the resolution upload names the version it replaces; on mismatch it throws and trashes the duplicate copy | **code path not exercised by a test** |

### F. Menu bar Command Center and transfer centre

| Item | State | Verified |
|---|---|---|
| Command Center: connection, status, live transfers (progress, speed, time left), errors with retry, conflicts with "Régler…", storage, five recent files, pause, quick upload, open, Finder | done | S of the same view hosted in a plain window (`27-menubar-command-center.png`). **The status item's own popover was not opened** |
| Transfer centre: figures, engine policy pills, filters, per-transfer actions, "send first", journal | done, same model (`AppModel.policy`, `TransferSummary`, `TransferRow`) | S with no running transfer; **not watched during a live transfer** |

### G. Finder integration

| Item | State | Verified |
|---|---|---|
| Extension still correct | — | **F 22 / 22** after the changes |
| `isShared` / `isSharedByCurrentUser` + decoration "Partagé par lien" | from the app's list of share links, passed through the mirror | `fileproviderctl evaluate` on a shared folder: `isShared = 1`, decoration `…fileprovider.shared: "Partagé par lien"` |
| Decorations "Favori" (heart badge), "Bloqué par l'antivirus" (warning badge) | declared (`NSFileProviderDecorations`) and returned | **not observed** |
| Context-menu actions: copy a share link · keep offline · stop keeping offline and free the space · show versions in SP Drive | declared (`NSExtensionFileProviderActions`) and implemented (`NSFileProviderCustomAction`) | activation rules evaluated by the system (YES / NO as expected on a folder). **None was clicked: execution not verified** |
| Progress | existing `Progress` per fetch / upload; actions report theirs | not observed |

### H. Optional — implemented, off by default

| Item | Trade-off | Verified |
|---|---|---|
| Desktop Drop Zone (`NSPanel`, non-activating, floating, movable, dims when idle, destination setting) | Always-on-top windows are intrusive: off by default, 72-pt tile, 55 % opacity at rest, never key. A floating panel is visible in every Space and over full-screen apps — some people will want it only on the desktop; not offered yet | A (off by default; shows without becoming key; hides). **No real drag onto it** |
| Core Spotlight, metadata only (title, kind, dates, path, size, extension) | With the Finder location on, macOS already indexes the same files: the app index would show duplicates. Hence off by default and described as useful only without the Finder location. No tags exist in the mirror, so none are indexed. Removed on switch-off and on sign-out | A (398 items indexed, found by name through `CSSearchQuery`, then gone after removal; attribute set has no text content). **Opening a result from the Spotlight window not verified** |

## 3. What was not done in phase 1

- English localisation (nothing to build on: 1.0 has none).
- `X-SPD-Client` header of contract §2 (belongs with the `NextTransport` of phase 2).
- Everything that needs the 2.0 endpoints: `SPDriveNext`, SSE client, content search, AI, collections, shared with me, activity, storage overview.
- README, FEATURE_MATRIX and TEST_REPORT still describe 1.0; this file is the 2.0 record for now.

## 4. Findings for the other teams

1. **Backend — a thumbnail becoming ready is not a change.** `thumb` is computed from the `previews` table; the worker
   finishing a preview does not bump the file's `rev`, so `/sync/changes` never reports it. A client that mirrored the
   file right after its upload keeps `thumb: false` for ever. The macOS app works around it (asks for the thumbnail of
   image / pdf / video / office files anyway, retries once after 20 s). Suggested for 2.0: bump `rev` (and emit the SSE
   `change`) when a preview or the antivirus verdict changes.
2. **Backend — rate limiting.** 8 parallel `spdrive-cli put` got `rate_limited` on the local testbed (seeding 1,000
   files). Fine as a protection; worth knowing for bulk imports.
3. **`SPDriveSync` public API** — additions only: `RetryPolicy`, `TransferPriority`, `PowerState`, `PowerSource`,
   `FixedPowerSource`, `SystemPowerSource`, `RemoteEvent`, `RemoteEventSource`, `EventListener`,
   `TransferQueue.Policy/policy()/setPriority/setPowerAware/setRetryPolicy`, `SyncStatus.events`,
   `SyncEngine.setEventSource`, `ConflictResolver.resolveKeepingMineAsNewVersion`; new defaulted parameters on
   `SyncEngine.init`, `TransferQueue.init`, `TransferQueue.enqueueUpload`, `ConcurrencyAdvisor.allowed`. No removal,
   no renamed symbol. `SPDriveCore` is untouched.

## 5. Defects found and fixed while testing

1. **Crash**: a text sizing itself from its container (`fixedSize(vertical:)`) inside the split view's detail made AppKit
   loop on constraints and abort when a search had no result. Empty states now use a fixed text width.
2. **Sandbox**: Quick Look and a drag to another app cannot be handed a file of the Finder location; they now get a
   verified APFS clone inside the app's container.
3. **Test**: `Process.waitUntilExit()` called from a Swift concurrency thread waited for ever once; the kill tests poll `isRunning`.
4. **Menus**: commands are now enabled from the key window's state through an `ObservableObject` bridge (verified on the
   real `NSMenuItem`s). Whether 1.0's menus re-validated correctly was not established.

## 6. Known weaknesses

- Download bandwidth cap is enforced by back-pressure: what the URL loader already buffered (about 1 MiB on loopback) arrives at once.
- The in-app pictures of the tour (`01…27`) are drawn by `cacheDisplay`: the sidebar and inspector columns come out blank
  there. `A…E` are real captures of the window.
- A pre-empted transfer that finishes at the very instant it is pre-empted may be run a second time; the server-side
  upload session and completion are idempotent, so no duplicate file results (not provoked in a test).
- The open conflict and the test folders left in the **test** account by the scenario are harmless and local.
