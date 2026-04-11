# Plan: Move Window to Another Space via Mission Control Drag Simulation

## Context

The user wants to move windows between Spaces from within Spaceballs. The native private APIs (`SLSMoveWindowsToManagedSpace`, `CGSAddWindowsToSpaces`, etc.) are all blocked on macOS 14.5+ by `connection_holds_rights_on_window` checks — only Dock.app's privileged connection can use them.

However, users **can** manually drag windows between spaces in Mission Control. The approach: simulate that drag via CGEvent mouse events. Spaceballs already opens Mission Control and navigates its AX hierarchy for space switching, creation, and closure.

## Approach

**Activate the target window → open Mission Control → simulate a mouse drag from the window's area to the target space button.**

Spaceballs already has all the building blocks except CGEvent mouse posting and the "move mode" UX.

## UX Flow

1. User opens Spaceballs (Cmd+Tab), selects a window
2. **Cmd+M** marks it for moving — row color changes to indicate move mode
3. User navigates to the target space header (Cmd+Arrow or arrow keys)
4. Releasing Cmd (or pressing Enter) triggers the move:
   - Hide Spaceballs panel
   - Activate the marked window (switches to its space via existing `activateWindow`)
   - Open Mission Control via `CoreDockSendNotification`
   - Wait for MC animation (~300ms, same as existing code)
   - Get the target space button's screen position via AX (`kAXPositionAttribute` + `kAXSizeAttribute`)
   - Calculate the drag start point (center of the activated window's bounds, scaled to MC thumbnail area)
   - Post `CGEvent` sequence: mouseDown → mouseDragged → mouseUp
   - MC auto-dismisses on drop (or we dismiss it)

## Implementation Steps

### Phase 0: Discover MC AX hierarchy + prototype drag

#### Step 0a: AX hierarchy discovery — COMPLETE

Added `dumpMissionControlAXTree()` to `SpaceManager` and `mc-dump` CLI subcommand. Results (verified with two clean runs):

**MC AX tree structure:**
```
mc (AXGroup, "Mission Control") — pos=(0,0) size=1800x1169
  mc.display (AXGroup) — AXDisplayID=1
    mc.windows (AXGroup, roleDesc="exposéd windows") — pos=(20,118) size=1760x985
      AXButton — title="<window title>", pos/size = thumbnail screen coords
      AXButton — ...
    mc.spaces (AXGroup, "Spaces Bar") — pos=(0,0) size=1800x78
      mc.spaces.list (AXList)
        AXButton — title="Desktop 1", desc="exit to Desktop 1", pos=(415,-32) size=65x24
        AXButton — title="Desktop 2", ...
        ...
      mc.spaces.add (AXButton, desc="add desktop")
```

**Key findings:**
- Window thumbnails are **fully visible** as `AXButton` children of `mc.windows`
- Each has `AXTitle` (= window title), `AXPosition`, `AXSize`, `AXEnabled=1`
- No CGWindowID attribute — must match by window title string
- Space buttons have **negative y positions** (y=-32) — the spaces bar is collapsed until hovered
- `mc.windows` has `AXSelectedChildren` attribute (may indicate focused window)
- Available attributes per button: AXRoleDescription, AXEnabled, AXFrame (no AXIdentifier)

**Matching strategy:** Match `mc.windows` AXButton titles to `WindowInfo.name` from `getAllWindows()`. Titles include app name + window title (e.g., "gasp – BookService.java [gasp.examples.spring-example.main]").

#### Step 0b: CGEvent drag simulation — COMPLETE

Validated that CGEvent mouse drag simulation works in Mission Control. Key findings:

**Working approach:**
1. Open MC, wait for animation
2. Find window thumbnail in `mc.windows` by title match
3. `mouseMoved` + `mouseDown` on thumbnail center (grab)
4. `mouseDragged` 15px upward (minimal nudge to initiate drag state)
5. Wait ~0.8s for MC to adjust the spaces bar layout
6. Re-query `mc.spaces.list` children positions (now accurate for current drag state)
7. Match target space by `AXTitle`
8. `mouseDragged` directly to target space center — one smooth motion
9. Wait ~0.5s, then `mouseUp` to drop

**Lessons learned:**
- Space buttons report y=-32 when collapsed. Bar expands on hover OR when dragging a window.
- Dragging a window INTO the spaces bar creates a placeholder thumbnail for that window, shifting all positions. Positions read before the placeholder appears are WRONG.
- Prediction math (pre-calculating shifted positions) is fragile — different item counts, sizes, and gaps.
- The reliable approach: initiate a minimal drag (nudge), let MC settle, THEN re-query positions.
- Must match target space by **title** not index (placeholder insertion shifts indices).
- `postMouseDragToPoint` with ~20 steps and 15ms intervals produces smooth, natural-looking drag.

**Key files:** `Sources/SpaceballsCore/SpaceManager.swift` (prototype methods: `testMoveWindowInMC`, `debugSpacePositions`, `postMouseMoveAndGrab`, `postMouseDragToPoint`, `postMouseUp`, `axPosition`, `axSize`)

### Phase 1: SpaceManager — `moveWindowToSpace` method

Add to `SpaceManager`:
```
public func moveWindowToSpace(windowID: Int, targetSpaceID: UInt64) throws
```

Flow:
1. Look up window bounds from `CGWindowListCopyWindowInfo` (already available via `dataSource`)
2. Look up target space's display UUID and ordinal index (same lookup as `closeSpace(id:)` at line 693)
3. Resolve `CGDirectDisplayID` via existing `displayIDForUUID`
4. Activate the window via existing `activateWindow(id:)` — switches to its space
5. Brief delay for space switch animation (~200ms)
6. Open Mission Control via `CoreDockSendNotification`
7. Poll for MC AX group (existing pattern, lines 781-790)
8. Wait 300ms for animation (existing pattern)
9. Navigate AX: `mc` → `mc.display` → `mc.spaces` → `mc.spaces.list` → target space button (existing code)
10. Get space button position: `AXUIElementCopyAttributeValue(button, kAXPositionAttribute)` and `kAXSizeAttribute`
11. Find the window thumbnail in `mc.windows` by matching `AXTitle` to the window's title, get its `AXPosition`/`AXSize`
12. Post CGEvent drag sequence (new helper method)
13. Brief delay for drop animation
14. Dismiss MC if needed

New helper — `postMouseDrag(from:to:)`:
```swift
private static func postMouseDrag(from: CGPoint, to: CGPoint) {
    // mouseDown at source
    let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                       mouseCursorPosition: from, mouseButton: .left)
    down?.post(tap: .cghidEventTap)

    // Brief pause for MC to register the grab
    Thread.sleep(forTimeInterval: 0.05)

    // mouseDragged in steps to target (MC may need intermediate points)
    let steps = 20
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let point = CGPoint(x: from.x + (to.x - from.x) * t,
                           y: from.y + (to.y - from.y) * t)
        let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                          mouseCursorPosition: point, mouseButton: .left)
        drag?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.01)  // ~200ms total for smooth drag
    }

    // mouseUp at target
    let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                    mouseCursorPosition: to, mouseButton: .left)
    up?.post(tap: .cghidEventTap)
}
```

**Key file:** `Sources/SpaceballsCore/SpaceManager.swift`

### Phase 2: ViewModel — Move mode state

Add to `SwitcherViewModel`:
- `@Published public var moveMode: Bool = false`
- `@Published public var markedWindowID: Int? = nil`
- `public func toggleMoveMode()` — if a `.windowRow` is selected, marks it and enters move mode. Selection jumps to the window's space header so the user can navigate to a different space.
- `public func executeMoveWindow()` — called on confirm when `moveMode` is true. Calls `spaceManager.moveWindowToSpace(windowID:targetSpaceID:)` with the marked window and currently-selected space header.
- `public func cancelMoveMode()` — clears move state

**Key file:** `Sources/SpaceballsGUILib/SwitcherViewModel.swift`

### Phase 3: KeyInterceptor — Cmd+M binding

Add `keyInterceptorToggleMoveMode()` to the `KeyInterceptorDelegate` protocol and handle Cmd+M (keyCode 46) in the callback. Follow the existing pattern for other Cmd+key bindings (e.g., Cmd+W at line 302).

Modify the confirm flow (Cmd release at line 379): when `moveMode` is active, call a new `keyInterceptorMoveConfirm()` delegate method instead of `keyInterceptorConfirm()`.

Also add Cmd+M to `KeyBindings` as a configurable binding.

**Key files:**
- `Sources/SpaceballsGUI/KeyInterceptor.swift`
- `Sources/SpaceballsGUILib/SwitcherViewModel.swift` (KeyBindings struct)

### Phase 4: AppDelegate — Wire up move mode

Add delegate method implementations:
- `keyInterceptorToggleMoveMode()` → calls `viewModel.toggleMoveMode()`
- `keyInterceptorMoveConfirm()` → calls `viewModel.executeMoveWindow()`, then `hidePanel()`

Modify `keyInterceptorConfirm()` to check if move mode is active.

**Key file:** `Sources/SpaceballsGUI/AppDelegate.swift`

### Phase 5: UI — Visual indicator for move mode

In `SwitcherRowView`, when a window row matches `markedWindowID` and `moveMode` is true, change the highlight color (e.g., orange/amber instead of the standard selection blue). Show a subtle "Moving..." label or icon.

Space headers that are valid drop targets (different from the marked window's current space) could have a subtle highlight.

**Key file:** `Sources/SpaceballsGUI/SwitcherRowView.swift`

## Open Questions / Risks

1. **Does CGEvent mouse drag work in Mission Control?** — This is the critical unknown. Phase 0 validates this before we build anything else. If MC ignores synthetic events, we're stuck.

2. **Finding the window thumbnail position in MC** — When MC opens, the frontmost window should be prominently displayed. We can estimate its position from its real `CGRect` bounds scaled to MC's layout. If this isn't accurate enough, we may need to dump the MC AX hierarchy to find window-specific elements (the user confirmed MC does expose window elements once the cursor enters the MC area).

3. **Timing sensitivity** — The delays between activate → MC open → animation → drag need tuning. Too fast and MC isn't ready; too slow and it feels sluggish.

4. **Multi-display** — The window and target space may be on different displays. The AX navigation already handles multi-display via `axChildMatchingDisplay`.

## Verification

1. **Phase 0 test:** Manually activate a window, then call the prototype `moveWindowToSpace` — does the window end up on the target space?
2. **Full flow test:** Open Spaceballs → select window → Cmd+M → navigate to different space → release Cmd → verify window moved
3. **Edge cases:** Moving to adjacent space, moving across 3+ spaces, moving when target space is on a different display, moving the only window on a space
4. `make test` — existing tests should still pass (ViewModel changes need new tests for move mode state)

## Critical Files

| File | Changes |
|---|---|
| `Sources/SpaceballsCore/SpaceManager.swift` | `moveWindowToSpace()`, `postMouseDrag()`, AX position helpers |
| `Sources/SpaceballsGUILib/SwitcherViewModel.swift` | Move mode state, `toggleMoveMode()`, `executeMoveWindow()` |
| `Sources/SpaceballsGUI/KeyInterceptor.swift` | Cmd+M binding, move-confirm flow |
| `Sources/SpaceballsGUI/AppDelegate.swift` | Delegate wiring |
| `Sources/SpaceballsGUI/SwitcherRowView.swift` | Move mode visual indicator |
