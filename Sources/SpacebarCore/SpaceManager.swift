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
  public let isOnscreen: Bool

  /// Window appears on multiple spaces (e.g. "Assign to All Desktops")
  public var isSticky: Bool { spaceIDs.count > 1 }

  public init(
    id: Int, ownerName: String, name: String?,
    pid: Int, bounds: CGRect, spaceIDs: [UInt64],
    isOnscreen: Bool = true
  ) {
    self.id = id
    self.ownerName = ownerName
    self.name = name
    self.pid = pid
    self.bounds = bounds
    self.spaceIDs = spaceIDs
    self.isOnscreen = isOnscreen
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

    // Cache activation policy per PID to avoid repeated lookups.
    var policyCache: [pid_t: NSApplication.ActivationPolicy] = [:]

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

      // Skip windows with no title (auxiliary windows like Safari's toolbar
      // containers, web inspector panels, etc.)
      guard let name, !name.isEmpty else { continue }

      // Skip windows from menu bar / background apps (accessory or prohibited
      // activation policy). These never appear as normal user-facing windows.
      let pidT = pid_t(pid)
      let policy: NSApplication.ActivationPolicy
      if let cached = policyCache[pidT] {
        policy = cached
      } else if let app = NSRunningApplication(processIdentifier: pidT) {
        policy = app.activationPolicy
        policyCache[pidT] = policy
      } else {
        policy = .regular
      }
      guard policy == .regular else { continue }

      var bounds = CGRect.zero
      if let boundsRef = entry[kCGWindowBounds as String] {
        let boundsDict = boundsRef as CFTypeRef as! CFDictionary
        CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds)
      }

      // Skip tiny windows (likely invisible helper windows)
      guard bounds.width > 50 && bounds.height > 50 else { continue }

      let spaceIDs = dataSource.fetchSpacesForWindow(windowID)
      let isOnscreen = entry[kCGWindowIsOnscreen as String] as? Bool ?? false

      windows.append(
        WindowInfo(
          id: windowID,
          ownerName: ownerName,
          name: name,
          pid: pid,
          bounds: bounds,
          spaceIDs: spaceIDs,
          isOnscreen: isOnscreen
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
  /// Uses the same approach as AltTab:
  /// 1. Find the target window's AXUIElement via brute-force enumeration
  ///    (kAXWindowsAttribute cannot see windows on other Spaces)
  /// 2. `_SLPSSetFrontProcessWithOptions` — targets the specific CGWindowID,
  ///    triggering macOS's automatic space-switch animation
  /// 3. `SLPSPostEventRecordTo` — synthetic key-window events
  /// 4. `AXUIElementPerformAction(kAXRaiseAction)` — z-order raise
  ///
  /// Requires Accessibility permission to be granted to the calling process.
  public func activateWindow(id windowID: Int) throws {
    // 1. Find the window in our CGWindowList enumeration
    let windows = getAllWindows()
    guard let window = windows.first(where: { $0.id == windowID }) else {
      throw WindowActivationError.windowNotFound(windowID: windowID)
    }

    // 2. Check AX trust
    guard AXIsProcessTrusted() else {
      throw WindowActivationError.accessibilityNotTrusted
    }

    let pid = pid_t(window.pid)

    // 3. Find the AXUIElement for this window via brute-force enumeration.
    //    kAXWindowsAttribute does NOT return windows on other Spaces.
    //    We construct AXUIElement handles directly via _AXUIElementCreateWithRemoteToken,
    //    iterating AXUIElementID values until we find one matching our CGWindowID.
    //    (Workaround discovered by AltTab in Feb 2025, issue #1324.)
    let axElement = findAXWindowBruteForce(pid: pid, targetCGWindowID: CGWindowID(windowID))

    // 4. Get PSN and activate via SkyLight (same sequence as AltTab).
    //    _SLPSSetFrontProcessWithOptions targets the specific CGWindowID and
    //    triggers macOS's space-switch animation if the window is on another Space.
    var psn = ProcessSerialNumber()
    GetProcessForPID(pid, &psn)

    let wid = CGWindowID(windowID)
    _SLPSSetFrontProcessWithOptions(&psn, wid, 0x200)

    // 5. Send synthetic key-window events (Hammerspoon technique via AltTab).
    //    Two event records (type 0x01 key-down, 0x02 key-up) with the
    //    CGWindowID embedded at offset 0x3c in a 0xf8-byte record.
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8
    bytes[0x3a] = 0x10
    bytes.withUnsafeMutableBufferPointer { buf in
      var widCopy = wid
      memcpy(buf.baseAddress! + 0x3c, &widCopy, MemoryLayout<UInt32>.size)
      memset(buf.baseAddress! + 0x20, 0xff, 0x10)
    }
    bytes[0x08] = 0x01
    SLPSPostEventRecordTo(&psn, &bytes)
    bytes[0x08] = 0x02
    SLPSPostEventRecordTo(&psn, &bytes)

    // 6. Raise via AX for z-ordering within the app's window stack.
    if let axElement {
      AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
    }
  }

  // MARK: - Close Window

  /// Closes a window by pressing its AX close button (same approach as AltTab).
  /// AX operations are dispatched to a background queue to avoid blocking the
  /// main thread and to match AltTab's threading model.
  public func closeWindow(id windowID: Int) throws {
    let windows = getAllWindows()
    guard let window = windows.first(where: { $0.id == windowID }) else {
      throw WindowActivationError.windowNotFound(windowID: windowID)
    }

    guard AXIsProcessTrusted() else {
      throw WindowActivationError.accessibilityNotTrusted
    }

    let pid = pid_t(window.pid)
    let targetCGWindowID = CGWindowID(windowID)

    // Dispatch AX close to a background queue (same pattern as AltTab).
    DispatchQueue.global(qos: .userInteractive).async { [self] in
      guard
        let axWindow = findAXWindowStandard(pid: pid, targetCGWindowID: targetCGWindowID)
          ?? findAXWindowBruteForce(pid: pid, targetCGWindowID: targetCGWindowID)
      else {
        print("closeWindow: AX element not found for window \(windowID)")
        return
      }

      var closeButtonRef: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(
          axWindow, kAXCloseButtonAttribute as CFString, &closeButtonRef
        ) == .success,
        let closeButton = closeButtonRef
      else {
        print("closeWindow: close button not found for window \(windowID)")
        return
      }

      let result = AXUIElementPerformAction(
        closeButton as! AXUIElement, kAXPressAction as CFString)
      if result != .success {
        print("closeWindow: kAXPressAction failed (\(result.rawValue)) for window \(windowID)")
      }
    }
  }

  // MARK: - Quit App

  /// Terminates the app that owns the given window.
  public func quitApp(owningWindowID windowID: Int) throws {
    let windows = getAllWindows()
    guard let window = windows.first(where: { $0.id == windowID }) else {
      throw WindowActivationError.windowNotFound(windowID: windowID)
    }

    guard
      let app = NSRunningApplication(processIdentifier: pid_t(window.pid))
    else {
      return
    }

    app.terminate()
  }

  // MARK: - AX Window Discovery

  /// Finds an AXUIElement via the standard `kAXWindowsAttribute` API.
  /// Only returns windows on the current Space.
  private func findAXWindowStandard(
    pid: pid_t, targetCGWindowID: CGWindowID
  ) -> AXUIElement? {
    let appElement = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        == .success,
      let windows = windowsRef as? [AXUIElement]
    else {
      return nil
    }

    for window in windows {
      var cgWid: CGWindowID = 0
      if _AXUIElementGetWindow(window, &cgWid) == .success,
        cgWid == targetCGWindowID
      {
        return window
      }
    }
    return nil
  }

  /// Finds an AXUIElement for a window on any Space by brute-forcing
  /// AXUIElementID values via `_AXUIElementCreateWithRemoteToken`.
  ///
  /// `kAXWindowsAttribute` only returns windows on the current Space.
  /// This method constructs AXUIElement handles directly, iterating element
  /// IDs 0..999 and checking each for a matching CGWindowID.
  private func findAXWindowBruteForce(
    pid: pid_t, targetCGWindowID: CGWindowID
  ) -> AXUIElement? {
    // Build the 20-byte remote token template:
    //   bytes  0..3:  pid (Int32)
    //   bytes  4..7:  0 (Int32)
    //   bytes  8..11: 0x636f636f ("coco")
    //   bytes 12..19: AXUIElementID (UInt64, varies per iteration)
    var tokenData = Data(count: 20)
    tokenData.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
    tokenData.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
    tokenData.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })

    let startTime = DispatchTime.now()

    for elementID: UInt64 in 0..<1000 {
      tokenData.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })

      guard
        let unmanaged = _AXUIElementCreateWithRemoteToken(tokenData as CFData),
        case let element = unmanaged.takeRetainedValue()
      else {
        continue
      }

      // Check if this element is a window (standard or dialog)
      var subroleRef: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
          == .success,
        let subrole = subroleRef as? String,
        subrole == kAXStandardWindowSubrole as String
          || subrole == kAXDialogSubrole as String
      else {
        continue
      }

      // Check if this window's CGWindowID matches our target
      var cgWid: CGWindowID = 0
      if _AXUIElementGetWindow(element, &cgWid) == .success,
        cgWid == targetCGWindowID
      {
        return element
      }

      // Timeout after 100ms (same as AltTab) to avoid blocking too long
      let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
      if elapsed > 100_000_000 {
        break
      }
    }

    return nil
  }

}
