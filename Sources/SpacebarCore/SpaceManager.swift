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

  /// Returns the CGWindowID of the frontmost normal window on the given space,
  /// using the on-screen window list which guarantees front-to-back Z-order.
  /// Returns `nil` if no qualifying window is found.
  public func frontmostWindowID(onSpace spaceID: UInt64) -> Int? {
    let onScreen = dataSource.fetchOnScreenWindowList()
    var policyCache: [pid_t: NSApplication.ActivationPolicy] = [:]

    for entry in onScreen {
      guard let windowID = entry[kCGWindowNumber as String] as? Int,
        let pid = entry[kCGWindowOwnerPID as String] as? Int,
        let layer = entry[kCGWindowLayer as String] as? Int,
        layer == 0
      else { continue }

      let name = entry[kCGWindowName as String] as? String
      guard let name, !name.isEmpty else { continue }

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

      let spaces = dataSource.fetchSpacesForWindow(windowID)
      if spaces.contains(spaceID) {
        return windowID
      }
    }
    return nil
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

  // MARK: - Display UUID Resolution

  /// Resolves a CGS display UUID to a CGDirectDisplayID via NSScreen.
  public static func displayIDForUUID(_ uuid: String) -> CGDirectDisplayID? {
    screenForUUID(uuid).map { screen in
      screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
    }
  }

  /// Resolves a CGS display UUID to a human-readable display name (e.g. "Built-in Retina Display").
  public static func displayNameForUUID(_ uuid: String) -> String? {
    screenForUUID(uuid)?.localizedName
  }

  private static func screenForUUID(_ uuid: String) -> NSScreen? {
    for screen in NSScreen.screens {
      guard
        let screenNumber = screen.deviceDescription[
          NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
      else { continue }
      let cfUUID = CGDisplayCreateUUIDFromDisplayID(screenNumber)?.takeUnretainedValue()
      guard let cfUUID else { continue }
      let screenUUID = CFUUIDCreateString(nil, cfUUID) as String
      if screenUUID == uuid {
        return screen
      }
    }
    return nil
  }

  // MARK: - Accessibility

  /// Checks AX trust with an OS prompt if not yet granted.
  ///
  /// On first call for an untrusted process, macOS shows a system dialog
  /// and opens System Settings → Privacy & Security → Accessibility with
  /// the app pre-listed. Returns `true` if already trusted.
  @discardableResult
  public static func ensureAccessibilityTrusted() -> Bool {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    return AXIsProcessTrustedWithOptions(opts)
  }

  // MARK: - Space Switching (by ID)

  /// Switches to a space by its ManagedSpaceID.
  ///
  /// Enumerates all spaces, finds the one with the given ID, computes its
  /// ordinal index among desktop spaces on the same display, resolves the
  /// display UUID to a CGDirectDisplayID, and calls
  /// `switchToSpace(spaceIndex:screenNumber:)`.
  public func switchToSpace(id spaceID: UInt64) throws {
    let allSpaces = getAllSpaces()
    guard let targetSpace = allSpaces.first(where: { $0.id == spaceID }) else {
      throw SpaceSwitchError.spaceNotFound(spaceID: spaceID)
    }

    guard targetSpace.type == .desktop else {
      throw SpaceSwitchError.notDesktopSpace(spaceID: spaceID)
    }

    guard Self.ensureAccessibilityTrusted() else {
      throw SpaceSwitchError.accessibilityNotTrusted
    }

    let displaySpaces =
      allSpaces
      .filter { $0.displayUUID == targetSpace.displayUUID && $0.type == .desktop }

    guard let spaceIndex = displaySpaces.firstIndex(where: { $0.id == spaceID }) else {
      throw SpaceSwitchError.spaceNotFound(spaceID: spaceID)
    }

    guard let screenNumber = Self.displayIDForUUID(targetSpace.displayUUID) else {
      throw SpaceSwitchError.displayNotFound(displayUUID: targetSpace.displayUUID)
    }

    switchToSpace(spaceIndex: spaceIndex, screenNumber: screenNumber)
  }

  // MARK: - Space Switching (by index)

  /// Switches to the specified Space via the Dock's accessibility interface.
  ///
  /// Opens Mission Control by posting `com.apple.expose.awake`, navigates the
  /// Dock's AX hierarchy to find the target space button, and presses it.
  /// Works on Sequoia without SIP, unlike `CGSManagedDisplaySetCurrentSpace`.
  ///
  /// - Parameters:
  ///   - spaceIndex: 0-based ordinal position of the space on its display
  ///   - screenNumber: `CGDirectDisplayID` for the target display
  public func switchToSpace(spaceIndex: Int, screenNumber: CGDirectDisplayID) {
    guard AXIsProcessTrusted() else {
      print("switchToSpace: Accessibility not trusted")
      return
    }

    guard
      let dockApp = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.dock"
      ).first
    else {
      print("switchToSpace: Dock not running")
      return
    }

    let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)

    // Open Mission Control via the Dock's private CoreDock API.
    CoreDockSendNotification("com.apple.expose.awake" as CFString)

    DispatchQueue.global(qos: .userInteractive).async {
      // Poll for the Mission Control AX group to appear in the Dock's children.
      let mcGroup: AXUIElement? = {
        let deadline = DispatchTime.now() + .milliseconds(1000)
        while DispatchTime.now() < deadline {
          if let mc = Self.axChildWithIdentifier(dockElement, identifier: "mc") {
            return mc
          }
          Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
      }()

      guard let mcGroup else {
        print("switchToSpace: Mission Control AX group not found")
        return
      }

      // Wait for Mission Control's animation to complete — the AX elements
      // appear in the tree before they're fully interactive.
      Thread.sleep(forTimeInterval: 0.3)

      // Navigate: mc → mc.display (matching target display) → mc.spaces → mc.spaces.list
      guard let mcDisplay = Self.axChildMatchingDisplay(mcGroup, screenNumber: screenNumber) else {
        print("switchToSpace: mc.display not found for display \(screenNumber)")
        return
      }

      guard let mcSpaces = Self.axChildWithIdentifier(mcDisplay, identifier: "mc.spaces") else {
        print("switchToSpace: mc.spaces not found")
        return
      }

      guard let mcSpacesList = Self.axChildWithIdentifier(mcSpaces, identifier: "mc.spaces.list")
      else {
        print("switchToSpace: mc.spaces.list not found")
        return
      }

      let children = Self.axChildren(mcSpacesList)
      guard spaceIndex >= 0 && spaceIndex < children.count else {
        print(
          "switchToSpace: space index \(spaceIndex) out of range (have \(children.count) spaces)")
        return
      }

      let spaceButton = children[spaceIndex]
      AXUIElementPerformAction(spaceButton, kAXPressAction as CFString)
    }
  }

  // MARK: - Dock AX Helpers

  private static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    var childrenRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        == .success,
      let children = childrenRef as? [AXUIElement]
    else {
      return []
    }
    return children
  }

  private static func axChildWithIdentifier(
    _ element: AXUIElement, identifier: String
  ) -> AXUIElement? {
    for child in axChildren(element) {
      if axStringAttribute(child, name: "AXIdentifier") == identifier {
        return child
      }
    }
    return nil
  }

  private static func axStringAttribute(_ element: AXUIElement, name: String) -> String? {
    var valueRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &valueRef) == .success else {
      return nil
    }
    return valueRef as? String
  }

  /// Finds the `mc.display` child whose `AXDisplayID` matches the target screen number.
  private static func axChildMatchingDisplay(
    _ mcGroup: AXUIElement, screenNumber: CGDirectDisplayID
  ) -> AXUIElement? {
    for child in axChildren(mcGroup) {
      guard axStringAttribute(child, name: "AXIdentifier") == "mc.display" else { continue }
      var valueRef: CFTypeRef?
      if AXUIElementCopyAttributeValue(child, "AXDisplayID" as CFString, &valueRef) == .success,
        let displayID = valueRef as? Int,
        CGDirectDisplayID(displayID) == screenNumber
      {
        return child
      }
    }
    // Fallback: if only one mc.display exists, use it (single-display setup)
    let displays = axChildren(mcGroup).filter {
      axStringAttribute($0, name: "AXIdentifier") == "mc.display"
    }
    return displays.count == 1 ? displays.first : nil
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
    // 1. Find the window's PID from the raw window list.
    //    Unlike getAllWindows(), this doesn't filter by title — window names
    //    require Screen Recording permission, but activation only needs the PID.
    let windowList = dataSource.fetchWindowList()
    guard
      let entry = windowList.first(where: {
        ($0[kCGWindowNumber as String] as? Int) == windowID
      }),
      let rawPID = entry[kCGWindowOwnerPID as String] as? Int
    else {
      throw WindowActivationError.windowNotFound(windowID: windowID)
    }
    let ownerName = entry[kCGWindowOwnerName as String] as? String ?? "unknown"
    let windowName = entry[kCGWindowName as String] as? String

    // 2. Check AX trust (prompt opens System Settings → Accessibility on first run)
    guard Self.ensureAccessibilityTrusted() else {
      throw WindowActivationError.accessibilityNotTrusted
    }

    let pid = pid_t(rawPID)
    let targetCGWindowID = CGWindowID(windowID)

    // 3. Try the standard kAXWindowsAttribute first (fast, works for same-space windows).
    let axElement = findAXWindowStandard(pid: pid, targetCGWindowID: targetCGWindowID)

    // 4. Get PSN and activate via SkyLight (same sequence as AltTab).
    //    _SLPSSetFrontProcessWithOptions targets the specific CGWindowID and
    //    triggers macOS's space-switch animation if the window is on another Space.
    var psn = ProcessSerialNumber()
    GetProcessForPID(pid, &psn)

    _SLPSSetFrontProcessWithOptions(&psn, targetCGWindowID, 0x200)

    // 5. Send synthetic key-window events (Hammerspoon technique via AltTab).
    //    Two event records (type 0x01 key-down, 0x02 key-up) with the
    //    CGWindowID embedded at offset 0x3c in a 0xf8-byte record.
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8
    bytes[0x3a] = 0x10
    bytes.withUnsafeMutableBufferPointer { buf in
      var widCopy = targetCGWindowID
      memcpy(buf.baseAddress! + 0x3c, &widCopy, MemoryLayout<UInt32>.size)
      memset(buf.baseAddress! + 0x20, 0xff, 0x10)
    }
    bytes[0x08] = 0x01
    SLPSPostEventRecordTo(&psn, &bytes)
    bytes[0x08] = 0x02
    SLPSPostEventRecordTo(&psn, &bytes)

    // 6. Raise via AX for z-ordering within the app's window stack.
    //    If the standard lookup found the element (same-space), raise immediately.
    //    Otherwise, dispatch brute-force search to a background thread with a
    //    longer timeout — apps like Safari can have very high AX element IDs
    //    after many tabs have been opened/closed, and the search can't complete
    //    within a main-thread-safe timeout.
    if let axElement {
      AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
    } else {
      DispatchQueue.global(qos: .userInteractive).async { [self] in
        if let axElement = findAXWindowBruteForce(
          pid: pid, targetCGWindowID: targetCGWindowID)
        {
          AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
        } else {
          print(
            "activateWindow: AX element not found for window \(windowID)"
              + " (\(ownerName) — \(windowName ?? "untitled"))"
              + " — kAXRaiseAction skipped")
        }
      }
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
  /// IDs and checking each for a matching CGWindowID.
  ///
  /// The search checks `_AXUIElementGetWindow` first (fast) and only queries
  /// `kAXSubroleAttribute` when the CGWindowID matches, to verify it's the
  /// window element and not a child (buttons etc. report the same window ID).
  ///
  /// Called from a background thread with a 1-second timeout — apps like Safari
  /// can accumulate very high AX element IDs after many tabs are opened/closed.
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
    tokenData.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f_636f)) { Data($0) })

    let startTime = DispatchTime.now()
    let maxElementID: UInt64 = 1_000_000
    let timeoutNanos: UInt64 = 1_000_000_000  // 1 second

    for elementID: UInt64 in 0..<maxElementID {
      tokenData.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })

      guard
        let unmanaged = _AXUIElementCreateWithRemoteToken(tokenData as CFData),
        case let element = unmanaged.takeRetainedValue()
      else {
        continue
      }

      // Check CGWindowID first — eliminates elements not in our target window.
      var cgWid: CGWindowID = 0
      guard _AXUIElementGetWindow(element, &cgWid) == .success,
        cgWid == targetCGWindowID
      else {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        if elapsed > timeoutNanos { break }
        continue
      }

      // CGWindowID matches — verify this is a window element, not a child
      // (buttons, text fields etc. also report their containing window's ID).
      var subroleRef: CFTypeRef?
      if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        == .success,
        let subrole = subroleRef as? String,
        subrole == kAXStandardWindowSubrole as String
          || subrole == kAXDialogSubrole as String
      {
        return element
      }
    }

    return nil
  }

}
