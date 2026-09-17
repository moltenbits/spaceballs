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

  public func appInfo(pid: pid_t) -> AppInfo? {
    guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
    return AppInfo(policy: app.activationPolicy, bundleID: app.bundleIdentifier)
  }

  public func liveAXWindowIDs(pid: pid_t) -> Set<CGWindowID>? {
    guard let axWindows = axWindows(pid: pid) else { return nil }

    // kAXWindowsAttribute covers the app's windows on the current Space (including
    // minimized ones) but not closed windows — exactly the liveness signal we need.
    return Set(
      axWindows.compactMap { axWindow in
        var windowID = CGWindowID(0)
        return _AXUIElementGetWindow(axWindow, &windowID) == .success ? windowID : nil
      })
  }

  public func axWindowPresence(pid: pid_t, windowID: CGWindowID) -> AXWindowPresence {
    guard let axWindows = axWindows(pid: pid) else { return .unknown }
    var unmapped = 0
    for axWindow in axWindows {
      var candidate = CGWindowID(0)
      guard _AXUIElementGetWindow(axWindow, &candidate) == .success else {
        unmapped += 1
        continue
      }
      if candidate == windowID { return .present }
    }
    return AXWindowPresence.resolve(targetFound: false, unmappedElements: unmapped)
  }

  public func minimizedAXWindowIDs(pid: pid_t) -> Set<CGWindowID>? {
    guard let axWindows = axWindows(pid: pid) else { return nil }

    var ids = Set<CGWindowID>()
    for axWindow in axWindows {
      var minimizedRef: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(
          axWindow, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
        minimizedRef as? Bool == true
      else { continue }

      var windowID = CGWindowID(0)
      if _AXUIElementGetWindow(axWindow, &windowID) == .success {
        ids.insert(windowID)
      }
    }
    return ids
  }

  private func axWindows(pid: pid_t) -> [AXUIElement]? {
    // Without AX trust the query returns nothing meaningful; report "unknown"
    // so callers do not infer liveness or minimization from a failed query.
    guard AXIsProcessTrusted() else { return nil }

    let appElement = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(
      appElement, kAXWindowsAttribute as CFString, &value)
    guard error == .success else { return nil }
    return value as? [AXUIElement]
  }
}
