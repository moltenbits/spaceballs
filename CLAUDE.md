# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Table of Contents

- [What This Is](#what-this-is)
- [Build & Run Commands](#build--run-commands)
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
make build        # Debug build + bundle .build/Spaceballs.app
make release      # Release build + bundle .build/Spaceballs.app
make everything   # Kill + build + open the .app
make run          # Build + run CLI (text output)
make run.json     # Build + run CLI (JSON output)
make kill         # Kill running Spaceballs
make test         # Run tests
make format       # Format with swift-format
make lint         # Lint with swift-format
make install      # Release build + install CLI binary + CLI .app bundle
make clean        # Remove .build/
```

Underlying tool: Swift Package Manager (`swift build`, `swift test`, etc.).

**After finishing any requested code change, automatically run `make everything` to install it.**

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
- **KeyInterceptor** uses a `CGEvent.tapCreate` at `.cghidEventTap` level with signal handlers to ensure cleanup on process exit (prevents system-wide input freeze)
- **Move mode** in `SwitcherViewModel` visually relocates window rows between sections. `MissionControlContext` + CGEvent mouse simulation handles the actual move via Mission Control drag.

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

Native CGS/SkyLight move APIs (`SLSMoveWindowsToManagedSpace`, `CGSAddWindowsToSpaces`) are blocked on macOS 14.5+ by `connection_holds_rights_on_window` checks. Spaceballs works around this by simulating the drag that a user would perform manually in Mission Control:

1. `activateWindow(id:)` — switch to the window's space (800ms delay for cross-space transitions)
2. `CoreDockSendNotification("com.apple.expose.awake")` — open Mission Control
3. `MissionControlContext` — navigate the Dock's AX hierarchy to find `mc.windows` (window thumbnails) and `mc.spaces.list` (space buttons)
4. Match the target window by `AXTitle` in `mc.windows`
5. `postMouseMoveAndGrab()` — hover + mouseDown on thumbnail center
6. `postMouseDragToPoint()` — nudge 15px to initiate drag state
7. Wait 500ms for MC to adjust spaces bar, then re-query `mc.spaces.list` positions (they shift during drag)
8. Match target space by title ("Desktop N"), drag directly to its center
9. `postMouseUp()` — drop the window
10. `AXUIElementPerformAction(kAXPressAction)` on target space button — switch to it
11. `activateWindow(id:)` — bring the moved window to front

**Key details:**
- Window thumbnails in MC are `AXButton` children of `mc.windows` with `AXTitle` = window title, `AXPosition`/`AXSize` = screen coordinates
- Space buttons shift when a window is dragged into the bar (placeholder insertion). Positions must be read AFTER initiating the drag, not before.
- Space buttons are matched by title ("Desktop N"), not index, because placeholder insertion shifts indices.
- The `move` CLI subcommand accepts window titles or IDs, and space names or IDs.

### Cross-Space Window Activation Requires .app Bundle

`_SLPSSetFrontProcessWithOptions` requires a process registered with WindowServer as a proper application. A bare CLI executable doesn't get this registration. The `.app` bundle with `LSUIElement=true` in `Info.plist` and `NSApplication.setActivationPolicy(.accessory)` provides the necessary registration while remaining invisible in the Dock.

## Key Constraints

- **macOS 14+ only** (uses Cocoa, CoreGraphics, SkyLight, Accessibility APIs)
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
- Window matched by title string — duplicate titles could match the wrong window
- Briefly visible MC animation during the move (~2s)
- Depends on Mission Control's AX hierarchy structure (could change across macOS versions)

### Opening New Windows on a Specific Space

`NSRunningApplication.activate()` from an accessory app does not set space context on Sequoia. Launch Services (`open`) also opens on the app's existing space, not the caller's space. There is no reliable way to open a new window for an arbitrary app on the current space from an accessory process.
