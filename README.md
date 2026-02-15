A macOS window switcher inspired by [Contexts](https://contexts.co) — a fast, keyboard-driven way to navigate between windows across Spaces. Enumerates Spaces and windows using private CoreGraphics Server (CGS) APIs.

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

## Usage

```bash
# List all Spaces and windows (text output)
spacebar

# JSON output
spacebar --json

# Version
spacebar --version
```

### Text Output

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

### JSON Output

```bash
spacebar --json | jq '.[].spaces[].windows[] | .app'
```

### Library Usage

`SpacebarCore` exposes `SpaceManager` with three methods:

| Method | Returns |
|---|---|
| `getAllSpaces()` | `[SpaceInfo]` — all Spaces across all displays |
| `getAllWindows()` | `[WindowInfo]` — all normal-layer windows (>50px) |
| `windowsBySpace()` | `([SpaceInfo], [UInt64: [WindowInfo]])` — windows grouped by Space ID |

`SpaceManager` accepts a `SystemDataSource` protocol for dependency injection in tests.

## Requirements

- macOS 13.0 (Ventura) or later
- **Screen Recording permission** must be granted to your terminal for window titles to be visible (System Settings > Privacy & Security > Screen Recording)

## How It Works

Spacebar uses three private CoreGraphics Server (SkyLight) functions accessed via `@_silgen_name`:

- `CGSMainConnectionID()` — gets the default CGS connection
- `CGSCopyManagedDisplaySpaces()` — enumerates displays and their Spaces
- `CGSCopySpacesForWindows()` — maps windows to Space IDs

These are undocumented Apple internals sourced from reverse-engineering by projects like [yabai](https://github.com/koekeishiya/yabai) and [Amethyst](https://github.com/ianyh/Amethyst). They may break across macOS versions.

The `--disable-sandbox` build flag is required because these APIs are not available in sandboxed processes.

## License

MIT
