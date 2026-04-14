import Cocoa
import SpaceballsCore

extension NSScreen {
  var displayUUID: String? {
    guard
      let screenNumber = deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
      let cfUUID = CGDisplayCreateUUIDFromDisplayID(screenNumber)?.takeUnretainedValue()
    else { return nil }
    return CFUUIDCreateString(nil, cfUUID) as String
  }
}

public final class ResizeViewModel: ObservableObject {
  @Published public var focusedAppName: String = ""
  @Published public var focusedAppIcon: NSImage?

  /// The AX element for the focused window, captured when the panel is shown.
  public internal(set) var focusedWindowElement: AXUIElement?
  /// The screen the focused window resides on.
  public internal(set) var targetScreen: NSScreen?

  /// The display UUID of the target screen (overlays use this to show highlight only on the correct display).
  @Published public var targetDisplayUUID: String?

  /// The region currently shown on the grid (set when a preset is applied).
  @Published public var activeRegion: GridRegion?

  /// Live preview region during drag — used by the screen overlay.
  @Published public var previewRegion: GridRegion?

  /// The columns/rows currently displayed on the grid.
  @Published public var previewGridColumns: Int = 12
  @Published public var previewGridRows: Int = 12

  /// Callback invoked after a grid-drag resize to dismiss the panel.
  public var onResizeComplete: (() -> Void)?

  /// Tracks the last preset key code applied, for screen cycling.
  private var lastPresetKeyCode: UInt16?

  public init() {}

  /// Captures the currently focused window's info for display and later resize.
  public func captureCurrentWindow() {
    guard let app = NSWorkspace.shared.frontmostApplication else {
      focusedAppName = ""
      focusedAppIcon = nil
      focusedWindowElement = nil
      targetScreen = nil
      return
    }

    focusedAppName = app.localizedName ?? "Unknown"
    focusedAppIcon = app.icon

    do {
      let (element, _) = try WindowResizer.focusedWindow()
      focusedWindowElement = element
      targetScreen = WindowResizer.screen(for: element)
    } catch {
      focusedWindowElement = nil
      targetScreen = nil
    }

    targetDisplayUUID = targetScreen?.displayUUID
    lastPresetKeyCode = nil
    activeRegion = nil
  }

  /// Resizes the captured window to the given grid region on the current target screen.
  /// Dismisses the panel via `onResizeComplete`.
  public func applyRegion(_ region: GridRegion, margins: CGFloat) {
    guard let element = focusedWindowElement,
      let screen = targetScreen
    else { return }
    do {
      try WindowResizer.resize(element, to: region, on: screen, margins: margins)
    } catch {
      print("Resize failed: \(error.localizedDescription)")
    }
    lastPresetKeyCode = nil
    onResizeComplete?()
  }

  /// Applies a preset. If the same preset key is pressed again, cycles to the next screen.
  /// Does NOT resize or dismiss — the actual resize happens on Cmd release via `commitResize`.
  public func applyPreset(_ preset: ResizePreset, margins: CGFloat) {
    guard focusedWindowElement != nil else { return }

    let screens = NSScreen.screens
    guard !screens.isEmpty else { return }

    let screen: NSScreen
    if preset.keyCode == lastPresetKeyCode, let current = targetScreen, screens.count > 1 {
      // Same preset pressed again — cycle to next screen
      let currentIndex = screens.firstIndex(where: { $0 == current }) ?? 0
      let nextIndex = (currentIndex + 1) % screens.count
      screen = screens[nextIndex]
    } else {
      // Different preset or first press — use current screen
      screen = targetScreen ?? screens.first!
    }

    targetScreen = screen
    targetDisplayUUID = screen.displayUUID
    lastPresetKeyCode = preset.keyCode
    activeRegion = preset.region
  }

  /// Updates the target display (e.g. when the user interacts with a panel on another screen).
  public func setTargetDisplay(_ uuid: String?) {
    targetDisplayUUID = uuid
    targetScreen = NSScreen.screens.first { $0.displayUUID == uuid }
  }

  /// Commits the pending preset resize and dismisses the panel.
  public func commitResize(margins: CGFloat) {
    guard let element = focusedWindowElement,
      let screen = targetScreen,
      let region = activeRegion
    else { return }
    do {
      try WindowResizer.resize(element, to: region, on: screen, margins: margins)
    } catch {
      print("Resize failed: \(error.localizedDescription)")
    }
  }
}
