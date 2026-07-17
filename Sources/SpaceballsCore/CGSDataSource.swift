import ApplicationServices
import Cocoa

/// Real implementation that calls private CGS/CG APIs.
public struct CGSDataSource: SystemDataSource {
  private let connection: CGSConnectionID

  public init() {
    self.connection = CGSMainConnectionID()
  }

  public func fetchManagedDisplaySpaces() -> [[String: Any]] {
    CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]] ?? []
  }

  public func fetchWindowList() -> [[String: Any]] {
    CGWindowListCopyWindowInfo(
      [.optionAll, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] ?? []
  }

  public func fetchOnScreenWindowList() -> [[String: Any]] {
    CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] ?? []
  }

  public func fetchSpacesForWindow(_ windowID: Int) -> [UInt64] {
    let windowArray = [windowID as CFNumber] as CFArray
    guard
      let result = CGSCopySpacesForWindows(
        connection,
        CGSSpaceMask.all.rawValue,
        windowArray
      ) as? [NSNumber]
    else {
      return []
    }
    return result.map { $0.uint64Value }
  }

  public func liveAXWindowIDs(pid: pid_t) -> Set<CGWindowID>? {
    // Without AX trust the query returns nothing meaningful; report "unknown"
    // so callers keep windows rather than hiding real ones.
    guard AXIsProcessTrusted() else { return nil }

    let appElement = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(
      appElement, kAXWindowsAttribute as CFString, &value)
    guard err == .success, let axWindows = value as? [AXUIElement] else {
      return nil
    }

    // kAXWindowsAttribute covers the app's windows on the current Space (including
    // minimized ones) but not closed windows — exactly the liveness signal we need.
    var ids = Set<CGWindowID>()
    for axWindow in axWindows {
      var windowID = CGWindowID(0)
      if _AXUIElementGetWindow(axWindow, &windowID) == .success {
        ids.insert(windowID)
      }
    }
    return ids
  }
}
