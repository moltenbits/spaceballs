# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Spacebar is a macOS window switcher app inspired by [Contexts](https://contexts.co) — a fast, keyboard-driven way to navigate between windows across Spaces. The goal is to provide features like search-based window switching, per-window (not per-app) listing, and Space-aware organization.

Currently in early development: the foundation is a CLI that enumerates Spaces and windows using private CoreGraphics Server (CGS) APIs via `@_silgen_name` (SkyLight framework). It supports text and JSON (`--json`) output modes.

## Build & Run Commands

All commands use `make`. The build requires `--disable-sandbox` for CGS access.

```bash
make build        # Debug build
make release      # Optimized release build
make run          # Build + run (text output)
make run-json     # Build + run (JSON output)
make test         # Run tests
make format       # Format with swift-format
make lint         # Lint with swift-format
make clean        # Remove .build/
```

Underlying tool: Swift Package Manager (`swift build`, `swift test`, etc.).

## Architecture

Three source files in `Sources/Spacebar/`:

- **PrivateCGS.swift** — Declares bindings to three private CGS functions (`CGSMainConnectionID`, `CGSCopyManagedDisplaySpaces`, `CGSCopySpacesForWindows`) and supporting types (`CGSConnectionID`, `CGSSpaceMask`, `CGSSpaceType`). These are resolved at link time from the dyld shared cache via `@_silgen_name`.

- **SpaceManager.swift** — Core logic. `SpaceManager` uses the CGS connection to enumerate spaces across all displays (`getAllSpaces`), enumerate normal-layer windows (`getAllWindows`), map windows to space IDs (`spacesForWindow`), and aggregate everything (`windowsBySpace`). Data models: `SpaceInfo` and `WindowInfo`. Filters out non-layer-0 windows and tiny (<50px) helper windows.

- **main.swift** — CLI entry point. Parses `--json`, calls `SpaceManager.windowsBySpace()`, formats output. Includes permission warnings (Screen Recording access required for window titles).

## Key Constraints

- **macOS 13+ only** (uses Cocoa + CoreGraphics APIs)
- **Screen Recording permission** must be granted to the terminal for window titles to be visible
- **Private APIs**: The CGS functions are undocumented Apple internals (sourced from yabai/Amethyst reverse-engineering). They may break across macOS versions.
- **No external dependencies** — pure Swift + system frameworks

## Known Limitations

### Space Names Cannot Be Read or Set via API

macOS does not store human-readable names for Spaces. The "Desktop 1", "Desktop 2" labels in Mission Control are generated at runtime by the Dock based on ordinal position — they are not persisted anywhere.

- `CGSCopyManagedDisplaySpaces` returns `ManagedSpaceID`, `id64`, `type`, and `uuid` per space — no name field.
- `CGSSpaceCopyName` / `SLSSpaceCopyName` exist but are misleadingly named: they return the space's UUID, not a display name. Confirmed by yabai's maintainer ([issue #119](https://github.com/koekeishiya/yabai/issues/119)).
- `CGSSpaceSetName` / `SLSSpaceSetName` exist in reverse-engineered headers but have no known effect on Mission Control display.
- `com.apple.spaces.plist` has a `"name"` field per space, but it stores the UUID, not a custom label.
- No public Cocoa API (`NSWorkspace`, `NSScreen`) or AppleScript support exists for space names.

**Workarounds considered:**
- **SIMBL injection** (e.g. spaces-renamer) — injects into the Dock process to override rendering. Requires SIP disabled, fragile, Intel-only.
- **Accessibility overlay** (e.g. rename-spaces) — draws labels on top of Mission Control. Visual trick, not real renaming.
- **Hammerspoon AX scraping** — briefly opens Mission Control to read accessibility elements. Causes a visible flash.

### Moving Windows Between Spaces Requires SIP Disabled on Modern macOS

Private CGS/SkyLight APIs exist for moving windows between spaces, but Apple has progressively locked them down so they only work from `Dock.app`'s privileged WindowServer connection.

**Available APIs:**
- `CGSMoveWindowsToManagedSpace(cid, windowIDs, spaceID)` — atomic single-call move. Silently no-ops on macOS 14.5+ for non-Dock connections.
- `CGSAddWindowsToSpaces` / `CGSRemoveWindowsFromSpaces` — two-step add/remove (must add before removing on macOS 12.1+). No-ops on Monterey+ for non-Dock connections.
- `SLSSetWindowListWorkspace` + `SLSSpaceSetCompatID` — workaround used by yabai. Also no-ops on Sequoia 15.0+.

**macOS version restrictions:**

| macOS Version | Move APIs Work Without SIP? |
|---|---|
| < 14.5 (pre-Sonoma) | Yes |
| 14.5+ (Sonoma) | No — Apple added `connection_holds_rights_on_window` checks |
| 15.0+ (Sequoia) | No — workarounds also blocked |

The root cause: WindowServer grants each app a connection with limited rights. `Dock.app` holds a special "universal owner" connection that bypasses authorization checks. The only reliable approach on modern macOS is injecting a scripting addition into Dock (as yabai does), which requires SIP to be partially disabled.

**Other constraints:**
- Cannot move windows into/out of fullscreen spaces.
- After moving, the window loses focus on the source space — focus management must be handled manually.
- No visible animation — the window simply disappears from one space and appears on the other.

**How other projects handle this:**
- **yabai** — Dock injection via scripting addition (requires partial SIP disable). The only reliable approach on modern macOS.
- **AeroSpace** — Avoids native Spaces entirely; emulates virtual workspaces by moving windows off-screen.
- **Amethyst** — Simulates mouse-drag + keyboard space-switch. Fragile, user-visible animation.
- **Hammerspoon** — Version-branching: direct API on older macOS, yabai-style workarounds on newer.

**Recommended approach for Spacebar:** Treat Spacebar as read-only for space/window enumeration and focus-switching. Moving windows between spaces is not viable without requiring users to disable SIP, which is a non-starter for a general-purpose app.
