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

  /// Posted after `WindowResizer` successfully changes a window's frame.
  /// userInfo: ["pid": pid_t, "bundleID": String, "element": AXUIElement]
  public static let didResizeWindowNotification = Notification.Name(
    "com.moltenbits.spaceballs.didResizeWindow")

  // MARK: - AX Write Helpers

  /// Sets the position of an AX window element. Returns true on success.
  @discardableResult
  public static func setAXPosition(_ element: AXUIElement, _ point: CGPoint) -> Bool {
    var p = point
    guard let value = AXValueCreate(.cgPoint, &p) else { return false }
    return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
      == .success
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
  /// `completion` fires after the async write chain finishes — used to defer follow-up
  /// actions (notification, panel-hide) that would otherwise race with the resize.
  public static func resize(
    _ element: AXUIElement, to region: GridRegion, on screen: NSScreen, margins: CGFloat = 0,
    pid: pid_t? = nil, completion: (() -> Void)? = nil
  ) throws {
    let frame = targetFrame(for: region, on: screen, margins: margins)
    let visible = screen.visibleFrame
    let screens = NSScreen.screens
    let screenIdx = screens.firstIndex(of: screen) ?? -1
    let allFrames = screens.map { s -> String in
      let f = s.frame
      let vf = s.visibleFrame
      return
        "frame=(\(Int(f.origin.x)),\(Int(f.origin.y)))/\(Int(f.width))x\(Int(f.height))"
        + " visible=(\(Int(vf.origin.x)),\(Int(vf.origin.y)))/\(Int(vf.width))x\(Int(vf.height))"
    }.joined(separator: " | ")
    debugLog(
      "resize region=(c=\(region.column),r=\(region.row),cs=\(region.columnSpan),rs=\(region.rowSpan),gc=\(region.gridColumns),gr=\(region.gridRows)) "
        + "targetScreen[\(screenIdx)/\(screens.count)].visible=(\(Int(visible.origin.x)),\(Int(visible.origin.y)))/\(Int(visible.width))x\(Int(visible.height)) "
        + "allScreens=[\(allFrames)]"
    )
    try setFrame(element, frame: frame, label: "resize") {
      if let pid {
        postDidResize(element: element, pid: pid)
      }
      completion?()
    }
  }

  /// Strict-serialized resize: move first, *wait for the move to actually complete*, then
  /// resize, *wait for the resize to actually complete*. "Complete" means the AX read has
  /// matched the target value continuously for `stableDuration` — touching the target once
  /// isn't enough, because some apps (iTerm) report the target immediately after the write
  /// returns and then drift as their internal animation runs. We require N consecutive
  /// reads at the target before considering the write done.
  ///
  /// Two writes total, no overlap, no third corrective write. `completion` fires only after
  /// the final stability check passes.
  static func setFrame(
    _ element: AXUIElement, frame: CGRect, label: String = "setFrame",
    completion: (() -> Void)? = nil
  ) throws {
    let bundleID = bundleIDForElement(element) ?? "?"
    debugLog(
      "\(label) app=\(bundleID) target=(\(Int(frame.origin.x)),\(Int(frame.origin.y)))/\(Int(frame.size.width))x\(Int(frame.size.height)) before=\(currentFrameString(element))"
    )

    let posOK = setAXPosition(element, frame.origin)
    debugLog(
      "\(label) step=setPos returnedOK=\(posOK) frame=\(currentFrameString(element))"
    )
    guard posOK else { throw WindowResizeError.axSetPositionFailed }

    waitUntilAtTarget(
      element: element, posTarget: frame.origin, sizeTarget: nil,
      label: label, phase: "after-setPos"
    ) {
      let sizeOK = setAXSize(element, frame.size)
      debugLog(
        "\(label) step=setSize returnedOK=\(sizeOK) frame=\(currentFrameString(element))"
      )

      waitUntilAtTarget(
        element: element, posTarget: nil, sizeTarget: frame.size,
        label: label, phase: "after-setSize"
      ) {
        debugLog("\(label) done final=\(currentFrameString(element))")
        completion?()
      }
    }
  }

  private static let positionTolerance: CGFloat = 2
  private static let sizeTolerance: CGFloat = 5

  /// Polls the window's WindowServer-reported frame until the watched attribute(s) have
  /// been at the target continuously for `stableDuration`. **We use WindowServer (via
  /// `CGWindowListCopyWindowInfo`), not AX**, because the AX layer in some apps (notably
  /// iTerm) reports the target value immediately after `setAXPosition` returns, *while
  /// the window is still visually animating*. WindowServer reflects the actual on-screen
  /// bounds, so it changes during the animation and only stabilizes when the animation
  /// completes — which is what we actually care about.
  ///
  /// Drift detection: if the watched attribute leaves the target tolerance after first
  /// reaching it, the timer resets — so a brief AX-style "lie" + later visual drift
  /// gets caught.
  ///
  /// Exits early on `maxWait` to avoid hanging when the app silently refuses a write.
  private static func waitUntilAtTarget(
    element: AXUIElement, posTarget: CGPoint?, sizeTarget: CGSize?,
    label: String, phase: String, completion: @escaping () -> Void
  ) {
    let pollInterval: TimeInterval = 0.025
    let stableDuration: TimeInterval = 0.060
    let maxWait: TimeInterval = 1.5
    let startTime = Date()
    var firstAtTarget: Date? = nil
    var cgWid: CGWindowID = 0
    let haveWindowID = _AXUIElementGetWindow(element, &cgWid) == .success

    func poll() {
      // Prefer WindowServer-reported bounds (reflect actual visual state). Fall back to
      // AX reads if we can't get a CGWindowID — better than nothing.
      let actualFrame: CGRect?
      if haveWindowID {
        actualFrame = cgWindowFrame(forID: cgWid)
      } else if let pos = SpaceManager.axPosition(element),
        let size = SpaceManager.axSize(element)
      {
        actualFrame = CGRect(origin: pos, size: size)
      } else {
        actualFrame = nil
      }

      guard let frame = actualFrame else {
        debugLog("\(label) \(phase) frame read failed; aborting wait")
        completion()
        return
      }

      var atTarget = true
      if let posTarget = posTarget {
        let dx = abs(frame.origin.x - posTarget.x)
        let dy = abs(frame.origin.y - posTarget.y)
        if dx >= positionTolerance || dy >= positionTolerance { atTarget = false }
      }
      if let sizeTarget = sizeTarget {
        let dw = abs(frame.size.width - sizeTarget.width)
        let dh = abs(frame.size.height - sizeTarget.height)
        if dw >= sizeTolerance || dh >= sizeTolerance { atTarget = false }
      }

      if atTarget {
        if firstAtTarget == nil {
          firstAtTarget = Date()
        }
        if Date().timeIntervalSince(firstAtTarget!) >= stableDuration {
          debugLog(
            "\(label) \(phase) at-target+stable after \(Int(Date().timeIntervalSince(startTime) * 1000))ms cgFrame=(\(Int(frame.origin.x)),\(Int(frame.origin.y)))/\(Int(frame.width))x\(Int(frame.height))"
          )
          completion()
          return
        }
      } else {
        if firstAtTarget != nil {
          debugLog(
            "\(label) \(phase) drifted off target at \(Int(Date().timeIntervalSince(startTime) * 1000))ms cgFrame=(\(Int(frame.origin.x)),\(Int(frame.origin.y)))/\(Int(frame.width))x\(Int(frame.height))"
          )
        }
        firstAtTarget = nil
      }

      if Date().timeIntervalSince(startTime) > maxWait {
        debugLog(
          "\(label) \(phase) timeout after \(Int(maxWait * 1000))ms cgFrame=(\(Int(frame.origin.x)),\(Int(frame.origin.y)))/\(Int(frame.width))x\(Int(frame.height))"
        )
        completion()
        return
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { poll() }
    }

    poll()
  }

  /// Reads a window's frame from WindowServer via `CGWindowListCopyWindowInfo`. Unlike AX
  /// reads, this reflects the actual on-screen bounds — including in-progress animations.
  private static func cgWindowFrame(forID cgWid: CGWindowID) -> CGRect? {
    guard
      let infos = CGWindowListCopyWindowInfo(.optionIncludingWindow, cgWid)
        as? [[String: Any]],
      let info = infos.first,
      let boundsRef = info[kCGWindowBounds as String]
    else { return nil }
    var bounds = CGRect.zero
    CGRectMakeWithDictionaryRepresentation(boundsRef as CFTypeRef as! CFDictionary, &bounds)
    return bounds
  }

  /// Polls the element's frame until two consecutive reads (30ms apart) match, indicating
  /// any in-progress animation has completed. Bails out after `maxWait` to avoid hanging if
  /// the app never stops twitching (or its frame perpetually drifts).
  private static func waitUntilSettled(
    element: AXUIElement, maxWait: TimeInterval = 1.0, completion: @escaping () -> Void
  ) {
    let pollInterval: TimeInterval = 0.030
    let stableThreshold: CGFloat = 1
    let startTime = Date()
    var lastFrame: CGRect?

    func poll() {
      guard let pos = SpaceManager.axPosition(element),
        let size = SpaceManager.axSize(element)
      else {
        completion()
        return
      }
      let currentFrame = CGRect(origin: pos, size: size)

      if let last = lastFrame {
        let stable =
          abs(currentFrame.origin.x - last.origin.x) < stableThreshold
          && abs(currentFrame.origin.y - last.origin.y) < stableThreshold
          && abs(currentFrame.size.width - last.size.width) < stableThreshold
          && abs(currentFrame.size.height - last.size.height) < stableThreshold
        if stable {
          completion()
          return
        }
      }

      lastFrame = currentFrame

      if Date().timeIntervalSince(startTime) > maxWait {
        completion()
        return
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { poll() }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { poll() }
  }

  // MARK: - Diagnostics

  private static let debugLogPath = "/tmp/spaceballs-resize.log"
  private static let debugLogQueue = DispatchQueue(label: "com.moltenbits.spaceballs.resize-log")
  private static let debugLogDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
  }()

  static func debugLog(_ message: String) {
    let timestamp = debugLogDateFormatter.string(from: Date())
    let line = "\(timestamp) \(message)\n"
    debugLogQueue.async {
      guard let data = line.data(using: .utf8) else { return }
      let url = URL(fileURLWithPath: debugLogPath)
      if FileManager.default.fileExists(atPath: debugLogPath) {
        if let handle = try? FileHandle(forWritingTo: url) {
          defer { try? handle.close() }
          try? handle.seekToEnd()
          try? handle.write(contentsOf: data)
        }
      } else {
        try? data.write(to: url)
      }
    }
  }

  private static func currentFrameString(_ element: AXUIElement) -> String {
    let p = SpaceManager.axPosition(element) ?? .zero
    let s = SpaceManager.axSize(element) ?? .zero
    return "(\(Int(p.x)),\(Int(p.y)))/\(Int(s.width))x\(Int(s.height))"
  }

  private static func bundleIDForElement(_ element: AXUIElement) -> String? {
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return nil }
    return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
  }

  /// Convenience: resizes the frontmost application's focused window.
  public static func resizeFocusedWindow(
    to region: GridRegion, margins: CGFloat = 0
  ) throws {
    let (element, pid) = try focusedWindow()
    guard let screen = screen(for: element) else { throw WindowResizeError.noScreen }
    try resize(element, to: region, on: screen, margins: margins, pid: pid)
  }

  // MARK: - Notifications

  private static func postDidResize(element: AXUIElement, pid: pid_t) {
    let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
    NotificationCenter.default.post(
      name: didResizeWindowNotification,
      object: nil,
      userInfo: [
        "pid": pid,
        "bundleID": bundleID,
        "element": element,
      ]
    )
  }
}
