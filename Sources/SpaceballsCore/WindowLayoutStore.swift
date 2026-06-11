import Cocoa

// MARK: - Data Models

/// A window's frame stored as offsets relative to the captured display's
/// `visibleFrame` origin in AX coordinates (top-left origin).
public struct WindowFrame: Codable, Equatable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

/// All apps' frames for a specific (Space, display) pairing.
public struct SpaceDisplayLayout: Codable {
  public var spaceUUID: String
  public var displayUUID: String
  public var apps: [String: WindowFrame]
  public var capturedAt: Date

  public init(
    spaceUUID: String, displayUUID: String,
    apps: [String: WindowFrame] = [:], capturedAt: Date = Date()
  ) {
    self.spaceUUID = spaceUUID
    self.displayUUID = displayUUID
    self.apps = apps
    self.capturedAt = capturedAt
  }
}

// MARK: - Display Helpers

/// EDID-derived UUID for a screen — stable across plug/unplug for the same physical monitor.
public func spaceballsDisplayUUID(for screen: NSScreen) -> String? {
  guard
    let screenNumber = screen.deviceDescription[
      NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
    let cfUUID = CGDisplayCreateUUIDFromDisplayID(screenNumber)?.takeUnretainedValue()
  else { return nil }
  return CFUUIDCreateString(nil, cfUUID) as String
}

/// Finds the NSScreen whose EDID UUID matches the given displayUUID.
public func spaceballsScreen(forDisplayUUID uuid: String) -> NSScreen? {
  NSScreen.screens.first { spaceballsDisplayUUID(for: $0) == uuid }
}

/// AX origin of a screen (top-left origin from primary display top).
/// AX X = Cocoa X. AX Y = primaryDisplayHeight - (Cocoa Y + height).
public func spaceballsAXOrigin(of screen: NSScreen) -> CGPoint {
  let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
  let visible = screen.visibleFrame
  return CGPoint(x: visible.minX, y: primaryHeight - visible.maxY)
}

// MARK: - Window Layout Store

public final class WindowLayoutStore {
  private let defaults: UserDefaults
  private let spaceManager: SpaceManager
  private let layoutsKey = "windowLayouts"
  private let lastDisplayKey = "spaceLastDisplay"

  private var layouts: [String: SpaceDisplayLayout]
  private var lastSeenDisplay: [String: String]

  public init(defaults: UserDefaults = .standard, spaceManager: SpaceManager) {
    self.defaults = defaults
    self.spaceManager = spaceManager

    if let data = defaults.data(forKey: layoutsKey),
      let decoded = try? JSONDecoder().decode([String: SpaceDisplayLayout].self, from: data)
    {
      self.layouts = decoded
    } else {
      self.layouts = [:]
    }

    self.lastSeenDisplay = (defaults.dictionary(forKey: lastDisplayKey) as? [String: String]) ?? [:]
  }

  // MARK: - Persistence

  public func layout(spaceUUID: String, displayUUID: String) -> SpaceDisplayLayout? {
    layouts[Self.key(spaceUUID, displayUUID)]
  }

  public func setFrame(
    bundleID: String, frame: WindowFrame, spaceUUID: String, displayUUID: String
  ) {
    let key = Self.key(spaceUUID, displayUUID)
    var layout =
      layouts[key]
      ?? SpaceDisplayLayout(spaceUUID: spaceUUID, displayUUID: displayUUID)
    layout.apps[bundleID] = frame
    layout.capturedAt = Date()
    layouts[key] = layout
    persistLayouts()
  }

  public func clearAll() {
    layouts = [:]
    lastSeenDisplay = [:]
    defaults.removeObject(forKey: layoutsKey)
    defaults.removeObject(forKey: lastDisplayKey)
  }

  public func lastSeenDisplayUUID(forSpace spaceUUID: String) -> String? {
    lastSeenDisplay[spaceUUID]
  }

  public func setLastSeenDisplay(spaceUUID: String, displayUUID: String) {
    lastSeenDisplay[spaceUUID] = displayUUID
    defaults.set(lastSeenDisplay, forKey: lastDisplayKey)
  }

  // MARK: - Capture

  /// Captures the focused window's frame for an app and stores it against the
  /// (Space, display) pair the window currently sits on.
  public func captureWindow(pid: pid_t, bundleID: String) {
    let axApp = AXUIElementCreateApplication(pid)
    var ref: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
      let windowRef = ref
    else { return }
    // swiftlint:disable:next force_cast
    let element = windowRef as! AXUIElement
    captureWindow(element: element, bundleID: bundleID)
  }

  /// Captures a specific AX window element. Resolves its display + the current
  /// Space on that display, converts to display-relative coords, and persists.
  public func captureWindow(element: AXUIElement, bundleID: String) {
    guard let position = SpaceManager.axPosition(element),
      let size = SpaceManager.axSize(element)
    else { return }
    guard let screen = WindowResizer.screen(for: element),
      let displayUUID = spaceballsDisplayUUID(for: screen)
    else { return }

    let spaces = spaceManager.getAllSpaces()
    guard let currentSpace = spaces.first(where: { $0.isCurrent && $0.displayUUID == displayUUID })
    else { return }

    let origin = spaceballsAXOrigin(of: screen)
    let relative = WindowFrame(
      x: Double(position.x - origin.x),
      y: Double(position.y - origin.y),
      width: Double(size.width),
      height: Double(size.height)
    )
    setFrame(
      bundleID: bundleID, frame: relative,
      spaceUUID: currentSpace.uuid, displayUUID: displayUUID)
    setLastSeenDisplay(spaceUUID: currentSpace.uuid, displayUUID: displayUUID)
  }

  // MARK: - Restore

  /// Applies the saved layout for (spaceUUID, displayUUID) to each saved app's windows
  /// **that are actually on that space**. Returns the count of windows moved.
  ///
  /// The per-window space check exists because `kAXWindowsAttribute` returns windows
  /// from every space, not just the current one (despite Apple's documentation implying
  /// otherwise — Safari, iTerm, and JetBrains IDEs all demonstrate this). Without the
  /// check, restoring a space that moved displays stamped cross-display coordinates
  /// onto other spaces' windows, physically dragging them into whatever space was
  /// active on the target display (issue #3).
  @discardableResult
  public func restore(spaceUUID: String, displayUUID: String) -> Int {
    let token = Diagnostics.beginTiming(
      "layout-restore", "restore",
      extras: ["space": spaceUUID, "display": displayUUID])
    guard let layout = layout(spaceUUID: spaceUUID, displayUUID: displayUUID) else {
      Diagnostics.endTiming(token, outcome: "no-layout-for-pair")
      return 0
    }
    guard let screen = spaceballsScreen(forDisplayUUID: displayUUID) else {
      Diagnostics.endTiming(token, outcome: "display-not-attached")
      return 0
    }
    guard let targetSpaceID = spaceID(forUUID: spaceUUID) else {
      // Can't resolve the space — restoring blind risks exactly the cross-space
      // moves this method must never make. Restore nothing.
      Diagnostics.endTiming(token, outcome: "space-uuid-unresolved")
      return 0
    }

    let origin = spaceballsAXOrigin(of: screen)
    var moved = 0
    var skippedOffSpace = 0

    Diagnostics.log(
      "layout-restore", "applying layout apps=\(layout.apps.count) targetSpaceID=\(targetSpaceID)")

    for (bundleID, relative) in layout.apps {
      let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
      if runningApps.isEmpty {
        Diagnostics.log("layout-restore", "skip — app not running", app: bundleID)
        continue
      }
      for app in runningApps {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard
          AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
          let raw = ref as? [AXUIElement]
        else {
          Diagnostics.log("layout-restore", "skip — windows unreadable", app: bundleID)
          continue
        }

        let absolute = CGRect(
          x: origin.x + CGFloat(relative.x),
          y: origin.y + CGFloat(relative.y),
          width: CGFloat(relative.width),
          height: CGFloat(relative.height)
        )

        for window in raw {
          var cgWid: CGWindowID = 0
          guard _AXUIElementGetWindow(window, &cgWid) == .success else {
            Diagnostics.log(
              "layout-restore", "skip window — CGWindowID unresolved", app: bundleID)
            continue
          }
          guard windowIsOnSpace(windowID: Int(cgWid), spaceID: targetSpaceID) else {
            skippedOffSpace += 1
            Diagnostics.log(
              "layout-restore",
              "skip window=\(cgWid) — not on target space \(targetSpaceID)", app: bundleID)
            continue
          }
          guard
            (try? WindowResizer.setFrame(window, frame: absolute, label: "restore")) != nil
          else { continue }
          moved += 1
        }
      }
    }

    Diagnostics.endTiming(token, outcome: "moved=\(moved) skippedOffSpace=\(skippedOffSpace)")
    return moved
  }

  // MARK: - Space Filtering

  /// Resolves a space UUID to its ManagedSpaceID via the current CGS snapshot.
  func spaceID(forUUID uuid: String) -> UInt64? {
    spaceManager.getAllSpaces().first { $0.uuid == uuid }?.id
  }

  /// True when the window belongs to the given space. Windows CGS has no space record
  /// for return false — skipping a restore is recoverable, moving a window across
  /// spaces is not. Sticky windows report every space they appear on, so they pass
  /// for any of them.
  func windowIsOnSpace(windowID: Int, spaceID: UInt64) -> Bool {
    spaceManager.spaceIDs(forWindowID: windowID).contains(spaceID)
  }

  // MARK: - Internals

  private func persistLayouts() {
    if let data = try? JSONEncoder().encode(layouts) {
      defaults.set(data, forKey: layoutsKey)
    }
  }

  private static func key(_ spaceUUID: String, _ displayUUID: String) -> String {
    "\(spaceUUID)|\(displayUUID)"
  }
}
