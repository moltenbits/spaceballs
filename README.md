# ![Spaceballs](title.png)
_"I'm a MOG. Half man, half dog. I'm my own best friend!" - Barf_

Spaceballs is a Frankensteinian attempt to make the abomination that is macOS Spaces and the default Application 
Switcher a little more useful for your average power user. macOS Spaces were, unfortunately, designed to the lowest 
common denominator. In an attempt to make them as simple as possible for anyone to use, they've made them nearly  
useless. Spaceballs is my personal attempt to alleviate that for my own productivity.

The name "Spaceballs" is inspired by:  
- macOS Spaces, obviously.
- The cult-classic movie of the same name which poked fun of the incredibly popular Star Wars franchise at the time. 
- The more Spaces one used, the more balls it felt like one was juggling, the opposite of helping productivity.
- Holy balls does it have bugs, especially when using with external displays.

## Table of Contents

- [Disclaimer](#disclaimer)
- [Inspiration](#inspiration)
- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
  - [GUI (Task Switcher)](#gui-task-switcher)
  - [Moving Windows Between Spaces](#moving-windows-between-spaces)
  - [Moving Spaces Between Displays](#moving-spaces-between-displays)
  - [Resizing Windows](#resizing-windows)
  - [Workspaces](#workspaces)
  - [CLI](#cli)
- [Requirements](#requirements)
- [How It Works](#how-it-works)
- [License](#license)

## Disclaimer

This application is 100% vibe coded. It handles no sensitive information whatsoever, which is why I'm comfortable
with that. If you as a potential user are not comfortable with that, then you can simply avoid using it. I charge no 
price for this application, nor collect any personal information or telemetry. The project is open source and you 
are welcome to inspect the code, build it yourself, and/or fork to customize to your needs if you wish. I do not provide 
any warranty or promise of support for this application. It was built to support my needs as a developer in a 
multi-Space environment. I am not responsible for any damage or loss of data that may occur from using it. Use at 
your own risk.

## Inspiration

Originally inspired by [Contexts](https://contexts.co) — Spaceballs is a fast, keyboard-driven way to switch between
applications but designed in a way that takes advantage of macOS Spaces. Using Spaces is not required and it can be
used simply as a more advanded app switcher, but for those who prefer to use Spaces, it helps tremendously.

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

A non-exhaustive list of the bugs and design failures Apple Spaces suffers from, every one of them verified the hard 
way while building Spaceballs:

- **The built-in Cmd+Tab switcher is Space-blind.** One icon per app, no matter how many windows across how many
  Spaces. Ten project Spaces each with a browser, an IDE, and a terminal collapse into three anonymous icons.
- **Spaces can't be named.** The "Desktop 1", "Desktop 2" labels aren't stored anywhere — they're generated at
  runtime from ordinal position. Rearrange your Spaces and every label silently changes meaning. There is no API,
  no AppleScript, no anything to read or set a Space name.
- **"Desktop N" numbering isn't even stable.** Mission Control numbers desktops in display-arrangement order,
  while the underlying enumeration order can vary from one call to the next — so the same desktop can be
  "Desktop 3" in one context and not in another.
- **There is no sanctioned way to move a window to another Space without using the mouse.** The internal APIs that 
  could do it were locked down in macOS 14.5 so that only the Dock itself may call them. The only supported method
  is manually dragging window thumbnails in Mission Control, one at a time, forever. This is excruciatingly slow and 
  when combined with the next issue, is maddening.
- **Disconnecting a display scrambles your windows.** macOS evacuates the departed display's Spaces and dumps
  windows onto whatever Space it feels like; reconnecting the display does not consistently put things back. This has 
  been broken for years and has arguably gotten worse in recent macOS releases.
- **Some apps refuse to open new windows on the current Space.** For single-window apps like Music or System
  Settings this is at least defensible — multiple windows wouldn't make sense, so activating them jumps to
  wherever their one window lives. But Finder, where having many windows open is completely normal, does the
  same thing: instead of opening a new window right here, it yanks you off to whichever Space already has one —
  and there is no API to force "new window, right here."

## Features

- **Per-window switching** — lists individual windows, not just apps
- **Space-aware** — groups windows by Space with MRU (most-recently-used) ordering
- **Cross-space activation** — switches to any window on any Space with native animation
- **Move windows between Spaces** — Cmd+X to mark a window, navigate to the target space, release to move (no SIP required)
- **Move Spaces between displays** — Cmd+Shift+X to mark a Space, arrow to the target display, release to move
- **Stable Default Spaces** — each external display's fresh space is auto-named "Default Space" and pinned to its display, so a display always keeps an anchor space and any named Space can be moved off it without first creating a sibling (rename a Default Space to unpin it; the built-in display is exempt)
- **Eject before disconnect** — press Cmd+E (or run `spaceballs eject`) *before* unplugging external displays to sweep their Spaces onto the built-in display, so disconnecting doesn't scatter windows into random Spaces; on reconnect, ejected Spaces are automatically restored to the displays they came from. Ejecting must be triggered manually — once a display is unplugged, it's too late
- **Window resizing** — Cmd+Shift+D opens a grid overlay for the focused window: drag cells to resize, or apply
  configurable presets (pressing a preset again cycles it across screens)
- **Keyboard-driven** — Cmd+Tab to cycle, Cmd+\` to go back; all shortcuts customizable in Settings
- **Window management** — Cmd+M minimizes a window while keeping the panel open; Cmd+Shift+M minimizes every window in the selected Space. Minimized windows move to the bottom of their Space and display a faded icon. Cmd+W closes a window, and Cmd+Q quits an app
- **Create and close spaces** - open the Workspaces menu to launch a workspace or create a new Space (Cmd+N), or close an existing Space (Cmd+Shift+W)
- **Custom space names** — select a Space and press Cmd+R to rename inline (names are local to Spaceballs; macOS does not expose Space names to apps)
- **Multi-display** — show the panel on the active display, primary display, or per display
- **Workspaces** — define named Spaces with app launchers, then restore them all in one shot (`spaceballs workspace restore`)
- **Window layout memory** — optionally remember and restore window positions per Space, display arrangement, and configured workspace
- **Cursor warp** — optionally warp the pointer onto the window you activate
- **App exclusions** — hide chosen apps from the switcher
- **Settings export/import** — backup and restore all settings via JSON (CLI or GUI)
- **Opt-in diagnostics** — local troubleshooting log with optional window-title redaction
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
| Cmd+↓ / Cmd+↑ (or bare arrows) | Next / previous space, continuing onto the display below / above and wrapping past the last one (arrangement-aware, move-mode-aware) |
| Cmd+→ / Cmd+← (Shift optional) | Move to the display in that physical direction, wrapping around at the edge (arrangement-aware, move-mode-aware) |
| Cmd+Shift+↓ / Cmd+Shift+↑ | Jump straight to the display below / above, wrapping around at the edge |
| Release Cmd (or Cmd+Enter) | Activate selected window or space |
| Escape | Dismiss panel / cancel current mode |
| Cmd+M | Minimize selected window, move it to the bottom of its Space, and keep the panel open |
| Cmd+Shift+M | Minimize every window in the selected Space and select its header |
| Cmd+X | Enter move mode (mark selected window for moving between Spaces) |
| Cmd+Shift+X | Enter space-move mode (mark selected Space for moving between displays) |
| Cmd+W | Close selected window |
| Cmd+Shift+W | Close selected space |
| Cmd+Q | Quit selected app |
| Cmd+R | Rename selected space (Enter to save, Escape to cancel) |
| Cmd+N | Open the Workspaces menu (launch a workspace or create a new Space) |
| Cmd+S | Cycle sort order (MRU / Ordinal / Name) |
| Cmd+E | Eject: move all external displays' non-default Spaces to the built-in display |
| Cmd+Shift+E | Restore ejected Spaces to their original displays |
| Cmd+Shift+D | Toggle the window resize grid (works globally, no panel needed) |
| Cmd+, | Open Settings |
| Type | Filter windows by app name or title |

All shortcut keys can be rebound in Settings.

### Moving Windows Between Spaces

Spaceballs can move windows between Spaces — something macOS does not expose via any public API and that other tools (yabai, Amethyst, Hammerspoon) can only do with SIP disabled. Spaceballs accomplishes this without SIP by simulating the drag a user would perform manually in Mission Control.

**How to use:**

1. **Cmd+Tab** to open Spaceballs and select the window you want to move
2. **Cmd+X** to enter move mode — the selection highlight turns to a lighter blue
3. **Cmd+Tab** or **Cmd+Arrow** to visually move the window row space-by-space (**Cmd+Shift+Arrow** jumps to the display in that physical direction) — it will appear as the first item in each space as you navigate
4. **Release Cmd** to execute the move — Spaceballs activates the window, opens Mission Control, drags the window to the target space, switches to that space, and brings the window to front
5. **Escape** to cancel move mode at any time

By default the moved window becomes the active window on its new Space. If your workflow prefers moves that don't
pull you along, turn off "Activate moved windows and Spaces" in Settings → General (CLI: `--no-activate`) — the
window is moved in the background and your current view is restored.

The move can also be performed from the CLI:

```bash
spaceballs move "Safari" "Desktop 3"    # Move by window title and space name
spaceballs move 12345 67890             # Move by window ID and space ID
```

### Moving Spaces Between Displays

An entire Space — with all its windows — can be relocated to another display, again via simulated Mission Control
drag (no SIP required). If the Space is the display's only desktop or is currently active, Spaceballs handles the
prerequisites automatically (creates a sibling Space / switches away first). Spaces named "Default Space" are
pinned to their display and refuse to move, in both the GUI and the CLI — rename one to unpin it.

**How to use:**

1. **Cmd+Tab** to open Spaceballs and select the Space (or any window in it)
2. **Cmd+Shift+X** to enter space-move mode
3. **Arrow keys** to cycle the marked Space between displays, or **Shift+Arrow** to send it to the display in that physical direction
4. **Release Cmd** to execute the move, or **Escape** to cancel

By default the moved Space becomes the active Space on its destination display. The same
"Activate moved windows and Spaces" setting (Settings → General, CLI: `--no-activate`) turns this off, leaving
every display's current Space exactly as it was.

From the CLI:

```bash
spaceballs move-space "Work" 2          # Space name → 2nd display
spaceballs move-space "Desktop 3" DELL  # "Desktop N" → display name substring
```

**Ejecting before disconnect:** macOS scatters a disconnected display's windows into arbitrary Spaces the
moment the display goes away — and once it's unplugged, it's too late to fix. **Ejecting is a deliberate,
manual step: press Cmd+E (or run `spaceballs eject`) *before* you disconnect.** Spaceballs has no way to do
this for you automatically; unplug without ejecting and the usual scrambling happens.

An eject moves every non-default Space from every external display onto the built-in display, keeping each
Space — and the apps in it — intact (each display keeps its Default Space, and the Space you're working on
stays put). When the displays come back, the ejected Spaces are automatically restored to the displays they
came from, and each display returns to the Space that was active when you ejected. Restore can also be
triggered by hand at any time with **Cmd+Shift+E** or `spaceballs restore`.

Auto-restore only fires for displays that actually went away and came back — ejecting and then continuing to
work with everything still plugged in won't be undone by a display going to sleep.

While an eject or restore runs, a full-screen overlay appears and physical mouse input is paused (Spaceballs
is driving the cursor); input returns as soon as the completion message appears, and the pause times out on
its own if anything goes wrong. Pacing is adjustable in **Settings → Timing** — if a Space snaps back to its
display instead of moving on your hardware, nudge the pauses up.

### Resizing Windows

**Cmd+Shift+D** (from anywhere — the switcher panel does not need to be open) overlays a resize grid on the focused
window's screen. Drag across grid cells to snap the window to that region, or apply one of the configurable presets —
pressing the same preset again cycles the window across screens. Grid dimensions, margins, and presets are all
configurable in Settings.

### Workspaces

Workspaces let you define named Spaces together with the apps that should launch in them. Restoring recreates any
missing Spaces and launches the configured apps in the right place:

```bash
spaceballs workspace list               # Show configured workspaces and their launchers
spaceballs workspace restore            # Create missing spaces and launch configured apps
```

Workspaces are configured in Settings → Workspaces and included in settings export/import.
Open Workspaces in the switcher to launch a configured workspace, or choose All Workspaces to restore them all.
New Space creates an empty macOS Space.

### CLI

```bash
spaceballs                            # Show help
spaceballs list                       # List all Spaces and windows (text output)
spaceballs list --json                # JSON output
spaceballs window <window-id>         # Activate a window by ID
spaceballs move <window> <space>      # Move a window to another Space (by ID or name)
spaceballs move-space <space> <display> # Move an entire Space to another display
spaceballs switch <space>             # Switch to a Space by ID or name
spaceballs create                     # Create a new unnamed space
spaceballs create "Work"              # Create a space and name it
spaceballs create 3                   # Create 3 unnamed spaces
spaceballs create --defaults          # Create missing spaces from your configured workspaces
spaceballs close <space>              # Close a Space by ID or name
spaceballs rename <space-id> [name]   # Set or clear a custom Space name
spaceballs workspace list             # Show configured workspaces and their launchers
spaceballs workspace restore          # Restore workspaces: create spaces and launch apps
spaceballs settings export [path]     # Export settings to JSON (stdout if no path)
spaceballs settings import <path>     # Import settings from JSON
spaceballs diagnostics [status]       # Show/enable/disable opt-in diagnostic logging
spaceballs --version                  # Version
```

## Requirements

- macOS 27 (Golden Gate) or newer — Spaceballs depends on private macOS APIs that can change in any macOS release, so each release targets the macOS version it was developed and tested on; on older macOS, use the last release that targeted it
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
- Space tiles in `mc.spaces.list` — dragged between display bars to move an entire Space to another display
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
