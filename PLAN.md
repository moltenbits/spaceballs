# Plan: Move Window to Another Space via Mission Control Drag Simulation

## Table of Contents

- [Context](#context)
- [Approach](#approach)
- [UX Flow](#ux-flow)
- [Implementation Steps](#implementation-steps)
  - [Phase 0: Discovery & Prototype](#phase-0-discovery--prototype) — COMPLETE
  - [Phase 1: SpaceManager API](#phase-1-spacemanager-api) — TODO
  - [Phase 2: ViewModel Move Mode](#phase-2-viewmodel-move-mode) — TODO
  - [Phase 3: KeyInterceptor Binding](#phase-3-keyinterceptor-binding) — TODO
  - [Phase 4: AppDelegate Wiring](#phase-4-appdelegate-wiring) — TODO
  - [Phase 5: UI Visual Indicator](#phase-5-ui-visual-indicator) — TODO
- [Architecture (from Phase 0)](#architecture-from-phase-0)
- [Open Questions / Risks](#open-questions--risks)
- [Verification](#verification)
- [Critical Files](#critical-files)

---

## Context

The user wants to move windows between Spaces from within Spaceballs. The native private APIs (`SLSMoveWindowsToManagedSpace`, `CGSAddWindowsToSpaces`, etc.) are all blocked on macOS 14.5+ by `connection_holds_rights_on_window` checks — only Dock.app's privileged connection can use them.

However, users **can** manually drag windows between spaces in Mission Control. The approach: simulate that drag via CGEvent mouse events. Spaceballs already opens Mission Control and navigates its AX hierarchy for space switching, creation, and closure.

## Approach

**Open Mission Control → find the window thumbnail → simulate a mouse drag to the target space button.**

## UX Flow

1. User opens Spaceballs (Cmd+Tab), selects a window
2. **Cmd+M** marks it for moving — row color changes to indicate move mode
3. User navigates to the target space header (Cmd+Arrow or arrow keys)
4. Releasing Cmd (or pressing Enter) triggers the move:
   - Hide Spaceballs panel
   - Activate the marked window (switches to its space via existing `activateWindow`)
   - Open Mission Control via `CoreDockSendNotification`
   - Wait for MC animation (~500ms)
   - Find the window thumbnail in `mc.windows` by title match
   - Grab thumbnail, nudge to initiate drag, re-query space positions
   - Drag directly to target space center, drop
   - MC auto-dismisses or we dismiss it

---

## Implementation Steps

### Phase 0: Discovery & Prototype — COMPLETE

#### Step 0a: AX Hierarchy Discovery

Added `dumpMissionControlAXTree()` to `SpaceManager` and `mc-dump` CLI subcommand (debug builds only). Verified with multiple clean runs.

**MC AX tree structure:**
```
mc (AXGroup, "Mission Control") — full screen size
  mc.display (AXGroup) — AXDisplayID per display
    mc.windows (AXGroup, roleDesc="exposéd windows")
      AXButton — title="<window title>", pos/size = thumbnail screen coords
      AXButton — ...
    mc.spaces (AXGroup, "Spaces Bar")
      mc.spaces.list (AXList)
        AXButton — title="Desktop 1", desc="exit to Desktop 1"
        AXButton — title="Desktop 2", ...
      mc.spaces.add (AXButton, desc="add desktop")
```

**Key findings:**
- Window thumbnails are fully visible as `AXButton` children of `mc.windows`
- Each has `AXTitle` (= window title), `AXPosition`, `AXSize`, `AXEnabled=1`
- No CGWindowID attribute — must match by window title string
- Space buttons have **negative y positions** (y=-32) when collapsed — the bar expands on hover or when dragging
- Matching by title: prefer exact match, fall back to unambiguous substring

#### Step 0b: CGEvent Drag Simulation

Validated that CGEvent mouse drag simulation works in Mission Control.

**Working drag sequence:**
1. Open MC via `openMissionControlContext()`, wait 500ms for animation
2. Find window thumbnail in `mc.windows` by title match
3. `postMouseMoveAndGrab()` on thumbnail center
4. `postMouseDragToPoint()` 15px upward (minimal nudge to initiate drag state)
5. Wait 500ms for MC to adjust the spaces bar layout
6. Re-query `mc.spaces.list` children positions (now accurate for current drag state)
7. Match target space by `AXTitle`
8. `postMouseDragToPoint()` directly to target space center — one smooth motion
9. Wait 200ms, then `postMouseUp()` to drop

**Lessons learned:**
- Dragging a window INTO the spaces bar creates a placeholder thumbnail, shifting all positions. Positions read before the placeholder are wrong.
- Prediction math (pre-calculating shifted positions) is fragile — item counts, sizes, and gaps all change.
- The reliable approach: initiate a minimal drag (nudge), let MC settle, THEN re-query positions.
- Must match target space by **title** not index (placeholder insertion shifts indices).
- MC animation wait (500ms) is critical — reducing it causes unreliable AX tree population.
- Total operation time: ~1.7s.

#### Step 0c: Code Compartmentalization

Refactored prototype code into reusable components:

| Component | Location | Purpose |
|---|---|---|
| `MissionControlContext` | `SpaceManager` struct | Resolved AX elements for an MC session. Methods: `windowButtons`, `spaceButtons`, `findWindowButton(titled:)`, `findSpaceButton(titled:)` |
| `openMissionControlContext()` | `SpaceManager` static | Opens MC, polls for AX tree, returns context |
| `axPosition()`, `axSize()`, `axCenter()` | `SpaceManager` static | AX element geometry helpers |
| `postMouseMoveAndGrab()`, `postMouseDragToPoint()`, `postMouseUp()` | `SpaceManager` static | CGEvent mouse simulation |
| `moveWindowInMC()` | `SpaceManager` public | High-level: find window + drag to space |
| `debugMCDragPositions()` | `SpaceManager` public | Functional test: visit all spaces, drop on specified one |

**CLI commands (debug builds only, via `#if DEBUG`):**
- `mc-dump` — dumps full MC AX hierarchy
- `mc-move-test <title> <space> [--verbose]` — moves a window to a space by title
- `mc-debug-pos <title> [--drop-on <space>]` — drags window over every space, drops on specified one

---

### Phase 1: SpaceManager API — TODO

Add the production `moveWindowToSpace` method that bridges from window ID + space ID to the MC drag:

```swift
public func moveWindowToSpace(windowID: Int, targetSpaceID: UInt64) throws
```

Flow:
1. Look up window title from `CGWindowListCopyWindowInfo` (already available via `dataSource`)
2. Look up target space's display UUID and ordinal index (same lookup as `closeSpace(id:)`)
3. Resolve space title from `SpaceNameStore` or default "Desktop N" label
4. Activate the window via existing `activateWindow(id:)` — switches to its space
5. Call `moveWindowInMC(windowTitle:targetSpaceTitle:)` to perform the drag

**Key file:** `Sources/SpaceballsCore/SpaceManager.swift`

### Phase 2: ViewModel Move Mode — TODO

Add to `SwitcherViewModel`:
- `@Published public var moveMode: Bool = false`
- `@Published public var markedWindowID: Int? = nil`
- `public func toggleMoveMode()` — if a `.windowRow` is selected, marks it and enters move mode. Selection jumps to the window's space header so the user can navigate to a different space.
- `public func executeMoveWindow()` — called on confirm when `moveMode` is true. Calls `spaceManager.moveWindowToSpace(windowID:targetSpaceID:)`.
- `public func cancelMoveMode()` — clears move state

**Key file:** `Sources/SpaceballsGUILib/SwitcherViewModel.swift`

### Phase 3: KeyInterceptor Binding — TODO

Add `keyInterceptorToggleMoveMode()` to `KeyInterceptorDelegate` protocol. Handle Cmd+M (keyCode 46) in the callback, following existing Cmd+key patterns.

Modify the confirm flow (Cmd release): when `moveMode` is active, call a move-confirm delegate method instead of the normal confirm.

Add Cmd+M to `KeyBindings` as a configurable binding.

**Key files:**
- `Sources/SpaceballsGUI/KeyInterceptor.swift`
- `Sources/SpaceballsGUILib/SwitcherViewModel.swift` (KeyBindings struct)

### Phase 4: AppDelegate Wiring — TODO

Add delegate method implementations:
- `keyInterceptorToggleMoveMode()` → `viewModel.toggleMoveMode()`
- Modify `keyInterceptorConfirm()` to check move mode and call `viewModel.executeMoveWindow()` + `hidePanel()`

**Key file:** `Sources/SpaceballsGUI/AppDelegate.swift`

### Phase 5: UI Visual Indicator — TODO

In `SwitcherRowView`, when a window row matches `markedWindowID` and `moveMode` is true, change the highlight color (e.g., orange/amber). Space headers that are valid drop targets could have a subtle highlight.

**Key file:** `Sources/SpaceballsGUI/SwitcherRowView.swift`

---

## Architecture (from Phase 0)

### MC AX Tree Navigation

```
Dock (AXApplication)
  └── mc (AXGroup) — "Mission Control"
      └── mc.display (AXGroup) — per display, has AXDisplayID
          ├── mc.windows (AXGroup) — "exposéd windows"
          │   ├── AXButton — title=<window title>, pos/size = thumbnail coords
          │   └── ...
          └── mc.spaces (AXGroup) — "Spaces Bar"
              ├── mc.spaces.list (AXList)
              │   ├── AXButton — title="Desktop 1"
              │   └── ...
              └── mc.spaces.add (AXButton)
```

### CGEvent Drag Timing

| Step | Duration | Notes |
|---|---|---|
| Open MC + wait for AX tree | ~500ms | Critical — too fast = unreliable AX population |
| Mouse move + grab | ~150ms | Move to thumbnail center, mouseDown |
| Nudge (15px) | ~25ms | 3 steps to initiate drag state |
| Wait for bar to settle | ~500ms | MC adjusts spaces bar layout |
| Re-query AX positions | ~1ms | Re-read space button positions |
| Drag to target | ~120ms | 15 steps × 8ms |
| Hold + release | ~200ms | Brief hold, then mouseUp |
| Post-drop + dismiss | ~200ms | Wait for MC to process, dismiss |
| **Total** | **~1.7s** | |

### Window Title Matching

MC window thumbnails expose `AXTitle` = the window's title bar text. Matching strategy:
1. **Exact match** on `AXTitle` (preferred)
2. **Substring match** only if exactly one window matches (avoids ambiguity)
3. Report error with available titles if no match or multiple matches

---

## Open Questions / Risks

1. ~~**Does CGEvent mouse drag work in Mission Control?**~~ — **Yes.** Validated in Phase 0.

2. ~~**Finding the window thumbnail position in MC**~~ — **Solved.** `mc.windows` exposes all thumbnails with positions. Nudge + re-query approach handles the spaces bar shift.

3. **Timing sensitivity** — 500ms MC animation wait is the minimum reliable value. Reducing it caused wrong-window grabs. The bar settle wait (500ms after nudge) may also need tuning per system.

4. **Multi-display** — `openMissionControlContext` accepts an optional `screenNumber` parameter. The `axChildMatchingDisplay` helper already handles multi-display. Untested in the MC drag flow.

5. **Window title collisions** — Multiple windows can have the same title (e.g., two "Untitled" windows). The current match-by-title approach would fail. The real implementation should use the exact title from `WindowInfo.name` which may help, but true duplicates remain a risk.

## Verification

1. ~~**Phase 0 test:** MC drag simulation works~~ — DONE
2. **`mc-debug-pos` functional test:** `spaceballs mc-debug-pos "<window>" --drop-on "Desktop N"` — visits all spaces, drops on target (debug builds only)
3. **`mc-move-test` quick test:** `spaceballs mc-move-test "<window>" "Desktop N" --verbose` — single move
4. **Full flow test:** Open Spaceballs → select window → Cmd+M → navigate to different space → release Cmd → verify window moved
5. **Edge cases:** Moving to adjacent space, moving across 3+ spaces, different space counts (verified: works with 8 and 12 spaces), moving the only window on a space
6. `make test` — existing tests should still pass (ViewModel changes need new tests for move mode state)

## Critical Files

| File | Phase | Changes |
|---|---|---|
| `Sources/SpaceballsCore/SpaceManager.swift` | 0, 1 | `MissionControlContext`, `moveWindowInMC()`, `moveWindowToSpace()`, CGEvent helpers, AX helpers |
| `Sources/SpaceballsGUILib/SwitcherViewModel.swift` | 2, 3 | Move mode state, `toggleMoveMode()`, `executeMoveWindow()`, KeyBindings |
| `Sources/SpaceballsGUI/KeyInterceptor.swift` | 3 | Cmd+M binding, move-confirm flow |
| `Sources/SpaceballsGUI/AppDelegate.swift` | 4 | Delegate wiring |
| `Sources/SpaceballsGUI/SwitcherRowView.swift` | 5 | Move mode visual indicator |
| `Sources/Spaceballs/MCDumpCommand.swift` | 0 | Debug CLI: dump MC AX tree |
| `Sources/Spaceballs/MCMoveTestCommand.swift` | 0 | Debug CLI: move window by title |
| `Sources/Spaceballs/MCDebugPositionsCommand.swift` | 0 | Debug CLI: functional test — visit all spaces |
| `Sources/Spaceballs/SpaceballsCommand.swift` | 0 | `#if DEBUG` gating for mc-* commands |
