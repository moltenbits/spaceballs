A macOS window switcher inspired by [Contexts](https://contexts.co) — a fast, keyboard-driven way to navigate between windows across Spaces. Uses private CoreGraphics Server (CGS) and SkyLight APIs for space enumeration and cross-space window activation.

## Features

- **Per-window switching** — lists individual windows, not just apps
- **Space-aware** — groups windows by Space with MRU (most-recently-used) ordering
- **Cross-space activation** — switches to any window on any Space with native animation
- **Keyboard-driven** — Cmd+Tab to cycle, Cmd+\` to go back, type to search
- **Window management** — Cmd+W to close a window, Cmd+Q to quit an app
- **Space navigation** — tab onto a Space header to switch to that Space
- **Custom space names** — rename Spaces in Settings (persisted locally)
- **Multi-display** — show the panel on the active display, primary display, or all displays
- **Configurable appearance** — background opacity, text size, light/dark/auto color scheme
- **Settings** — Cmd+, to open; General, Appearance, and About panes

## Installation

### Homebrew

```bash
brew tap moltenbits/tap
brew install spacebar
```

### From Source

```bash
git clone https://github.com/moltenbits/spacebar.git
cd spacebar
make install
```

## Usage

### GUI (Task Switcher)

```bash
make gui          # Build and run the GUI switcher
```

Once running, the app lives in the background (no Dock icon). Keyboard shortcuts:

| Shortcut | Action |
|---|---|
| Cmd+Tab | Show panel / move selection down |
| Cmd+\` | Move selection up |
| Release Cmd | Activate selected window or space |
| Escape | Dismiss panel |
| Cmd+W | Close selected window |
| Cmd+Q | Quit selected app |
| Cmd+, | Open Settings |
| Type | Filter windows by app name or title |

### CLI

```bash
spacebar            # List all Spaces and windows (text output)
spacebar --json     # JSON output
spacebar --version  # Version
```

```
══════════════════════════════════════════════════════════════
 Display: 37D8832A-2D66-02CA-B9F7-8F30A301B230
══════════════════════════════════════════════════════════════

  Space 1 [Desktop] (ID: 3)  ← ACTIVE
  ────────────────────────────────────────────────
    [1234] Safari — GitHub
    [5678] Terminal — spacebar

  Space 2 [Desktop] (ID: 5)
  ────────────────────────────────────────────────
    [9012] Slack — #general

Summary: 2 space(s) across 1 display(s), 3 window(s)
```

### As an SPM Library

Add SpacebarCore to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/moltenbits/spacebar.git", from: "0.1.0"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "SpacebarCore", package: "spacebar"),
        ]
    ),
]
```

```swift
import SpacebarCore

let manager = SpaceManager()
let (spaces, windowMap) = manager.windowsBySpace()

for space in spaces {
    let windows = windowMap[space.id] ?? []
    print("Space \(space.id): \(windows.count) windows")
}
```

`SpacebarCore` exposes `SpaceManager` with these methods:

| Method | Returns |
|---|---|
| `getAllSpaces()` | `[SpaceInfo]` — all Spaces across all displays |
| `getAllWindows()` | `[WindowInfo]` — all normal-layer windows (>50px) |
| `windowsBySpace()` | `([SpaceInfo], [UInt64: [WindowInfo]])` — windows grouped by Space ID |
| `activateWindow(id:)` | Activates a window by CGWindowID (triggers space switch) |
| `closeWindow(id:)` | Closes a window via its AX close button |
| `quitApp(owningWindowID:)` | Terminates the app that owns a window |

`SpaceManager` accepts a `SystemDataSource` protocol for dependency injection in tests.

## Requirements

- macOS 14.0 (Sonoma) or later
- **Accessibility permission** — required for keyboard interception and window activation (System Settings > Privacy & Security > Accessibility)
- **Screen Recording permission** — required for window titles to be visible (System Settings > Privacy & Security > Screen Recording)

## How It Works

Spacebar uses private Apple frameworks accessed via `@_silgen_name`:

**CGS / SkyLight** (space & window enumeration):
- `CGSMainConnectionID()` — default CGS connection
- `CGSCopyManagedDisplaySpaces()` — enumerate displays and their Spaces
- `CGSCopySpacesForWindows()` — map windows to Space IDs

**SkyLight** (window activation):
- `_SLPSSetFrontProcessWithOptions` — activate a specific window by CGWindowID, triggering macOS space-switch animation
- `SLPSPostEventRecordTo` — synthetic key-window events
- `GetProcessForPID` — PID to ProcessSerialNumber (deprecated Carbon)

**Accessibility** (cross-space window discovery):
- `_AXUIElementCreateWithRemoteToken` — construct AX handles for windows on any Space (brute-force enumeration, since `kAXWindowsAttribute` only returns current-Space windows)
- `_AXUIElementGetWindow` — AXUIElement to CGWindowID

These are undocumented Apple internals sourced from reverse-engineering by projects like [yabai](https://github.com/koekeishiya/yabai), [AltTab](https://github.com/lwouis/alt-tab-macos), and [Amethyst](https://github.com/ianyh/Amethyst). They may break across macOS versions.

The `--disable-sandbox` build flag is required because these APIs are not available in sandboxed processes.

## License

MIT
