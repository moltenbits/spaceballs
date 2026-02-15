import Cocoa

// MARK: - Data Models

public struct SpaceInfo {
  public let id: UInt64
  public let uuid: String
  public let type: CGSSpaceType
  public let displayUUID: String
  public let isCurrent: Bool

  public init(
    id: UInt64, uuid: String, type: CGSSpaceType,
    displayUUID: String, isCurrent: Bool
  ) {
    self.id = id
    self.uuid = uuid
    self.type = type
    self.displayUUID = displayUUID
    self.isCurrent = isCurrent
  }
}

public struct WindowInfo {
  public let id: Int
  public let ownerName: String
  public let name: String?
  public let pid: Int
  public let bounds: CGRect
  public let spaceIDs: [UInt64]

  /// Window appears on multiple spaces (e.g. "Assign to All Desktops")
  public var isSticky: Bool { spaceIDs.count > 1 }

  public init(
    id: Int, ownerName: String, name: String?,
    pid: Int, bounds: CGRect, spaceIDs: [UInt64]
  ) {
    self.id = id
    self.ownerName = ownerName
    self.name = name
    self.pid = pid
    self.bounds = bounds
    self.spaceIDs = spaceIDs
  }
}

// MARK: - SpaceManager

public class SpaceManager {
  private let dataSource: SystemDataSource

  public init(dataSource: SystemDataSource = CGSDataSource()) {
    self.dataSource = dataSource
  }

  /// Enumerates all Spaces across all displays.
  public func getAllSpaces() -> [SpaceInfo] {
    let raw = dataSource.fetchManagedDisplaySpaces()

    var spaces: [SpaceInfo] = []

    for display in raw {
      guard let displayUUID = display["Display Identifier"] as? String,
        let spaceList = display["Spaces"] as? [[String: Any]],
        let currentSpace = display["Current Space"] as? [String: Any],
        let currentSpaceID = currentSpace["ManagedSpaceID"] as? Int
      else {
        continue
      }

      for space in spaceList {
        guard let spaceID = space["ManagedSpaceID"] as? Int,
          let uuid = space["uuid"] as? String,
          let typeRaw = space["type"] as? Int
        else {
          continue
        }

        spaces.append(
          SpaceInfo(
            id: UInt64(spaceID),
            uuid: uuid,
            type: CGSSpaceType(rawValue: typeRaw) ?? .desktop,
            displayUUID: displayUUID,
            isCurrent: spaceID == currentSpaceID
          ))
      }
    }

    return spaces
  }

  /// Enumerates all normal-layer windows.
  ///
  /// - Note: Window names from other apps require Screen Recording permission
  ///   to be granted to your terminal emulator.
  public func getAllWindows() -> [WindowInfo] {
    let windowList = dataSource.fetchWindowList()

    var windows: [WindowInfo] = []

    for entry in windowList {
      guard let windowID = entry[kCGWindowNumber as String] as? Int,
        let ownerName = entry[kCGWindowOwnerName as String] as? String,
        let pid = entry[kCGWindowOwnerPID as String] as? Int,
        let layer = entry[kCGWindowLayer as String] as? Int
      else {
        continue
      }

      // Layer 0 = normal application windows.
      // Higher layers are system chrome (menubar, dock, spotlight, etc.)
      guard layer == 0 else { continue }

      let name = entry[kCGWindowName as String] as? String

      var bounds = CGRect.zero
      if let boundsRef = entry[kCGWindowBounds as String] {
        let boundsDict = boundsRef as CFTypeRef as! CFDictionary
        CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds)
      }

      // Skip tiny windows (likely invisible helper windows)
      guard bounds.width > 50 && bounds.height > 50 else { continue }

      let spaceIDs = dataSource.fetchSpacesForWindow(windowID)

      windows.append(
        WindowInfo(
          id: windowID,
          ownerName: ownerName,
          name: name,
          pid: pid,
          bounds: bounds,
          spaceIDs: spaceIDs
        ))
    }

    return windows
  }

  /// Returns all spaces and windows grouped by space ID.
  public func windowsBySpace() -> (spaces: [SpaceInfo], windowMap: [UInt64: [WindowInfo]]) {
    let spaces = getAllSpaces()
    let windows = getAllWindows()

    var windowMap: [UInt64: [WindowInfo]] = [:]
    for space in spaces {
      windowMap[space.id] = []
    }

    for window in windows {
      for spaceID in window.spaceIDs {
        windowMap[spaceID, default: []].append(window)
      }
    }

    return (spaces, windowMap)
  }

  // MARK: - Window Activation

  /// Activates (brings to front) the window with the given CGWindowID.
  ///
  /// Uses the same private SkyLight APIs as yabai and AltTab:
  /// 1. `_SLPSSetFrontProcessWithOptions` — targets a specific CGWindowID,
  ///    triggering macOS's automatic space-switch animation
  /// 2. `SLPSPostEventRecordTo` — synthetic key-window events
  /// 3. `AXUIElementPerformAction(kAXRaiseAction)` — z-order raise (best-effort)
  ///
  /// Requires Accessibility permission to be granted to the calling process.
  public func activateWindow(id windowID: Int) throws {
    let log = { (msg: String) in _ = fputs("[spacebar] \(msg)\n", stderr) }

    log("Bundle ID: \(Bundle.main.bundleIdentifier ?? "nil")")
    log("Target window ID: \(windowID)")

    // 1. Find the window in our enumeration
    let windows = getAllWindows()
    guard let window = windows.first(where: { $0.id == windowID }) else {
      throw WindowActivationError.windowNotFound(windowID: windowID)
    }

    log("Found: \(window.ownerName) (pid \(window.pid)) — \"\(window.name ?? "<no title>")\"")
    log("Window spaces: \(window.spaceIDs)")

    // Find which space is current
    let spaces = getAllSpaces()
    let currentSpace = spaces.first(where: { $0.isCurrent })
    log("Current space: \(currentSpace?.id ?? 0)")

    let windowOnCurrentSpace = window.spaceIDs.contains(where: { sid in
      spaces.first(where: { $0.id == sid })?.isCurrent == true
    })
    log("Window on current space: \(windowOnCurrentSpace)")

    // 2. Check AX trust
    guard AXIsProcessTrusted() else {
      throw WindowActivationError.accessibilityNotTrusted
    }
    log("AX trusted: true")

    // 3. Get the ProcessSerialNumber for the owning app
    let pid = pid_t(window.pid)
    var psn = ProcessSerialNumber()
    let psnResult = GetProcessForPID(pid, &psn)
    log("GetProcessForPID: \(psnResult) — PSN: \(psn.highLongOfPSN):\(psn.lowLongOfPSN)")

    let wid = CGWindowID(windowID)

    // 4. Bring the process to front targeting the specific window.
    let slpsResult = _SLPSSetFrontProcessWithOptions(&psn, wid, 0x200)
    log("_SLPSSetFrontProcessWithOptions(\(wid), 0x200): \(slpsResult.rawValue)")

    // 5. Send synthetic key-window events to make it the key window.
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8
    bytes[0x3a] = 0x10
    bytes.withUnsafeMutableBufferPointer { buf in
      var widCopy = wid
      memcpy(buf.baseAddress! + 0x3c, &widCopy, MemoryLayout<UInt32>.size)
      memset(buf.baseAddress! + 0x20, 0xff, 0x10)
    }
    bytes[0x08] = 0x01
    let evt1 = SLPSPostEventRecordTo(&psn, &bytes)
    bytes[0x08] = 0x02
    let evt2 = SLPSPostEventRecordTo(&psn, &bytes)
    log("SLPSPostEventRecordTo: evt1=\(evt1.rawValue), evt2=\(evt2.rawValue)")

    // 6. Raise via AX for z-ordering
    let appElement = AXUIElementCreateApplication(pid)
    var axWindowsRef: CFTypeRef?
    let attrResult = AXUIElementCopyAttributeValue(
      appElement, kAXWindowsAttribute as CFString, &axWindowsRef)
    log("AXUIElementCopyAttributeValue(kAXWindows): \(attrResult.rawValue)")

    if attrResult == .success, let axWindows = axWindowsRef as? [AXUIElement] {
      log("AX windows count: \(axWindows.count)")
      if let axWindow = findAXWindowByID(windowID, in: axWindows) {
        let raiseResult = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        log("AXUIElementPerformAction(kAXRaise): \(raiseResult.rawValue)")
      } else {
        log("AX window ID \(windowID) not matched — trying all AX windows:")
        for (i, ax) in axWindows.enumerated() {
          var axWid: CGWindowID = 0
          let r = _AXUIElementGetWindow(ax, &axWid)
          log("  AX[\(i)]: _AXUIElementGetWindow=\(r.rawValue), cgWindowID=\(axWid)")
        }
      }
    }

    // 7. Trigger space switch via Apple Events.
    //    NSRunningApplication.activate() talks to WindowServer directly and
    //    does NOT trigger the Dock's space-switch animation on Sequoia.
    //    Apple Events go through the target app's event handler, which the
    //    Dock observes and responds to with a space switch.
    let runningApp = NSRunningApplication(processIdentifier: pid)
    if let bundleID = runningApp?.bundleIdentifier {
      let script = NSAppleScript(source: "tell application id \"\(bundleID)\" to activate")
      var errorInfo: NSDictionary?
      script?.executeAndReturnError(&errorInfo)
      if let err = errorInfo {
        log("AppleScript activate error: \(err)")
      } else {
        log("AppleScript activate: success (bundle: \(bundleID))")
      }
    } else {
      // Fallback for apps without bundle ID — use app name
      let script = NSAppleScript(
        source: "tell application \"\(window.ownerName)\" to activate")
      var errorInfo: NSDictionary?
      script?.executeAndReturnError(&errorInfo)
      if let err = errorInfo {
        log("AppleScript activate error: \(err)")
      } else {
        log("AppleScript activate: success (name: \(window.ownerName))")
      }
    }
  }

  /// Matches an AXUIElement window to a CGWindowID using `_AXUIElementGetWindow`.
  private func findAXWindowByID(_ targetID: Int, in axWindows: [AXUIElement]) -> AXUIElement? {
    for axWindow in axWindows {
      var cgWindowID: CGWindowID = 0
      if _AXUIElementGetWindow(axWindow, &cgWindowID) == .success,
        Int(cgWindowID) == targetID
      {
        return axWindow
      }
    }
    return nil
  }

}
