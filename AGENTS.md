# AGENTS.md

This file provides repository guidance for coding agents. Follow it when inspecting, changing, testing, or operating this codebase.

## Table of Contents

- [What This Is](#what-this-is)
- [Build & Run Commands](#build--run-commands)
- [Pull Requests](#pull-requests)
- [Architecture](#architecture)
  - [Package Structure](#package-structure)
  - [Source Layout](#source-layout)
  - [Key Design Patterns](#key-design-patterns)
- [Private APIs](#private-apis)
  - [Cross-Space Window Activation Flow](#cross-space-window-activation-flow)
  - [Moving Windows Between Spaces via Mission Control Drag](#moving-windows-between-spaces-via-mission-control-drag)
  - [Cross-Space Window Activation Requires .app Bundle](#cross-space-window-activation-requires-app-bundle)
- [Key Constraints](#key-constraints)
- [Known Limitations](#known-limitations)
  - [Space Names Cannot Be Read or Set via API](#space-names-cannot-be-read-or-set-via-api)
  - [Moving Windows Between Spaces — CGS APIs Blocked, MC Drag Works](#moving-windows-between-spaces--cgs-apis-blocked-mc-drag-works)
  - [Opening New Windows on a Specific Space](#opening-new-windows-on-a-specific-space)

---

## What This Is

Spaceballs is a macOS window switcher app inspired by [Contexts](https://contexts.co) — a fast, keyboard-driven way to navigate between windows across Spaces. It provides per-window (not per-app) listing, Space-aware organization with MRU ordering, cross-space window activation, window-to-space moving, and a configurable floating panel UI.

## Build & Run Commands

All commands use `make`. The build requires `--disable-sandbox` for CGS access.

```bash
make build        # Debug build only
make release      # Release build only
make bundle       # Debug build + bundle .build/debug/Spaceballs.app and Spaceballs-CLI.app
make bundle-release # Release build + bundle .build/release/Spaceballs.app and Spaceballs-CLI.app
make dist         # Build release archive; notarizes when credentials are configured
make everything   # Kill + install + open /Applications/Spaceballs.app
make run          # Build + run CLI (text output)
make run.json     # Build + run CLI (JSON output)
make kill         # Kill running Spaceballs
make test         # Run tests
make format       # Format with swift-format
make lint         # Lint with swift-format
make install      # Release bundle + install GUI app, CLI app, and CLI symlink
make clean        # Remove .build/ and dist/
```

Underlying tool: Swift Package Manager (`swift build`, `swift test`, etc.).

**After finishing any requested code change, automatically run `make everything` to install it.**

## Pull Requests

Every PR body must follow `.github/pull_request_template.md`: fill in its sections (Fixes, Related, TLDR, Summarized Work, Operational Impact) and write "None" in a section that has nothing rather than dropping it. `gh pr create --body`/`--body-file` bypasses the template, so read the file and reproduce its structure yourself before opening or editing a PR. Prefix each issue under Fixes with `Fixes` so it closes on merge, and cite the abbreviated commit SHAs (plain text, not inline code) that contributed to each Summarized Work item.

## Architecture

### Package Structure

Four targets in `Package.swift`:

| Target | Type | Purpose |
|---|---|---|
| `SpaceballsCore` | Library | Space/window enumeration, activation, private API bindings |
| `SpaceballsGUILib` | Library | View model, settings store, space name store (testable) |
| `spaceballs` | Executable | CLI tool (ArgumentParser) |
| `spaceballs-gui` | Executable | GUI app (NSApplication accessory) |

### Source Layout

```
Sources/
├── SpaceballsCore/          # Reusable library — no UI dependency
│   ├── PrivateCGS.swift         # CGS type definitions & @_silgen_name bindings
│   ├── PrivateSkyLight.swift    # SkyLight process/window activation APIs
│   ├── PrivateAX.swift          # Accessibility framework bindings
│   ├── SpaceManager.swift       # Core logic: enumeration, activation, close, quit, move
│   ├── SystemDataSource.swift   # Protocol for CGS data abstraction (testable)
│   ├── CGSDataSource.swift      # Real CGS implementation
│   └── WindowActivationError.swift
├── SpaceballsGUILib/        # Testable view model layer
│   ├── SwitcherViewModel.swift  # ObservableObject: sections, selection, MRU, search
│   ├── AppSettings.swift        # UserDefaults-backed settings (color, text, opacity)
│   └── SpaceNameStore.swift     # Custom space name persistence (UUID → name)
├── SpaceballsGUI/           # GUI app — AppKit + SwiftUI
│   ├── main.swift               # Entry point: NSApp.accessory + AppDelegate
│   ├── AppDelegate.swift        # Panel lifecycle, multi-display, key interception
│   ├── KeyInterceptor.swift     # CGEvent tap: Cmd+Tab/`/W/Q/M/,/Esc
│   ├── SwitcherPanel.swift      # Floating NSPanel configuration
│   ├── SwitcherView.swift       # Root SwiftUI view (sections + settings row)
│   ├── SwitcherRowView.swift    # Window row + section header views
│   ├── SettingsView.swift       # Sidebar-navigated settings container
│   ├── SettingsWindowController.swift
│   └── Settings/
│       ├── GeneralPane.swift    # Launch at login (SMAppService)
│       ├── AppearancePane.swift # Color scheme, opacity, text size, display
│       └── AboutPane.swift      # Version/build info
└── Spaceballs/              # CLI tool
    ├── SpaceballsCommand.swift    # @main ParsableCommand
    ├── ListCommand.swift        # list subcommand (default)
    ├── ActivateCommand.swift    # activate <windowID> subcommand
    ├── MoveCommand.swift        # move <window> <space> subcommand
    ├── Output.swift             # Text/JSON formatting
    └── Version.swift
```

### Key Design Patterns

- **SpaceManager** accepts a `SystemDataSource` protocol — production uses `CGSDataSource`, tests use `MockDataSource`
- **SwitcherViewModel** is the single source of truth for UI state — sections, selection (`SelectedItem` enum), search filtering, MRU ordering
- **SelectedItem** enum: `.spaceHeader(UInt64)`, `.windowRow(Int)`, `.settings` — unifies the keyboard navigation cycle through space headers, window rows, and the settings row
- **AppDelegate** manages an array of `SwitcherPanel` instances (one per display for "All" mode), all sharing the same `SwitcherViewModel`
- **KeyInterceptor** uses a `CGEvent.tapCreate` at `.cghidEventTap` level by default with signal handlers to ensure cleanup on process exit (prevents system-wide input freeze). The "Capture input from remote-control apps" setting (`AppSettings.captureRemoteInput`, default off) moves the tap to `.cgSessionEventTap`, which also sees synthetic keyboard events injected by remote-control agents (Jump Desktop, Screen Sharing) — those enter the event stream below the HID tap point and are invisible to the default tap. The setting affects only the keyboard tap; the eject/restore `MouseInputBlocker` keeps its own HID-level tap and passes Spaceballs' own synthetic drags by their `eventSourceUserData` tag, not by tap location
- **Move mode** in `SwitcherViewModel` visually relocates window rows between sections. `SpaceManager.moveWindowToSpace` does the actual move: a direct AX frame write when the window's Space and the target Space are both visible on different displays (`WindowMovePlanner` decides), otherwise `MissionControlContext` + CGEvent mouse simulation via Mission Control drag.

## Private APIs

| API | Framework | Purpose |
|---|---|---|
| `CGSMainConnectionID` | SkyLight | Default CGS connection |
| `CGSCopyManagedDisplaySpaces` | SkyLight | Space enumeration per display |
| `CGSCopySpacesForWindows` | SkyLight | Window-to-space mapping |
| `_SLPSSetFrontProcessWithOptions` | SkyLight | Activate process+window, triggers space switch |
| `SLPSPostEventRecordTo` | SkyLight | Synthetic key-window events |
| `GetProcessForPID` | Carbon (deprecated) | PID → ProcessSerialNumber |
| `_AXUIElementCreateWithRemoteToken` | HIServices | Construct AX handles for cross-space windows |
| `_AXUIElementGetWindow` | HIServices | AXUIElement → CGWindowID |
| `CoreDockSendNotification` | CoreDock | Open/dismiss Mission Control |

### Cross-Space Window Activation Flow

1. Brute-force AX element discovery: iterate element IDs 0–999 via `_AXUIElementCreateWithRemoteToken` (20-byte token: pid + zero + "coco" + elementID), match by CGWindowID. Required because `kAXWindowsAttribute` only returns current-Space windows.
2. `_SLPSSetFrontProcessWithOptions` — targets specific CGWindowID, triggers macOS space-switch animation
3. `SLPSPostEventRecordTo` — two synthetic event records (key-down + key-up) with CGWindowID at offset 0x3c
4. `AXUIElementPerformAction(kAXRaiseAction)` — z-order raise within the app's window stack
5. 100ms timeout on brute-force search (same as AltTab)

### Moving Windows Between Spaces via Mission Control Drag

Native CGS/SkyLight move APIs (`SLSMoveWindowsToManagedSpace`, `CGSAddWindowsToSpaces`) are blocked on macOS 14.5+ by `connection_holds_rights_on_window` checks. Spaceballs works around this by simulating the drag that a user would perform manually in Mission Control — except in the one case where no drag is needed:

**Direct cross-display fast path (both Spaces visible).** When the window's Space and the target Space are both *current* (each on a different display), `SpaceManager.moveWindowToSpace` skips Mission Control entirely: `WindowMovePlanner.route` (pure, unit-tested) returns `.direct(targetFrame)` and `performDirectWindowMove` writes the window's AX position — the same mechanism the Cmd+Shift+D resize grid uses to cycle a window between displays; WindowServer reassigns a window to the Space shown on whichever display its frame lands on, as for a manual cross-display drag. The size is never changed; the origin is mapped proportionally over each display's movable range (a window flush with the right/bottom edge stays flush; an axis the target can't fit pins to the target's origin, unshrunk). Within one shared deadline (`directMoveDeadline`, 1s) the move is verified by polling CGS until the window reports the target Space **and** its WindowServer origin matches the plan (held ~60ms for stability — `DirectMoveVerifier`, clock-injected and unit-tested; size is reported, not gated — AppKit clamps a window larger than its new display exactly as a manual drag does, surfacing as a `-size-changed` outcome suffix), with a final fresh read of **both** membership and frame at the deadline: either one proves the move (CGS can publish membership after WindowServer has already relocated the frame), and a moved window is never dragged. Only a failure before the window provably moved falls back to the Mission Control drag below (`direct-fallback:<reason>` in the `move-space` diagnostics). With "Activate moved windows and Spaces" on, the moved window is then activated and verified through the exact oracle Cmd+Shift+D uses — `WindowResizer.focusedWindowID()`: `NSWorkspace.frontmostApplication` must be the window's pid and that app's `kAXFocusedWindowAttribute` must resolve to its CGWindowID (one retry) — so a bare Cmd+Shift+D targets it on its new display; with it off, no focus or current Space changes at all. Declined cases keep the MC path: target not visible / not a desktop, window's own Space not visible, same-display moves, sticky (all-Spaces) windows, offscreen (minimized / Stage Manager-hidden) windows, unknown bounds or display geometry. Both legs sit behind `WindowMoveExecuting` (`performDirectWindowMove` / `performMissionControlWindowMove`) so routing and fallback are unit-tested with a recording executor (`WindowMoveRoutingTests`).

Every other case simulates the drag:

1. `activateWindow(id:)` — switch to the window's space (800ms delay for cross-space transitions; 250ms when the window is already on a current space)
2. `CoreDockSendNotification("com.apple.expose.awake")` — open Mission Control
3. `MissionControlTree` — locate the Mission Control AX tree (see **Where the MC tree lives** below) and its per-display `mc.display` groups, window thumbnails, and `mc.spaces.list` (space buttons)
4. Match the target window thumbnail by its `wid` attribute (CGWindowID, macOS 27+), else by `AXTitle`
5. `postMouseMoveAndGrab()` — hover + mouseDown on thumbnail center
6. `postMouseDragToPoint()` — nudge 15px to initiate drag state
7. `homingDrag()` — one continuous glide toward the target tile (located by per-display index on the target display's bar, then tracked by its own title during the drag), re-reading its aim point (`MissionControlTree.aimPoint`) every few steps and bending toward the latest reading. The path heads for the tile's pre-drag position; when the drag crosses into the bar, MC expands it and shifts every tile, and the re-reads bend the path onto the new center. (Tiles shift on arrival, so any fixed pre-drag coordinate would be stale.)
8. `MissionControlTree.locateTile` — after arrival, confirm the bar expanded and the tile settled (~40ms polls), following any residual shift so the drop is dead-center; unconfirmed → the drop is abandoned
9. `postMouseUp()` — drop the window dead-center on the tile
10. `AXUIElementPerformAction(kAXPressAction)` on target space button — switch to it
11. `activateWindow(id:)` — bring the moved window to front

**Where the MC tree lives (`MissionControlTree`, `awaitMissionControlTree`):** through macOS 26 the Dock's AX tree holds an `mc` group whose children are `mc.display` groups, each with `mc.windows` (thumbnails) and `mc.spaces` → `mc.spaces.list` (the bar). On **macOS 27** the Dock still exposes the `mc` group while MC is open — it remains the open/closed signal — but as an **empty stub**; the real tree moved to the **WindowManager** process (`com.apple.WindowManager`): `mc.display` groups are direct children of its application element, window thumbnails are direct `AXButton` children of each display (no `mc.windows`) identified `<bundle id>.space.<space id>` and carrying a `wid` attribute with their CGWindowID, and the bar is unchanged. All MC flows resolve the tree through the one locator (Dock group first, WindowManager second) and read thumbnails from either layout. Two more macOS 27 quirks the geometry helpers absorb: **tile `AXPosition` is the tile's center, not its top-left** under the WindowManager-hosted tree (`MissionControlTree.tileAnchor`, a property of the host — the Dock reported origins; do NOT infer it from the row's layout, a two-tile row is not centered in its bar) — verified against a screenshot of the expanded bar — so every grab/drop aims at that reported point as-is (`aimPoint`; origin-anchored tiles on the Dock tree aim at the frame's x center on the **bar's** vertical center, since those frames are taller than the bar and can sit above it); the naive frame center (position + half the size) lands on the tile's bottom-right corner and MC refuses the drop. **A tile's grab/drop point always comes from `MissionControlTree.locateTile`**, nil meaning *fail, never act on a stale point*: on the WindowManager host it requires the bar confirmed expanded (bar height ≥ tile height, `awaitExpandedAim`) and two agreeing expanded reads — MC opens with the bar collapsed to a row of labels and expands it only once hovered or dragged into, and a collapsed bar is *stable*, so a plain stable-point wait accepts collapsed coordinates before the hover has taken effect and the grab then misses the tile; on the Dock host (whose frames the expansion predicate is unverified against) it is the historical two-agreeing-reads wait. Hover-and-grab flows (the space-tile grab, `mc-dump --hover`) go through `hoverAndLocateTile`, which hovers the bar first and logs the outcome under `[mc]`; the window drop, whose drag into the bar expands it, calls `locateTile` for its final settle and abandons the drop (mouse up, dismiss, failure) when the tile isn't confirmed. A display's only desktop is titled just **"Desktop"** (no number), so per-display index, not a CGS-derived "Desktop N", locates a tile (`isDesktopTile` accepts both). `mc-dump` (DEBUG CLI) prints the tree wherever it is hosted; `mc-dump --hover --hold 3` expands the main display's bar first and holds MC open for a screenshot, which is how tile geometry was verified.

**Key details:**
- Window thumbnails in MC are `AXButton`s (children of `mc.windows`, or of `mc.display` on macOS 27) with `AXTitle` = window title, `AXPosition`/`AXSize` = screen coordinates; on macOS 27 the built-in display's group lists thumbnails for *every* Space, not just the current one
- Thumbnail matching (`matchWindowThumbnail`, pure/unit-tested) searches the window's own display first and prefers an exact title match on ANY display over any substring match; a substring match is accepted only when unambiguous (unique on the source display, else unique globally). MC shows every display's current space, so a similarly-titled window on another display (e.g. a terminal at the project path vs. an IDE with the project name in its title) would otherwise get grabbed and dragged instead of the real one.
- Space buttons shift when a window is dragged into the bar (placeholder insertion). Positions must be read AFTER initiating the drag, not before.
- Space buttons are tracked by title during the drag, not index, because placeholder insertion shifts indices; the title comes from the tile at the per-display index read before the drag.
- The `move` CLI subcommand accepts window titles or IDs, and space names or IDs.

### Moving Spaces Between Displays via Mission Control Drag

`SpaceManager.moveSpaceToDisplay` relocates an entire Space to another display using the same MC drag simulation, but the grabbed element is a **Space tile** in the source display's `mc.spaces.list` and the drop target is the **destination display's bar**:

1. `SpaceMovePlanner.plan` (pure, unit-tested) — resolves the space's **per-display tile index**, guards (desktop-only, target display exists, not already there), and picks a sibling to pre-switch to when the space is current
2. If the space is its display's **only** desktop space, a sibling is created there first (`createSpace` on that display, identified by UUID diff), then re-planned — a display must always retain ≥1 space
3. If the space is **current** on its display, `switchToSpace` moves the display off it first (MC refuses to drag the active Space), verified by polling CGS `isCurrent` — never a blind sleep
4. `moveSpaceInMC` — hover the source bar first (`MissionControlTree.hoverAndLocateTile`) so it expands and wait for confirmed expansion: tile AX frames are stale until expansion settles, and a collapsed bar reads as stable. Grab, nudge **downward** out of the bar (in-bar motion reads as reordering), then `homingDrag` toward the **center of the destination bar's frame**
5. Dwell ~0.6s over the bar (stationary drag events keep the session alive), drop, wait ~0.5s for MC to commit. By default (`activateAfterMove: true`, GUI setting "Activate moved windows and Spaces", CLI `--no-activate` to disable) the session then **ends on the moved Space**: once CGS lists it on the target display, its tile is pressed in the target bar (`pressTileInSession`, the same routine Space creation's switch-on-create uses — per-display desktop index, never a title, verified through CGS), zooming straight into it with no dismissal animation and no separate switch (`active-in-session` outcome). Only when that press didn't verify is MC dismissed and the Space activated from outside — `MovedSpaceActivator` (pure orchestration, unit-tested with a fake clock): activate the Space the way the panel does, poll CGS until it is current, and retry once through `switchToSpace(id:)` if it isn't — but never while Mission Control is present: an attempt can end in an async MC tile press, and a retry's awake TOGGLE would dismiss the session beneath it, so attempts are serialized on MC's absence (capped). `awaitMissionControlDismissed` beforehand is only an AX-presence guard — MC's group vanishes before the dismiss animation ends, and a DockSwipe posted meanwhile is swallowed — which is exactly what the verified retry covers. The outcome suffix (`active` / `activation-unverified`) is in the `move-space-display` log; an unverified activation never fails the completed move. With activation off the move leaves both displays' current Spaces unchanged
6. Verified by polling `getAllSpaces()` until the space's `displayUUID` matches the target

**Key details:**
- **Tiles are located by per-display index, never by "Desktop N" title.** MC numbers desktops in display-arrangement order (built-in first), while `CGSCopyManagedDisplaySpaces` enumerates displays in an order that can VARY between calls — a CGS-derived global title matches MC only by luck. Per-display CGS space order does match the bar's tile order (the invariant `switchToSpace(spaceIndex:screenNumber:)` relies on). `moveWindowToSpace` now locates its target tile the same way (falling back to the CGS-derived title only when the target display can't be resolved).
- **The drop aims at the bar frame's center, not at tile coordinates.** Collapsed-state tiles can report frames *above* the bar (observed on portrait displays); a stale read overshoots to the display's top edge, MC shows the spring-load-into-space effect, and the drop snaps back. Tiles are laid out centered in the bar, so the frame center is a clean insertion point. (Final position within the destination bar is therefore not guaranteed.)
- Requires ≥2 `mc.display` elements (fails early under mirroring / "Displays have separate Spaces" off)
- MC dismissal is guarded: `com.apple.expose.awake` TOGGLES Mission Control, so it is only re-sent when the `mc` AX group is still present
- **Eject/restore batches drags in one MC session.** `moveSpacesInMCBatch` opens Mission Control once, performs many tile drags (`performSpaceTileDrag`), and dismisses once. Per-source-display drags MUST be ordered by DESCENDING tile index (removals never shift pending indices; the drop aims at the target bar's center, so gaining tiles is safe). `ejectSpaces` sweeps all non-Default spaces to the built-in display (creating+naming a Default Space where a display would be left empty, pre-switching displays whose current space is leaving), records origins in `EjectStore` (shared UserDefaults suite), and activates nothing. `restoreEjectedSpaces` reverses it when displays return; the GUI auto-restores on display reconfiguration (debounced 2s, single-flight with eject) but ONLY for **armed** origins — those whose display was observed absent after the eject (armed at launch + each reconfiguration, per display: `armedEjectDisplays`; the older per-space `armedEjectedSpaces` list migrates on read) — so spurious display events can't undo an eject whose displays never left. **Eject records are multi-origin, one per site.** The same named Spaces live on different displays at home and at the office, and each site's eject-before-unplug would otherwise overwrite the other's record (one origin per Space stranded the office layout "awaiting" the home monitor). `EjectStore` therefore keeps, per Space, the list of displays it has been ejected from (most recent last; legacy single-UUID values read as one-element lists). A fresh eject supersedes only the Space's origins whose display is connected right now — the Space plainly isn't ejected from there anymore — and keeps origins whose display is absent (`EjectPlanner.supersededOrigins`, resolving displays by UUID or hardware fingerprint through `DisplayResolver`). Restore sends a Space to whichever origin is connected (the most recently recorded one if several) and clears only that origin; a Space with no connected origin is reported *waiting* only while it is still parked on the built-in display — one placed on an external display belongs to this site and its remaining origins to another. The GUI's pre-checks and the real run share `SpaceManager.restorePlan(ejectStore:onlyArmed:)` so both resolve displays the same way. Manual restore (GUI Cmd+Shift+E, CLI `restore`) moves everything movable regardless of arming. An automatic restore that leaves plannable moves behind (the run can fail wholesale right after reconnect while the Dock's AX hierarchy is still rebuilding) retries with backoff (`RestoreRetryPolicy`: 4s then 8s, reset by each real display event), and a restore check arriving while an eject/restore is in flight defers 2s instead of being dropped. MC-flow failures report via `SpaceManager.reportMCFailure` (stdout + diagnostics log) so a failed restore is diagnosable from `~/Library/Logs/Spaceballs/`. Eject GUI: Cmd+E; CLI: `eject`. Planning is pure (`EjectPlanner`/`RestorePlanner`). **Restore matches home displays by hardware fingerprint, not just UUID**: macOS can reassign a display's CGS UUID across reconnects (especially identical twin monitors on different ports), stranding records "awaiting" a UUID that never returns. Each eject records a `DisplayFingerprint` (vendor/model/serial + arrangement position) per home display; restore falls back to fingerprint matching (position breaks twin ties) and remaps the record to the display's new UUID (`Plan.displayRemap`, logged). Records from ejects predating fingerprints still need the exact UUID. ⚠️ `switchToSpace(spaceIndex:screenNumber:)` opens MC itself via the awake TOGGLE and returns before its async tile press — MC-sequenced flows must serialize switches and verify MC fully dismissed (`awaitMissionControlDismissed`) before the next awake.
- **Default Spaces are pinned.** `DefaultSpaceNamer` auto-names each external display's sole unnamed desktop space "Default Space" (`SpaceNameStore.defaultSpaceName`) at GUI launch and on display reconfiguration; the built-in display is exempt. A space carrying exactly that name refuses space-move in both GUI (`toggleSpaceMoveMode`) and CLI (`move-space`) — renaming it unpins it. Purpose: a display always retains an anchor space, so named spaces can be moved off without sibling creation.
- The `move-space <space> <display>` CLI subcommand accepts space IDs/names/"Desktop N" and display name substrings/UUIDs/1-based ordinals (`DisplayArgumentResolver`); DEBUG builds add `mc-move-space-test <sourceDisplay> <index> <targetDisplay>` for raw drag tuning
- GUI: **Cmd+Shift+X** enters space-move mode (Cmd+X enters window-move mode); plain arrows cycle the marked space between displays, Shift+arrows target the display in that physical direction (`DisplayArrangement` nearest-neighbor scoring over `NSScreen.frame`, wrapping past the far edge to the opposite end of the chain — but never wrapping on an axis with no displays; falls back to cycling when no arrangement is set), Enter executes, Esc cancels
- Verified live on a 4-display setup in all directions: external → built-in, built-in → external, external → external, including pre-switch off an active Space

### Cross-Space Window Activation Requires .app Bundle

`_SLPSSetFrontProcessWithOptions` requires a process registered with WindowServer as a proper application. A bare CLI executable doesn't get this registration. The `.app` bundle with `LSUIElement=true` in `Info.plist` and `NSApplication.setActivationPolicy(.accessory)` provides the necessary registration while remaining invisible in the Dock.

## Key Constraints

- **Targets the current macOS release only** — currently macOS 26 (Tahoe). The private CGS/SkyLight/AX internals shift between macOS releases, so each Spaceballs release supports only the macOS version it was developed against; older macOS versions are served by older releases (uses Cocoa, CoreGraphics, SkyLight, Accessibility APIs)
- **Accessibility permission** required for keyboard interception and window activation
- **Screen Recording permission** required for window titles
- **Private APIs** — undocumented Apple internals; may break across macOS versions
- **No external dependencies** beyond swift-argument-parser (CLI only); GUI is pure Swift + system frameworks
- **Window move via MC drag simulation** — moving windows between Spaces works by simulating a drag in Mission Control (no SIP required), but is timing-sensitive and depends on MC's AX hierarchy

## Known Limitations

### Space Names Cannot Be Read or Set via API

macOS does not store human-readable names for Spaces. The "Desktop 1", "Desktop 2" labels in Mission Control are generated at runtime by the Dock based on ordinal position — they are not persisted anywhere.

- `CGSCopyManagedDisplaySpaces` returns `ManagedSpaceID`, `id64`, `type`, and `uuid` per space — no name field.
- `CGSSpaceCopyName` / `SLSSpaceCopyName` exist but return the space's UUID, not a display name. Confirmed by yabai's maintainer ([issue #119](https://github.com/koekeishiya/yabai/issues/119)).
- No public Cocoa API (`NSWorkspace`, `NSScreen`) or AppleScript support exists for space names.

**Spaceballs's approach:** Store custom names locally in UserDefaults, keyed by space UUID. Users can rename spaces in Settings. Default labels use ordinal numbering ("Desktop 1", "Desktop 2").

### Moving Windows Between Spaces — CGS APIs Blocked, MC Drag Works

Private CGS/SkyLight APIs (`SLSMoveWindowsToManagedSpace`, `CGSAddWindowsToSpaces`, etc.) are blocked on macOS 14.5+ by `connection_holds_rights_on_window` checks — only `Dock.app`'s privileged WindowServer connection passes.

| macOS Version | CGS Move APIs Work? |
|---|---|
| < 14.5 (pre-Sonoma) | Yes |
| 14.5+ (Sonoma) | No — `connection_holds_rights_on_window` checks |
| 15.0+ (Sequoia) | No — workarounds also blocked |

**Spaceballs's approach:** Simulate the drag that a user would perform manually in Mission Control. Open MC, find the window thumbnail via AX, post CGEvent mouse events to drag it to the target space. No SIP required. See "Moving Windows Between Spaces via Mission Control Drag" above for the full flow.

**Limitations of MC drag approach:**
- Timing-sensitive — delays between activation, MC open, drag initiation, and position re-query must be tuned
- Window matched by title string — identical duplicate titles on the same display could still match the wrong window (exact-match ties break by AX child order)
- Briefly visible MC animation during the move (~2s)
- Depends on Mission Control's AX hierarchy structure (could change across macOS versions)

### Opening New Windows on a Specific Space

`NSRunningApplication.activate()` from an accessory app does not set space context on Sequoia. Launch Services (`open`) also opens on the app's existing space, not the caller's space. There is no reliable way to open a new window for an arbitrary app on the current space from an accessory process.
