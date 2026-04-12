import Cocoa

// MARK: - Grid Region

/// Describes a rectangular region within a grid, used to compute proportional screen frames.
public struct GridRegion: Codable, Equatable, Hashable {
  /// 0-based start column.
  public var column: Int
  /// 0-based start row.
  public var row: Int
  /// Number of columns the region spans.
  public var columnSpan: Int
  /// Number of rows the region spans.
  public var rowSpan: Int
  /// Total columns in the grid.
  public var gridColumns: Int
  /// Total rows in the grid.
  public var gridRows: Int

  public init(
    column: Int, row: Int,
    columnSpan: Int, rowSpan: Int,
    gridColumns: Int, gridRows: Int
  ) {
    self.column = column
    self.row = row
    self.columnSpan = columnSpan
    self.rowSpan = rowSpan
    self.gridColumns = gridColumns
    self.gridRows = gridRows
  }
}

// MARK: - Window Resizer

public enum WindowResizeError: LocalizedError {
  case noFrontmostApp
  case noFocusedWindow
  case noScreen
  case axSetPositionFailed
  case axSetSizeFailed

  public var errorDescription: String? {
    switch self {
    case .noFrontmostApp: "No frontmost application"
    case .noFocusedWindow: "Could not get focused window"
    case .noScreen: "Could not determine screen for window"
    case .axSetPositionFailed: "Failed to set window position"
    case .axSetSizeFailed: "Failed to set window size"
    }
  }
}

public enum WindowResizer {

  // MARK: - AX Write Helpers

  /// Sets the position of an AX window element. Returns true on success.
  @discardableResult
  public static func setAXPosition(_ element: AXUIElement, _ point: CGPoint) -> Bool {
    var p = point
    guard let value = AXValueCreate(.cgPoint, &p) else { return false }
    return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
  }

  /// Sets the size of an AX window element. Returns true on success.
  @discardableResult
  public static func setAXSize(_ element: AXUIElement, _ size: CGSize) -> Bool {
    var s = size
    guard let value = AXValueCreate(.cgSize, &s) else { return false }
    return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
  }

  // MARK: - Focused Window Resolution

  /// Returns the AXUIElement for the focused window of the frontmost application.
  public static func focusedWindow() throws -> (element: AXUIElement, pid: pid_t) {
    guard let app = NSWorkspace.shared.frontmostApplication else {
      throw WindowResizeError.noFrontmostApp
    }
    let pid = app.processIdentifier
    let axApp = AXUIElementCreateApplication(pid)
    var ref: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
      let windowRef = ref
    else {
      throw WindowResizeError.noFocusedWindow
    }
    // swiftlint:disable:next force_cast
    return (windowRef as! AXUIElement, pid)
  }

  // MARK: - Screen Detection

  /// Returns the NSScreen that contains the given AX window element.
  public static func screen(for element: AXUIElement) -> NSScreen? {
    guard let pos = SpaceManager.axPosition(element),
      let size = SpaceManager.axSize(element)
    else { return nil }
    let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
    // AX coordinates are top-left origin; NSScreen.frame is bottom-left origin.
    // Convert AX center to Cocoa coordinates for screen matching.
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    let cocoaCenter = CGPoint(x: center.x, y: primaryHeight - center.y)
    return NSScreen.screens.first { $0.frame.contains(cocoaCenter) } ?? NSScreen.main
  }

  // MARK: - Frame Calculation

  /// Computes the target window frame for a grid region within a screen's visible area.
  /// The returned frame uses AX coordinates (top-left origin).
  public static func targetFrame(
    for region: GridRegion, on screen: NSScreen, margins: CGFloat = 0
  ) -> CGRect {
    let visible = screen.visibleFrame
    let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height

    let cellWidth = visible.width / CGFloat(region.gridColumns)
    let cellHeight = visible.height / CGFloat(region.gridRows)

    // Cocoa coordinates (bottom-left origin)
    let cocoaX = visible.origin.x + CGFloat(region.column) * cellWidth + margins
    // Rows are numbered top-to-bottom in the grid, but Cocoa Y increases upward.
    // Row 0 = top of visible area = highest Cocoa Y.
    let cocoaY =
      visible.origin.y + visible.height - CGFloat(region.row + region.rowSpan) * cellHeight
      + margins
    let width = CGFloat(region.columnSpan) * cellWidth - 2 * margins
    let height = CGFloat(region.rowSpan) * cellHeight - 2 * margins

    // Convert to AX coordinates (top-left origin)
    let axX = cocoaX
    let axY = primaryHeight - (cocoaY + height)

    return CGRect(x: axX, y: axY, width: max(width, 1), height: max(height, 1))
  }

  // MARK: - Resize

  /// Resizes the given AX window element to match a grid region on the specified screen.
  public static func resize(
    _ element: AXUIElement, to region: GridRegion, on screen: NSScreen, margins: CGFloat = 0
  ) throws {
    let frame = targetFrame(for: region, on: screen, margins: margins)
    // Set size first (some apps clamp position based on current size), then position, then
    // size again to handle apps that constrain size based on position.
    guard setAXSize(element, frame.size) else { throw WindowResizeError.axSetSizeFailed }
    guard setAXPosition(element, frame.origin) else { throw WindowResizeError.axSetPositionFailed }
    setAXSize(element, frame.size)
  }

  /// Convenience: resizes the frontmost application's focused window.
  public static func resizeFocusedWindow(
    to region: GridRegion, margins: CGFloat = 0
  ) throws {
    let (element, _) = try focusedWindow()
    guard let screen = screen(for: element) else { throw WindowResizeError.noScreen }
    try resize(element, to: region, on: screen, margins: margins)
  }
}
