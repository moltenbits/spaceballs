# ![Spaceballs](title.png)
_"I'm a MOG. Half man, half dog. I'm my own best friend!" - Barf_

Spaceballs is effectively a superpowered replacement for both macOS Mission Control and the App Switcher. It is a
Frankensteinian attempt to make the abomination that is macOS Spaces a little more useful.
Spaces were, unfortunately, designed to the lowest common denominator. In an attempt to make them as simple as
possible for anyone to use, they've severely limited their usefulness. Spaceballs is my personal attempt to
alleviate that for my own productivity.



## Table of Contents

- [Inspiration](#inspiration)
- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
  - [GUI (Task Switcher)](#gui-task-switcher)
  - [Moving Windows Between Spaces](#moving-windows-between-spaces)
  - [CLI](#cli)
- [Requirements](#requirements)
- [How It Works](#how-it-works)
- [License](#license)

## Inspiration
Originally inspired by [Contexts](https://contexts.co) — Spaceballs is a fast, keyboard-driven way to switch between
applications but designed in a
way that takes advantage of macOS Spaces. Using Spaces is not required and it can be used simply as a more
advanded app switcher, but for those who prefer to use Spaces, it becomes a superpower.

In an increasingly AI-powered environment, the ability to multi-task is becoming more important than ever while at
the same time the ability to regain context when switching between tasks is becoming more and more difficult. The
initial solution was to make use of macOS Spaces, one for each project I was working on which contained its own
instance of all the tools I needed for that project. This quickly turned into a couple spaces, then 5, then 10, etc,
each containing their own browser, IDE, terminal, etc. The default macOS app switcher was completely useless.
Contexts, a 3rd party app switcher I had heavily used in the past, was now also falling short due to shear
duplication of apps I had across a variety of spaces. Unable to find any solution that fit my workflow, I decided to
see what I could vibe-code one Sunday. Having never touched a line of Swift code in my life, I was absolutey shocked
at what I was able to come up with in a single day. Now here we are, and I continue to add features that I feel
perfectly compliment users who make heavy use of AI tooling to work on many projects at once.

As for the name "Spaceballs", inspiration came about two ways - first the cult classic movie Spaceballs which
heavily poked fun of the very mainstream Star Wars movies (as I'd love to poke fun of Apple for their modern UX).
Second, the more one made use of Spaces in their
workflows, the more balls it felt like one was forced to juggle until all productivity essentially broke down.

## Features

- **Per-window switching** — lists individual windows, not just apps
- **Space-aware** — groups windows by Space with MRU (most-recently-used) ordering
- **Cross-space activation** — switches to any window on any Space with native animation
- **Move windows between Spaces** — Cmd+M to mark a window, navigate to the target space, release to move (no SIP required)
- **Keyboard-driven** — Cmd+Tab to cycle, Cmd+\` to go back
- **Window management** — Cmd+W to close a window, Cmd+Q to quit an app
- **Create and close spaces** - create new spaces (Cmd+N) or close existing ones (Cmd+Shift+W)
- **Custom space names** — select a Space and press Cmd+R to rename inline (names are local to Spaceballs; macOS does not expose Space names to apps)
- **Multi-display** — show the panel on the active display, primary display, or per display
- **Default spaces** - define default spaces that can be automatically created (Cmd+D)
- **Settings export/import** — backup and restore all settings via JSON (CLI or GUI)
- **CLI** - All features available from a `spaceballs` CLI command

## Installation

### Homebrew

```bash
brew tap moltenbits/tap
brew install spaceballs
```

### From Source

```bash
git clone https://github.com/moltenbits/spacebar.git
cd spacebar
make install
```

## Usage

### GUI (Task Switcher)

Once running, the app lives in the background (no Dock icon). Keyboard shortcuts:

| Shortcut | Action |
|---|---|
| Cmd+Tab | Show panel / move selection down |
| Cmd+\` | Move selection up |
| Cmd+↓ / Cmd+↑ | Jump to next / previous space (with Cmd held) |
| Cmd+← / Cmd+→ | Cycle between displays |
| Release Cmd | Activate selected window or space |
| Escape | Dismiss panel |
| Cmd+M | Enter move mode (mark selected window for moving) |
| Cmd+W | Close selected window |
| Cmd+Shift+W | Close selected space |
| Cmd+Q | Quit selected app |
| Cmd+R | Rename selected space (Enter to save, Escape to cancel) |
| Cmd+N | Create a new space |
| Cmd+D | Create all missing default spaces |
| Cmd+S | Cycle sort order (MRU / Ordinal / Name) |
| Cmd+, | Open Settings |
| Type | Filter windows by app name or title |

### Moving Windows Between Spaces

Spaceballs can move windows between Spaces — something macOS does not expose via any public API and that other tools (yabai, Amethyst, Hammerspoon) can only do with SIP disabled. Spaceballs accomplishes this without SIP by simulating the drag a user would perform manually in Mission Control.

**How to use:**

1. **Cmd+Tab** to open Spaceballs and select the window you want to move
2. **Cmd+M** to enter move mode — the selection highlight turns to a lighter blue
3. **Cmd+Tab** or **Cmd+Arrow** to visually move the window row to the target space — it will appear as the first item in each space as you navigate
4. **Release Cmd** to execute the move — Spaceballs activates the window, opens Mission Control, drags the window to the target space, switches to that space, and brings the window to front
5. **Escape** to cancel move mode at any time

The move can also be performed from the CLI:

```bash
spaceballs move "Safari" "Desktop 3"    # Move by window title and space name
spaceballs move 12345 67890             # Move by window ID and space ID
```

### CLI

```bash
spaceballs                          # Show help
spaceballs list                     # List all Spaces and windows (text output)
spaceballs list --json              # JSON output
spaceballs window <window-id>       # Activate a window by ID
spaceballs move <window> <space>    # Move a window to another Space (by ID or name)
spaceballs switch <space>           # Switch to a Space by ID or name
spaceballs create                   # Create a new unnamed space
spaceballs create "Work"            # Create a space and name it
spaceballs create 3                 # Create 3 unnamed spaces
spaceballs create --defaults        # Create all missing default spaces
spaceballs close <space>            # Close a Space by ID or name
spaceballs rename <space-id> [name] # Set or clear a custom Space name
spaceballs settings export [path]   # Export settings to JSON (stdout if no path)
spaceballs settings import <path>   # Import settings from JSON
spaceballs --version                # Version
```

## Requirements

- macOS 14.0 (Sonoma) or later
- **Accessibility permission** — required for keyboard interception and window activation (System Settings > Privacy & Security > Accessibility)
- **Screen Recording permission** — required for window titles to be visible (System Settings > Privacy & Security > Screen Recording)

## How It Works

Spaceballs uses private Apple frameworks accessed via `@_silgen_name`:

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

**Dock Accessibility** (space management & window moving):
- `CoreDockSendNotification("com.apple.expose.awake")` — open/close Mission Control programmatically
- Dock AX hierarchy navigation (`mc` → `mc.display` → `mc.spaces` → `mc.spaces.list`) — locate space buttons for switching
- `mc.windows` AX group — window thumbnails in Mission Control, used for drag simulation to move windows between Spaces
- `AXPress` on the `mc.spaces.add` button — create new Spaces
- `AXRemoveDesktop` action on space buttons — close Spaces

**CGEvent** (keyboard interception & mouse simulation):
- `CGEvent.tapCreate` at `.cghidEventTap` — intercepts Cmd+Tab and other shortcuts system-wide
- `CGEvent` mouse events (`leftMouseDown`, `leftMouseDragged`, `leftMouseUp`) — simulates Mission Control drag to move windows between Spaces
- Signal handlers ensure the tap is removed on process exit to prevent system-wide input freeze

These are undocumented Apple internals sourced from reverse-engineering by projects like [yabai](https://github.com/koekeishiya/yabai), [AltTab](https://github.com/lwouis/alt-tab-macos), and [Amethyst](https://github.com/ianyh/Amethyst). They may break across macOS versions.

The `--disable-sandbox` build flag is required because these APIs are not available in sandboxed processes.

## License

MIT
