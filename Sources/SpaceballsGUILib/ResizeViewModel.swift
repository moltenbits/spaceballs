import Cocoa
import SpaceballsCore

public final class ResizeViewModel: ObservableObject {
  @Published public var focusedAppName: String = ""
  @Published public var focusedAppIcon: NSImage?

  /// The AX element for the focused window, captured when the panel is shown.
  public internal(set) var focusedWindowElement: AXUIElement?
  /// The screen the focused window resides on.
  public internal(set) var targetScreen: NSScreen?

  /// The region currently shown on the grid (set when a preset is applied).
  @Published public var activeRegion: GridRegion?

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
  /// Does NOT dismiss the panel (so the user can press again to cycle).
  public func applyPreset(_ preset: ResizePreset, margins: CGFloat) {
    guard let element = focusedWindowElement else { return }

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

    do {
      try WindowResizer.resize(element, to: preset.region, on: screen, margins: margins)
      targetScreen = screen
    } catch {
      print("Resize failed: \(error.localizedDescription)")
    }

    lastPresetKeyCode = preset.keyCode
    activeRegion = preset.region
  }
}
