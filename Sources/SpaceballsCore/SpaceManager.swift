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
  private let selfPID = ProcessInfo.processInfo.processIdentifier

  /// Window IDs confirmed closed via an AX liveness check while their Space was
  /// current. Kept so the verdict survives Space switches (AX can't re-check a
  /// non-current Space). Guarded by `tombstoneLock` — getAllWindows() is called
  /// from the main thread and from background restore/move threads.
  private var closedWindowTombstones = Set<Int>()
  private let tombstoneLock = NSLock()

  /// Records that a window was just closed by Spaceballs itself, so it is hidden
  /// immediately and durably — including windows on non-current Spaces, which the
  /// AX liveness check can't reach. Subject to the same self-correction as
  /// AX-derived tombstones: if the close turns out to have failed (AX lists the
  /// window alive, or it shows up on-screen), the verdict is reverted.
  public func markWindowClosed(id windowID: Int) {
    tombstoneLock.withLock { _ = closedWindowTombstones.insert(windowID) }
  }

  /// Bundle IDs of `.regular` apps the user wants hidden from Spaceballs.
  public var excludedBundleIDs: Set<String> = []

  public init(dataSource: SystemDataSource = CGSDataSource()) {
    self.dataSource = dataSource
  }

  private typealias AppInfo = (policy: NSApplication.ActivationPolicy, bundleID: String?)

  /// Returns whether a window from the given PID should be included in results.
  private func shouldIncludeWindow(
    pid: pid_t, appInfoCache: inout [pid_t: AppInfo]
  ) -> Bool {
    if pid == selfPID { return true }

    let info: AppInfo
    if let cached = appInfoCache[pid] {
      info = cached
    } else {
      let app = NSRunningApplication(processIdentifier: pid)
      info = (app?.activationPolicy ?? .regular, app?.bundleIdentifier)
      appInfoCache[pid] = info
    }

    switch info.policy {
    case .regular:
      if let bid = info.bundleID, excludedBundleIDs.contains(bid) { return false }
      return true
    case .accessory, .prohibited:
      return false
    @unknown default:
      return false
    }
  }

  /// Returns the space IDs the given window belongs to (empty when CGS has no
  /// record of the window). Sticky windows report every space they appear on.
  public func spaceIDs(forWindowID windowID: Int) -> [UInt64] {
    dataSource.fetchSpacesForWindow(windowID)
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
    var appInfoCache: [pid_t: AppInfo] = [:]

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

      // Filter by activation policy, included/excluded bundle IDs, and self-PID.
      let pidT = pid_t(pid)
      guard shouldIncludeWindow(pid: pidT, appInfoCache: &appInfoCache) else { continue }

      let name = entry[kCGWindowName as String] as? String

      // Skip windows where the name key is entirely absent (auxiliary chrome).
      if name == nil { continue }

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

    // Some apps (e.g. Contacts) report empty kCGWindowName for their main
    // window. Keep those so the app still appears. But apps like Safari also
    // have auxiliary empty-name windows (toolbar containers, etc.) alongside
    // real titled windows. Remove empty-name windows from any app that also
    // has at least one titled window.
    var pidsWithTitledWindows = Set<Int>()
    for window in windows where window.name != nil && !window.name!.isEmpty {
      pidsWithTitledWindows.insert(window.pid)
    }
    windows.removeAll { window in
      (window.name == nil || window.name!.isEmpty) && pidsWithTitledWindows.contains(window.pid)
    }

    // Drop windows that were closed in a still-running app. macOS keeps such
    // windows in CGWindowListCopyWindowInfo(.optionAll) — ordered out, still mapped
    // to a Space — until the process exits, so without this they linger in the list.
    return removeClosedWindows(windows)
  }

  /// Removes windows that have been closed but still linger in the window-server
  /// list. A closed window is indistinguishable from a minimized one in
  /// `CGWindowListCopyWindowInfo` (both are off-screen on their Space with identical
  /// fields), so liveness is resolved via the Accessibility API, which lists
  /// minimized (live) windows but not closed ones.
  ///
  /// The AX window list only covers the *current* Space, so fresh verdicts are only
  /// possible for current-space, off-screen windows: on-screen windows are live by
  /// definition, and windows on other Spaces can't be interrogated. To keep a ghost
  /// hidden after its Space stops being current, confirmed-dead window IDs are
  /// remembered in `closedWindowTombstones` — a dead CGWindowID stays dead, so the
  /// verdict is applied on every later call regardless of which Space is current.
  /// Tombstones self-correct (removed if AX ever lists the ID alive again) and are
  /// pruned once the ID leaves the window list, so a later ID reuse can't be hidden.
  private func removeClosedWindows(_ windows: [WindowInfo]) -> [WindowInfo] {
    var tombstones = tombstoneLock.withLock { closedWindowTombstones }

    // Prune tombstones for IDs no longer in the window list (app quit purged them).
    tombstones.formIntersection(windows.map(\.id))

    let currentSpaceIDs = Set(getAllSpaces().filter(\.isCurrent).map(\.id))

    // Cache the AX query per pid; an app may have several windows to validate.
    var liveIDsByPID: [pid_t: Set<CGWindowID>?] = [:]
    let result = windows.filter { window in
      // On-screen ⟹ on an active Space and visible ⟹ definitely a live window.
      if window.isOnscreen {
        tombstones.remove(window.id)
        return true
      }
      // Off-screen but not on a current Space ⟹ AX can't vouch either way.
      // Keep unless a past current-space check already proved it dead.
      guard window.spaceIDs.contains(where: { currentSpaceIDs.contains($0) }) else {
        return !tombstones.contains(window.id)
      }

      // Off-screen on a current Space ⟹ minimized or closed. Ask AX which.
      let pid = pid_t(window.pid)
      let liveIDs: Set<CGWindowID>?
      if let cached = liveIDsByPID[pid] {
        liveIDs = cached
      } else {
        liveIDs = dataSource.liveAXWindowIDs(pid: pid)
        liveIDsByPID[pid] = liveIDs
      }
      guard let liveIDs else {  // AX unavailable ⟹ no fresh verdict; use memory.
        return !tombstones.contains(window.id)
      }
      if liveIDs.contains(CGWindowID(window.id)) {
        tombstones.remove(window.id)  // alive — clear any stale verdict
        return true
      }
      tombstones.insert(window.id)  // confirmed dead — remember across Space switches
      return false
    }

    tombstoneLock.withLock { closedWindowTombstones = tombstones }
    return result
  }

  /// Returns the CGWindowID of the frontmost normal window on the given space,
  /// using the on-screen window list which guarantees front-to-back Z-order.
  /// Returns `nil` if no qualifying window is found.
  public func frontmostWindowID(onSpace spaceID: UInt64) -> Int? {
    let onScreen = dataSource.fetchOnScreenWindowList()
    var appInfoCache: [pid_t: AppInfo] = [:]

    for entry in onScreen {
      guard let windowID = entry[kCGWindowNumber as String] as? Int,
        let pid = entry[kCGWindowOwnerPID as String] as? Int,
        let layer = entry[kCGWindowLayer as String] as? Int,
        layer == 0
      else { continue }

      // Skip windows with no name key (auxiliary chrome), but allow empty
      // names (e.g. Contacts) so the frontmost window is detected correctly.
      let name = entry[kCGWindowName as String] as? String
      if name == nil { continue }

      let pidT = pid_t(pid)
      guard shouldIncludeWindow(pid: pidT, appInfoCache: &appInfoCache) else { continue }

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

  // MARK: - High-Level Space Operations

  /// Creates missing spaces from a list of default names, pruning stale
  /// name mappings first. Returns the number of spaces created.
  public func createDefaultSpaces(
    defaultNames: [String], spaceNameStore: SpaceNameStoring,
    completion: @escaping (Int) -> Void
  ) {
    spaceNameStore.pruneStaleNames(currentSpaces: getAllSpaces())

    let existingNames = Set(spaceNameStore.allCustomNames().values)
    let missingNames = defaultNames.filter { !existingNames.contains($0) }

    guard !missingNames.isEmpty else {
      completion(0)
      return
    }

    createSpace(count: missingNames.count) { [weak self] result in
      guard let self else {
        completion(0)
        return
      }
      let created: Int
      switch result {
      case .success(let n): created = n
      case .failure:
        completion(0)
        return
      }

      // Wait for macOS to settle, then assign names to new unnamed spaces
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        let allSpaces = self.getAllSpaces().filter { $0.type == .desktop }
        let alreadyNamed = Set(spaceNameStore.allCustomNames().keys)
        let unnamedSpaces = allSpaces.filter { !alreadyNamed.contains($0.uuid) }

        for (name, space) in zip(missingNames, unnamedSpaces.suffix(created)) {
          spaceNameStore.setCustomName(name, forSpaceUUID: space.uuid)
        }

        completion(created)
      }
    }
  }

  /// Synchronous version for CLI usage.
  public func createDefaultSpacesSync(
    defaultNames: [String], spaceNameStore: SpaceNameStoring
  ) throws -> Int {
    guard Self.ensureAccessibilityTrusted() else {
      throw SpaceCreateError.accessibilityNotTrusted
    }

    spaceNameStore.pruneStaleNames(currentSpaces: getAllSpaces())

    let existingNames = Set(spaceNameStore.allCustomNames().values)
    let missingNames = defaultNames.filter { !existingNames.contains($0) }
    guard !missingNames.isEmpty else { return 0 }

    try createSpaceSync(count: missingNames.count)
    Thread.sleep(forTimeInterval: 1.0)

    let allSpaces = getAllSpaces().filter { $0.type == .desktop }
    let alreadyNamed = Set(spaceNameStore.allCustomNames().keys)
    let unnamedSpaces = allSpaces.filter { !alreadyNamed.contains($0.uuid) }

    for (name, space) in zip(missingNames, unnamedSpaces.suffix(missingNames.count)) {
      spaceNameStore.setCustomName(name, forSpaceUUID: space.uuid)
    }

    return missingNames.count
  }

  /// Creates a single space and assigns a name to it.
  public func createNamedSpaceSync(name: String, spaceNameStore: SpaceNameStoring) throws {
    try createSpaceSync(count: 1)
    Thread.sleep(forTimeInterval: 1.0)

    let allSpaces = getAllSpaces().filter { $0.type == .desktop }
    let alreadyNamed = Set(spaceNameStore.allCustomNames().keys)
    let unnamedSpaces = allSpaces.filter { !alreadyNamed.contains($0.uuid) }

    if let newSpace = unnamedSpaces.last {
      spaceNameStore.setCustomName(name, forSpaceUUID: newSpace.uuid)
    }
  }

  /// Closes a space by ID and removes its name mapping.
  public func closeSpaceAndRemoveName(
    id spaceID: UInt64, spaceNameStore: SpaceNameStoring,
    completion: @escaping (Result<Void, SpaceCloseError>) -> Void
  ) {
    let spaceUUID = getAllSpaces().first(where: { $0.id == spaceID })?.uuid

    closeSpace(id: spaceID) { result in
      if case .success = result, let uuid = spaceUUID {
        spaceNameStore.setCustomName(nil, forSpaceUUID: uuid)
      }
      completion(result)
    }
  }

  /// Synchronous version for CLI usage.
  public func closeSpaceAndRemoveNameSync(
    id spaceID: UInt64, spaceNameStore: SpaceNameStoring
  ) throws {
    let spaceUUID = getAllSpaces().first(where: { $0.id == spaceID })?.uuid
    try closeSpaceSync(id: spaceID)
    if let uuid = spaceUUID {
      spaceNameStore.setCustomName(nil, forSpaceUUID: uuid)
    }
  }

  // MARK: - Space Creation

  /// Creates a new desktop Space on the focused display via the Dock's
  /// accessibility interface. Opens Mission Control, finds the "Add Desktop"
  /// button in the Spaces Bar, and clicks it.
  ///
  /// - Parameter count: Number of spaces to create (default 1).
  /// - Parameter completion: Called on the main queue when done, with success/failure.
  public func createSpace(
    count: Int = 1, screenNumber: CGDirectDisplayID? = nil,
    completion: ((Result<Int, SpaceCreateError>) -> Void)? = nil
  ) {
    guard AXIsProcessTrusted() else {
      completion?(.failure(.accessibilityNotTrusted))
      return
    }

    guard
      let dockApp = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.dock"
      ).first
    else {
      completion?(.failure(.dockNotRunning))
      return
    }

    let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)

    CoreDockSendNotification("com.apple.expose.awake" as CFString)

    DispatchQueue.global(qos: .userInteractive).async {
      // Poll for Mission Control AX group
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
        completion?(.failure(.missionControlNotFound))
        return
      }

      Thread.sleep(forTimeInterval: 0.3)

      // Find the add button in the Spaces Bar on the target display.
      let addButton: AXUIElement? = {
        // If a specific display is requested, find its mc.display first
        let displayElements: [AXUIElement]
        if let screenNumber,
          let targetDisplay = Self.axChildMatchingDisplay(mcGroup, screenNumber: screenNumber)
        {
          displayElements = [targetDisplay]
        } else {
          displayElements = Self.axChildren(mcGroup).filter {
            Self.axStringAttribute($0, name: "AXIdentifier") == "mc.display"
          }
        }

        for displayChild in displayElements {
          if let mcSpaces = Self.axChildWithIdentifier(displayChild, identifier: "mc.spaces") {
            if let add = Self.axChildWithIdentifier(mcSpaces, identifier: "mc.spaces.add") {
              return add
            }
            if let add = Self.findAddButton(in: mcSpaces) {
              return add
            }
          }
        }
        return nil
      }()

      guard let addButton else {
        // Dismiss Mission Control before reporting error
        Self.dismissMissionControl()
        completion?(.failure(.addButtonNotFound))
        return
      }

      var created = 0
      for i in 0..<count {
        let result = AXUIElementPerformAction(addButton, kAXPressAction as CFString)
        guard result == .success else { break }
        created += 1
        if i < count - 1 {
          Thread.sleep(forTimeInterval: 0.5)
        }
      }

      Thread.sleep(forTimeInterval: 0.3)
      Self.dismissMissionControl()

      completion?(.success(created))
    }
  }

  /// Synchronous version for CLI usage.
  public func createSpaceSync(count: Int = 1) throws {
    guard Self.ensureAccessibilityTrusted() else {
      throw SpaceCreateError.accessibilityNotTrusted
    }

    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<Int, SpaceCreateError>?

    createSpace(count: count) { r in
      result = r
      semaphore.signal()
    }

    semaphore.wait()

    switch result {
    case .success(let created):
      if created < count {
        print("Warning: only created \(created) of \(count) requested spaces")
      }
    case .failure(let error):
      throw error
    case nil:
      throw SpaceCreateError.missionControlNotFound
    }
  }

  private static func dismissMissionControl() {
    CoreDockSendNotification("com.apple.expose.awake" as CFString)
  }

  /// Searches for a button whose name or description contains "add" (case-insensitive).
  private static func findAddButton(in element: AXUIElement) -> AXUIElement? {
    for child in axChildren(element) {
      var roleRef: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
        let role = roleRef as? String
      else { continue }

      if role == "AXButton" {
        let name = axStringAttribute(child, name: "AXTitle") ?? ""
        let desc = axStringAttribute(child, name: "AXDescription") ?? ""
        if name.localizedCaseInsensitiveContains("add")
          || desc.localizedCaseInsensitiveContains("add")
        {
          return child
        }
      }

      // Recurse into groups
      if let found = findAddButton(in: child) {
        return found
      }
    }
    return nil
  }

  // MARK: - Space Closing

  /// Closes a Space by its index on the given display via the Dock's
  /// accessibility interface. Opens Mission Control, moves the mouse into
  /// the spaces bar to trigger the expanded view, holds Option to reveal
  /// close buttons, then clicks the target space's close button.
  public func closeSpace(
    spaceIndex: Int, screenNumber: CGDirectDisplayID,
    completion: ((Result<Void, SpaceCloseError>) -> Void)? = nil
  ) {
    guard AXIsProcessTrusted() else {
      completion?(.failure(.accessibilityNotTrusted))
      return
    }

    guard
      let dockApp = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.dock"
      ).first
    else {
      completion?(.failure(.dockNotRunning))
      return
    }

    let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)

    CoreDockSendNotification("com.apple.expose.awake" as CFString)

    DispatchQueue.global(qos: .userInteractive).async {
      // Poll for Mission Control
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
        completion?(.failure(.missionControlNotFound))
        return
      }

      Thread.sleep(forTimeInterval: 0.3)

      // Navigate to the spaces list
      guard let mcDisplay = Self.axChildMatchingDisplay(mcGroup, screenNumber: screenNumber) else {
        Self.dismissMissionControl()
        completion?(.failure(.spaceNotFound))
        return
      }

      guard let mcSpaces = Self.axChildWithIdentifier(mcDisplay, identifier: "mc.spaces"),
        let mcSpacesList = Self.axChildWithIdentifier(mcSpaces, identifier: "mc.spaces.list")
      else {
        Self.dismissMissionControl()
        completion?(.failure(.spaceNotFound))
        return
      }

      let children = Self.axChildren(mcSpacesList)
      guard spaceIndex >= 0 && spaceIndex < children.count else {
        Self.dismissMissionControl()
        completion?(.failure(.spaceNotFound))
        return
      }

      let spaceButton = children[spaceIndex]
      let result = AXUIElementPerformAction(spaceButton, "AXRemoveDesktop" as CFString)

      guard result == .success else {
        Self.dismissMissionControl()
        completion?(.failure(.removeActionFailed))
        return
      }

      // Wait for macOS to finish the space removal animation before dismissing MC
      Thread.sleep(forTimeInterval: 0.8)
      Self.dismissMissionControl()

      completion?(.success(()))
    }
  }

  /// Closes a Space by its ManagedSpaceID.
  public func closeSpace(
    id spaceID: UInt64,
    completion: ((Result<Void, SpaceCloseError>) -> Void)? = nil
  ) {
    let allSpaces = getAllSpaces()

    let desktopSpaces = allSpaces.filter { $0.type == .desktop }
    guard desktopSpaces.count > 1 else {
      completion?(.failure(.cannotCloseLastSpace))
      return
    }

    guard let targetSpace = allSpaces.first(where: { $0.id == spaceID }) else {
      completion?(.failure(.spaceNotFound))
      return
    }

    let displaySpaces =
      allSpaces
      .filter { $0.displayUUID == targetSpace.displayUUID && $0.type == .desktop }

    guard let spaceIndex = displaySpaces.firstIndex(where: { $0.id == spaceID }) else {
      completion?(.failure(.spaceNotFound))
      return
    }

    guard let screenNumber = Self.displayIDForUUID(targetSpace.displayUUID) else {
      completion?(.failure(.spaceNotFound))
      return
    }

    closeSpace(spaceIndex: spaceIndex, screenNumber: screenNumber, completion: completion)
  }

  /// Synchronous version for CLI usage.
  public func closeSpaceSync(id spaceID: UInt64) throws {
    guard Self.ensureAccessibilityTrusted() else {
      throw SpaceCloseError.accessibilityNotTrusted
    }

    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<Void, SpaceCloseError>?

    closeSpace(id: spaceID) { r in
      result = r
      semaphore.signal()
    }

    semaphore.wait()

    if case .failure(let error) = result {
      throw error
    }
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
    let activateStart = Date()
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
      Diagnostics.log(
        "activate", "windowID=\(windowID) result=window-not-found")
      throw WindowActivationError.windowNotFound(windowID: windowID)
    }
    let ownerName = entry[kCGWindowOwnerName as String] as? String ?? "unknown"
    let windowName = entry[kCGWindowName as String] as? String
    let activationContext =
      Diagnostics.enabled
      ? " \(activationContextForDiagnostics(windowID: windowID))" : ""

    // 2. Check AX trust (prompt opens System Settings → Accessibility on first run)
    guard Self.ensureAccessibilityTrusted() else {
      Diagnostics.log("activate", "windowID=\(windowID) result=ax-not-trusted")
      throw WindowActivationError.accessibilityNotTrusted
    }

    let pid = pid_t(rawPID)
    let targetCGWindowID = CGWindowID(windowID)
    let spaceWakeFallbackTarget = spaceWakeFallbackTargetForActivation(windowID: windowID)

    Diagnostics.log(
      "activate",
      "windowID=\(windowID) owner=\"\(ownerName)\" title=\(Diagnostics.titleForLogging(windowName)) pid=\(pid) starting\(activationContext)",
      app: ownerName)

    // Self-owned windows (e.g. the Settings window) — bring to front via AppKit
    // directly. The SkyLight/AX activation flow crashes on the process's own windows.
    if pid == ProcessInfo.processInfo.processIdentifier {
      DispatchQueue.main.async {
        for window in NSApp.windows where CGWindowID(window.windowNumber) == targetCGWindowID {
          window.makeKeyAndOrderFront(nil)
          NSApp.activate(ignoringOtherApps: true)
          break
        }
        Diagnostics.log(
          "activate",
          "windowID=\(windowID) path=self duration=\(Int(Date().timeIntervalSince(activateStart) * 1000))ms",
          app: ownerName)
      }
      return
    }

    // 3. Try the standard kAXWindowsAttribute first (fast, works for same-space windows).
    let axElement = findAXWindowStandard(pid: pid, targetCGWindowID: targetCGWindowID)

    // 4. Get PSN and activate via SkyLight (same sequence as AltTab).
    //    _SLPSSetFrontProcessWithOptions targets the specific CGWindowID and
    //    triggers macOS's space-switch animation if the window is on another Space.
    postSkyLightActivation(
      pid: pid,
      targetCGWindowID: targetCGWindowID,
      windowID: windowID,
      ownerName: ownerName,
      phase: "initial",
      scheduleSpaceCheck: spaceWakeFallbackTarget == nil)

    // 5. Raise via AX for z-ordering within the app's window stack.
    //    If the standard lookup found the element (same-space), raise immediately.
    //    Otherwise, dispatch brute-force search to a background thread with a
    //    longer timeout — apps like Safari can have very high AX element IDs
    //    after many tabs have been opened/closed, and the search can't complete
    //    within a main-thread-safe timeout.
    if let axElement {
      AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
      Diagnostics.log(
        "activate",
        "windowID=\(windowID) path=standard duration=\(Int(Date().timeIntervalSince(activateStart) * 1000))ms",
        app: ownerName)
    } else {
      DispatchQueue.global(qos: .userInteractive).async { [self] in
        if let spaceWakeFallbackTarget {
          // For normal off-Space windows, the brute-force AX lookup often succeeds
          // quickly and AXRaise helps complete the cross-Space activation. Restored
          // windows can be different: CGS reports a valid Space mapping, but AX has
          // no element for the window until that Space is visited. Probe briefly so
          // ordinary switches stay fast, then wake the Space if the probe sees nothing.
          let probeStart = Date()
          let probeResult = findAXWindowBruteForceResult(
            pid: pid, targetCGWindowID: targetCGWindowID, timeout: 0.25)
          if let axElement = probeResult.element {
            AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
            Diagnostics.log(
              "activate",
              "windowID=\(windowID) path=brute-force-probe duration=\(Int(Date().timeIntervalSince(probeStart) * 1000))ms total=\(Int(Date().timeIntervalSince(activateStart) * 1000))ms \(probeResult.diagnosticsSummary)",
              app: ownerName)
            return
          }

          Diagnostics.log(
            "activate",
            "windowID=\(windowID) path=brute-force-probe outcome=not-found duration=\(Int(Date().timeIntervalSince(probeStart) * 1000))ms \(probeResult.diagnosticsSummary)",
            app: ownerName)

          let waitStart = Date()
          let switched = waitForCurrentSpace(spaceWakeFallbackTarget.id, timeout: 0.4)
          Diagnostics.log(
            "activate",
            "windowID=\(windowID) skylight-target-space-wait targetSpaceID=\(spaceWakeFallbackTarget.id) success=\(switched) duration=\(Int(Date().timeIntervalSince(waitStart) * 1000))ms",
            app: ownerName)

          if let axElement = findAXWindowStandard(pid: pid, targetCGWindowID: targetCGWindowID) {
            AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
            Diagnostics.log(
              "activate",
              "windowID=\(windowID) path=standard-after-skylight-wait total=\(Int(Date().timeIntervalSince(activateStart) * 1000))ms",
              app: ownerName)
            return
          }

          if !switched {
            Diagnostics.log(
              "activate",
              "windowID=\(windowID) path=brute-force skipped=space-wake-needed fallback=space-wake targetSpaceID=\(spaceWakeFallbackTarget.id)",
              app: ownerName)
            activateAfterSpaceWakeFallback(
              windowID: windowID,
              ownerName: ownerName,
              pid: pid,
              targetCGWindowID: targetCGWindowID,
              targetSpace: spaceWakeFallbackTarget,
              activateStart: activateStart)
            return
          }
        }

        let bruteStart = Date()
        let bruteResult = findAXWindowBruteForceResult(
          pid: pid, targetCGWindowID: targetCGWindowID)
        if let axElement = bruteResult.element {
          AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
          Diagnostics.log(
            "activate",
            "windowID=\(windowID) path=brute-force brute-duration=\(Int(Date().timeIntervalSince(bruteStart) * 1000))ms total=\(Int(Date().timeIntervalSince(activateStart) * 1000))ms \(bruteResult.diagnosticsSummary)",
            app: ownerName)
        } else {
          let fallbackMessage =
            spaceWakeFallbackTarget.map { " fallback=space-wake targetSpaceID=\($0.id)" }
            ?? ""
          Diagnostics.log(
            "activate",
            "windowID=\(windowID) path=brute-force outcome=not-found total=\(Int(Date().timeIntervalSince(activateStart) * 1000))ms \(bruteResult.diagnosticsSummary)\(fallbackMessage) (kAXRaiseAction skipped)",
            app: ownerName)
          if let spaceWakeFallbackTarget,
            !getAllSpaces().contains(where: { $0.id == spaceWakeFallbackTarget.id && $0.isCurrent })
          {
            activateAfterSpaceWakeFallback(
              windowID: windowID,
              ownerName: ownerName,
              pid: pid,
              targetCGWindowID: targetCGWindowID,
              targetSpace: spaceWakeFallbackTarget,
              activateStart: activateStart)
          }
        }
      }
    }
  }

  @discardableResult
  private func postSkyLightActivation(
    pid: pid_t,
    targetCGWindowID: CGWindowID,
    windowID: Int,
    ownerName: String,
    phase: String,
    scheduleSpaceCheck: Bool = true
  ) -> String {
    var psn = ProcessSerialNumber()
    GetProcessForPID(pid, &psn)

    let beforeCurrentSpaces = Diagnostics.enabled ? currentSpacesForActivationDiagnostics() : "[]"
    let skylightStart = Date()
    _SLPSSetFrontProcessWithOptions(&psn, targetCGWindowID, 0x200)
    if Diagnostics.enabled {
      Diagnostics.log(
        "activate",
        "windowID=\(windowID) skylight=set-front-process phase=\(phase) called duration=\(Int(Date().timeIntervalSince(skylightStart) * 1000))ms beforeCurrentSpaces=\(beforeCurrentSpaces)",
        app: ownerName)
      if scheduleSpaceCheck {
        logSpaceChangeAfterSkyLight(
          windowID: windowID,
          ownerName: ownerName,
          beforeCurrentSpaces: beforeCurrentSpaces,
          phase: phase)
      }
    }

    // Synthetic key-window events: two records (key-down/key-up) with the
    // CGWindowID embedded at offset 0x3c in a 0xf8-byte record.
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

    return beforeCurrentSpaces
  }

  private func activateAfterSpaceWakeFallback(
    windowID: Int,
    ownerName: String,
    pid: pid_t,
    targetCGWindowID: CGWindowID,
    targetSpace: SpaceInfo,
    activateStart: Date
  ) {
    let fallbackStart = Date()
    let beforeCurrentSpaces = currentSpacesForActivationDiagnostics()
    Diagnostics.log(
      "activate",
      "windowID=\(windowID) fallback=space-wake starting targetSpaceID=\(targetSpace.id) beforeCurrentSpaces=\(beforeCurrentSpaces)",
      app: ownerName)

    do {
      try switchToSpace(id: targetSpace.id)
    } catch {
      Diagnostics.log(
        "activate",
        "windowID=\(windowID) fallback=space-wake outcome=switch-error error=\"\(error.localizedDescription)\"",
        app: ownerName)
      return
    }

    let switched = waitForCurrentSpace(targetSpace.id, timeout: 2.5)
    let afterCurrentSpaces = currentSpacesForActivationDiagnostics()
    Diagnostics.log(
      "activate",
      "windowID=\(windowID) fallback=space-wake switch-complete success=\(switched) duration=\(Int(Date().timeIntervalSince(fallbackStart) * 1000))ms afterCurrentSpaces=\(afterCurrentSpaces)",
      app: ownerName)

    guard switched else {
      Diagnostics.log(
        "activate",
        "windowID=\(windowID) fallback=space-wake outcome=space-switch-timeout total=\(Int(Date().timeIntervalSince(activateStart) * 1000))ms",
        app: ownerName)
      return
    }

    Thread.sleep(forTimeInterval: 0.15)
    postSkyLightActivation(
      pid: pid,
      targetCGWindowID: targetCGWindowID,
      windowID: windowID,
      ownerName: ownerName,
      phase: "space-wake-retry")
    Thread.sleep(forTimeInterval: 0.15)

    if let axElement = findAXWindowStandard(pid: pid, targetCGWindowID: targetCGWindowID) {
      AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
      Diagnostics.log(
        "activate",
        "windowID=\(windowID) fallback=space-wake path=standard total=\(Int(Date().timeIntervalSince(activateStart) * 1000))ms",
        app: ownerName)
      return
    }

    let bruteStart = Date()
    let bruteResult = findAXWindowBruteForceResult(pid: pid, targetCGWindowID: targetCGWindowID)
    if let axElement = bruteResult.element {
      AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
      Diagnostics.log(
        "activate",
        "windowID=\(windowID) fallback=space-wake path=brute-force brute-duration=\(Int(Date().timeIntervalSince(bruteStart) * 1000))ms total=\(Int(Date().timeIntervalSince(activateStart) * 1000))ms \(bruteResult.diagnosticsSummary)",
        app: ownerName)
    } else {
      Diagnostics.log(
        "activate",
        "windowID=\(windowID) fallback=space-wake outcome=retry-not-found total=\(Int(Date().timeIntervalSince(activateStart) * 1000))ms \(bruteResult.diagnosticsSummary)",
        app: ownerName)
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
      if result == .success {
        // The close was delivered — tombstone the ID so the window is hidden
        // durably even if it lives on a non-current Space (where the window
        // server will keep listing it and AX can't be consulted).
        markWindowClosed(id: windowID)
      } else {
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

  // MARK: - Mission Control Context

  /// Resolved AX elements for an open Mission Control session on a single display.
  struct MissionControlContext {
    let mcGroup: AXUIElement
    let mcDisplay: AXUIElement
    let mcWindows: AXUIElement
    let mcSpaces: AXUIElement
    let mcSpacesList: AXUIElement

    /// All window thumbnail buttons currently shown in Mission Control.
    var windowButtons: [AXUIElement] { SpaceManager.axChildren(mcWindows) }

    /// All space buttons in the spaces bar.
    var spaceButtons: [AXUIElement] { SpaceManager.axChildren(mcSpacesList) }

    /// Finds a window thumbnail by title. Prefers exact match, falls back to
    /// case-insensitive substring. Returns `nil` if no match or multiple substring matches.
    func findWindowButton(titled title: String) -> AXUIElement? {
      // Prefer exact match
      if let exact = windowButtons.first(where: {
        SpaceManager.axStringAttribute($0, name: "AXTitle") == title
      }) {
        return exact
      }
      // Fall back to substring match, but only if unambiguous
      let matches = windowButtons.filter {
        (SpaceManager.axStringAttribute($0, name: "AXTitle") ?? "")
          .localizedCaseInsensitiveContains(title)
      }
      return matches.count == 1 ? matches.first : nil
    }

    /// Returns all window thumbnails whose title contains the given substring.
    func findWindowButtons(titleContaining substring: String) -> [AXUIElement] {
      windowButtons.filter {
        (SpaceManager.axStringAttribute($0, name: "AXTitle") ?? "")
          .localizedCaseInsensitiveContains(substring)
      }
    }

    /// Finds a space button by exact title match.
    func findSpaceButton(titled title: String) -> AXUIElement? {
      spaceButtons.first {
        SpaceManager.axStringAttribute($0, name: "AXTitle") == title
      }
    }
  }

  /// Opens Mission Control via Dock's CoreDock API, polls for the AX hierarchy,
  /// and returns a context with resolved element references.
  ///
  /// Must be called from a background thread (blocks while polling).
  /// Caller is responsible for calling `dismissMissionControl()` when done.
  static func openMissionControlContext(
    screenNumber: CGDirectDisplayID? = nil
  ) -> MissionControlContext? {
    guard
      let dockApp = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.dock"
      ).first
    else {
      print("openMissionControlContext: Dock not running")
      return nil
    }

    let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)

    CoreDockSendNotification("com.apple.expose.awake" as CFString)

    // Poll for the Mission Control AX group
    let mcGroup: AXUIElement? = {
      let deadline = DispatchTime.now() + .milliseconds(2000)
      while DispatchTime.now() < deadline {
        if let mc = axChildWithIdentifier(dockElement, identifier: "mc") { return mc }
        Thread.sleep(forTimeInterval: 0.01)
      }
      return nil
    }()

    guard let mcGroup else {
      print("openMissionControlContext: Mission Control AX group not found")
      return nil
    }

    // Wait for MC animation and AX tree to fully populate
    Thread.sleep(forTimeInterval: 0.5)

    // Find mc.display (match by screen number if provided, or use first/only)
    let mcDisplay: AXUIElement?
    if let screenNumber {
      mcDisplay = axChildMatchingDisplay(mcGroup, screenNumber: screenNumber)
    } else {
      mcDisplay = axChildren(mcGroup).first {
        axStringAttribute($0, name: "AXIdentifier") == "mc.display"
      }
    }

    guard let mcDisplay else {
      print("openMissionControlContext: mc.display not found")
      return nil
    }

    guard let mcWindows = axChildWithIdentifier(mcDisplay, identifier: "mc.windows"),
      let mcSpaces = axChildWithIdentifier(mcDisplay, identifier: "mc.spaces"),
      let mcSpacesList = axChildWithIdentifier(mcSpaces, identifier: "mc.spaces.list")
    else {
      print("openMissionControlContext: mc.windows/mc.spaces/mc.spaces.list not found")
      return nil
    }

    return MissionControlContext(
      mcGroup: mcGroup, mcDisplay: mcDisplay,
      mcWindows: mcWindows, mcSpaces: mcSpaces, mcSpacesList: mcSpacesList)
  }

  // MARK: - Display Focus

  /// Clicks on the desktop of the display containing the given space to
  /// transfer keyboard focus to that display. This ensures Launch Services
  /// opens new apps on the correct display.
  public func clickDesktopOnDisplay(forSpaceID spaceID: UInt64) {
    let allSpaces = getAllSpaces()
    guard let space = allSpaces.first(where: { $0.id == spaceID }),
      let screenNumber = Self.displayIDForUUID(space.displayUUID)
    else { return }

    // Find the NSScreen matching this display
    guard
      let screen = NSScreen.screens.first(where: {
        let desc = $0.deviceDescription
        return (desc[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
          == screenNumber
      })
    else { return }

    // Convert screen center to CGEvent coordinates (top-left origin)
    let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
    let center = CGPoint(
      x: screen.frame.midX,
      y: primaryHeight - screen.frame.midY
    )

    SpaceManager.postMouseClick(at: center)
  }

  /// Posts a click (mouseDown + mouseUp) at the given point.
  static func postMouseClick(at point: CGPoint) {
    if let down = CGEvent(
      mouseEventSource: nil, mouseType: .leftMouseDown,
      mouseCursorPosition: point, mouseButton: .left)
    {
      down.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: 0.05)
    if let up = CGEvent(
      mouseEventSource: nil, mouseType: .leftMouseUp,
      mouseCursorPosition: point, mouseButton: .left)
    {
      up.post(tap: .cghidEventTap)
    }
  }

  // MARK: - AX Position/Size Helpers

  static func axPosition(_ element: AXUIElement) -> CGPoint? {
    var ref: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref) == .success,
      let value = ref
    else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
    return point
  }

  static func axSize(_ element: AXUIElement) -> CGSize? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref) == .success,
      let value = ref
    else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
    return size
  }

  /// Returns the center point of an AX element's frame.
  static func axCenter(_ element: AXUIElement) -> CGPoint? {
    guard let pos = axPosition(element), let size = axSize(element) else { return nil }
    return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
  }

  // MARK: - CGEvent Mouse Simulation

  /// Moves the cursor to a point, pauses, then presses mouseDown to grab.
  static func postMouseMoveAndGrab(at point: CGPoint) {
    if let move = CGEvent(
      mouseEventSource: nil, mouseType: .mouseMoved,
      mouseCursorPosition: point, mouseButton: .left)
    {
      move.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: 0.05)

    if let down = CGEvent(
      mouseEventSource: nil, mouseType: .leftMouseDown,
      mouseCursorPosition: point, mouseButton: .left)
    {
      down.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: 0.1)
  }

  /// Posts a single mouseDragged event (mouse must already be down).
  static func postMouseDragEvent(at point: CGPoint) {
    if let drag = CGEvent(
      mouseEventSource: nil, mouseType: .leftMouseDragged,
      mouseCursorPosition: point, mouseButton: .left)
    {
      drag.post(tap: .cghidEventTap)
    }
  }

  /// Posts mouseDragged events in steps from one point to another (mouse must already be down).
  static func postMouseDragToPoint(from: CGPoint, to: CGPoint, steps: Int = 15) {
    for i in 1...steps {
      let t = CGFloat(i) / CGFloat(steps)
      let point = CGPoint(
        x: from.x + (to.x - from.x) * t,
        y: from.y + (to.y - from.y) * t
      )
      postMouseDragEvent(at: point)
      Thread.sleep(forTimeInterval: 0.008)
    }
  }

  /// Drives a homing drag: steps the cursor toward the latest target reading,
  /// re-reading every `readEvery` steps, so the path bends as the target moves.
  ///
  /// Used for the Mission Control move drag — the target tile's final position
  /// doesn't exist until the drag reaches the spaces bar (arrival triggers
  /// expansion + placeholder insertion, shifting every tile), so a fixed-endpoint
  /// drag either aims at a stale coordinate or needs a visible dog-leg through a
  /// neutral waypoint. Homing yields one continuous, straight-then-bending path.
  ///
  /// Returns the arrival point (the last aim reached), the current position if
  /// `maxSteps` runs out before catching the target, or `nil` (without moving)
  /// if the target was never readable. A failed re-read keeps the last known aim.
  static func homingDrag(
    from start: CGPoint, stepLength: CGFloat = 40, readEvery: Int = 3, maxSteps: Int = 200,
    read: () -> CGPoint?, move: (CGPoint) -> Void
  ) -> CGPoint? {
    guard var aim = read() else { return nil }
    var current = start
    var stepsSinceRead = 0
    for _ in 0..<maxSteps {
      if stepsSinceRead >= readEvery {
        if let latest = read() { aim = latest }
        stepsSinceRead = 0
      }
      let dx = aim.x - current.x
      let dy = aim.y - current.y
      let distance = (dx * dx + dy * dy).squareRoot()
      if distance <= stepLength {
        current = aim
        move(current)
        return current
      }
      current = CGPoint(
        x: current.x + dx / distance * stepLength,
        y: current.y + dy / distance * stepLength
      )
      move(current)
      stepsSinceRead += 1
    }
    return current
  }

  /// Polls `read` until two consecutive readings agree within `tolerance` points,
  /// calling `delay` between attempts. Used to wait for Mission Control's
  /// spaces-bar animation to settle instead of sleeping a fixed worst case —
  /// typically ~3× faster, and the returned coordinate is guaranteed
  /// post-animation.
  ///
  /// Returns the settled point, or the last successful read flagged unstable if
  /// `maxAttempts` runs out, or `nil` if every read failed. A `nil` read (element
  /// missing mid-relayout) breaks the consecutive-agreement streak.
  static func awaitStablePoint(
    tolerance: CGFloat = 2, maxAttempts: Int = 15,
    read: () -> CGPoint?, delay: () -> Void
  ) -> (point: CGPoint, isStable: Bool)? {
    var previous: CGPoint?
    var lastSeen: CGPoint?
    for attempt in 0..<maxAttempts {
      if attempt > 0 { delay() }
      guard let point = read() else {
        previous = nil
        continue
      }
      if let previous,
        abs(previous.x - point.x) <= tolerance, abs(previous.y - point.y) <= tolerance
      {
        return (point, true)
      }
      previous = point
      lastSeen = point
    }
    return lastSeen.map { ($0, false) }
  }

  /// Posts a mouseUp event at the given point.
  static func postMouseUp(at point: CGPoint) {
    if let up = CGEvent(
      mouseEventSource: nil, mouseType: .leftMouseUp,
      mouseCursorPosition: point, mouseButton: .left)
    {
      up.post(tap: .cghidEventTap)
    }
  }

  // MARK: - Window Move via Mission Control

  /// Moves a window to a different Space by activating it, opening Mission Control,
  /// and simulating a drag to the target space.
  ///
  /// - Parameters:
  ///   - windowID: CGWindowID of the window to move.
  ///   - targetSpaceID: ManagedSpaceID of the destination space.
  /// - Throws: `WindowActivationError` if the window can't be found or activated.
  /// - Returns: `true` if the drag completed successfully.
  @discardableResult
  public func moveWindowToSpace(windowID: Int, targetSpaceID: UInt64) throws -> Bool {
    let token = Diagnostics.beginTiming(
      "move-space", "moveWindowToSpace",
      extras: ["windowID": "\(windowID)", "targetSpace": "\(targetSpaceID)"])
    // 1. Look up the window title from the raw window list.
    let windowList = dataSource.fetchWindowList()
    guard
      let entry = windowList.first(where: {
        ($0[kCGWindowNumber as String] as? Int) == windowID
      })
    else {
      Diagnostics.endTiming(token, outcome: "window-not-found")
      throw WindowActivationError.windowNotFound(windowID: windowID)
    }
    let windowTitle =
      (entry[kCGWindowName as String] as? String)
      ?? (entry[kCGWindowOwnerName as String] as? String)
      ?? ""

    // 2. Resolve the target space's "Desktop N" label (what MC shows).
    //    MC uses global numbering across all displays, not per-display ordinals.
    let allSpaces = getAllSpaces()
    guard let targetSpace = allSpaces.first(where: { $0.id == targetSpaceID }) else {
      Diagnostics.endTiming(token, outcome: "target-space-not-found")
      print("moveWindowToSpace: space \(targetSpaceID) not found")
      return false
    }

    let allDesktopSpaces = allSpaces.filter { $0.type == .desktop }
    guard let ordinalIndex = allDesktopSpaces.firstIndex(where: { $0.id == targetSpaceID })
    else {
      Diagnostics.endTiming(token, outcome: "no-ordinal")
      print("moveWindowToSpace: could not determine ordinal for space \(targetSpaceID)")
      return false
    }
    let targetSpaceTitle = "Desktop \(ordinalIndex + 1)"
    Diagnostics.log(
      "move-space",
      "title=\(Diagnostics.titleForLogging(windowTitle)) → \(targetSpaceTitle) targetDisplay=\(targetSpace.displayUUID)"
    )

    // 3. Activate the window to switch to its space.
    // When the window is already on a current Space there is no space-switch
    // animation to wait out — only a brief settle for the activation itself.
    let currentSpaceIDs = Set(allSpaces.filter(\.isCurrent).map(\.id))
    let sourceSpaceIDs = dataSource.fetchSpacesForWindow(windowID)
    let needsSpaceSwitch = !sourceSpaceIDs.contains(where: { currentSpaceIDs.contains($0) })
    try activateWindow(id: windowID)

    // 4. Wait for the space switch animation to complete.
    Thread.sleep(forTimeInterval: needsSpaceSwitch ? 0.8 : 0.25)

    // 5. Perform the MC drag. Pass target display so the space button is found
    //    on the correct display (supports cross-display moves).
    let targetScreenNumber = Self.displayIDForUUID(targetSpace.displayUUID)
    let moved = moveWindowInMC(
      windowTitle: windowTitle, targetSpaceTitle: targetSpaceTitle,
      targetScreenNumber: targetScreenNumber)

    // 6. Activate the window again so it's in front on the target space.
    if moved {
      Thread.sleep(forTimeInterval: 0.3)
      try activateWindow(id: windowID)
    }

    Diagnostics.endTiming(token, outcome: moved ? "moved" : "drag-failed")
    return moved
  }

  /// Moves a window to a different Space by simulating a drag in Mission Control.
  ///
  /// Opens Mission Control, searches ALL displays for the window thumbnail and
  /// target space button (supporting cross-display moves), initiates a drag,
  /// and drops the window on the target space.
  ///
  /// - Parameters:
  ///   - windowTitle: Substring to match against MC window thumbnail titles.
  ///   - targetSpaceTitle: Exact title of the target space (e.g., "Desktop 2").
  ///   - targetScreenNumber: Screen number of the display containing the target space.
  ///   - verbose: Print diagnostic output.
  /// - Returns: `true` if the drag completed, `false` on any error.
  @discardableResult
  public func moveWindowInMC(
    windowTitle: String, targetSpaceTitle: String,
    targetScreenNumber: CGDirectDisplayID? = nil, verbose: Bool = false
  ) -> Bool {
    guard AXIsProcessTrusted() else {
      print("moveWindowInMC: Accessibility not trusted")
      return false
    }

    let semaphore = DispatchSemaphore(value: 0)
    var success = false

    DispatchQueue.global(qos: .userInteractive).async {
      defer { semaphore.signal() }

      guard
        let dockApp = NSRunningApplication.runningApplications(
          withBundleIdentifier: "com.apple.dock"
        ).first
      else {
        print("moveWindowInMC: Dock not running")
        return
      }

      let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)
      CoreDockSendNotification("com.apple.expose.awake" as CFString)

      // Poll for MC
      let mcGroup: AXUIElement? = {
        let deadline = DispatchTime.now() + .milliseconds(2000)
        while DispatchTime.now() < deadline {
          if let mc = Self.axChildWithIdentifier(dockElement, identifier: "mc") { return mc }
          Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
      }()

      guard let mcGroup else {
        print("moveWindowInMC: Mission Control not found")
        Self.dismissMissionControl()
        return
      }

      Thread.sleep(forTimeInterval: 0.5)

      // Gather all mc.display elements
      let allDisplays = Self.axChildren(mcGroup).filter {
        Self.axStringAttribute($0, name: "AXIdentifier") == "mc.display"
      }

      // Search ALL displays for the window thumbnail
      var windowButton: AXUIElement?
      var windowCenter: CGPoint?
      for display in allDisplays {
        guard let mcWindows = Self.axChildWithIdentifier(display, identifier: "mc.windows") else {
          continue
        }
        let buttons = Self.axChildren(mcWindows)
        // Exact match first
        if let exact = buttons.first(where: {
          Self.axStringAttribute($0, name: "AXTitle") == windowTitle
        }) {
          windowButton = exact
          windowCenter = Self.axCenter(exact)
          break
        }
        // Substring fallback
        let matches = buttons.filter {
          (Self.axStringAttribute($0, name: "AXTitle") ?? "")
            .localizedCaseInsensitiveContains(windowTitle)
        }
        if matches.count == 1, let match = matches.first {
          windowButton = match
          windowCenter = Self.axCenter(match)
          break
        }
      }

      guard let windowButton, let windowCenter else {
        print("moveWindowInMC: No window matching \"\(windowTitle)\" on any display")
        Self.dismissMissionControl()
        return
      }

      if verbose {
        let title = Self.axStringAttribute(windowButton, name: "AXTitle") ?? "?"
        print("  Window: \"\(title)\" at \(windowCenter)")
      }

      // Build display search order — target display first
      let displaySearchOrder: [AXUIElement]
      if let targetScreenNumber {
        let targetDisplay = allDisplays.first { display in
          var valueRef: CFTypeRef?
          if AXUIElementCopyAttributeValue(display, "AXDisplayID" as CFString, &valueRef)
            == .success,
            let displayID = valueRef as? Int,
            CGDirectDisplayID(displayID) == targetScreenNumber
          {
            return true
          }
          return false
        }
        if let targetDisplay {
          displaySearchOrder = [targetDisplay] + allDisplays.filter { $0 != targetDisplay }
        } else {
          displaySearchOrder = allDisplays
        }
      } else {
        displaySearchOrder = allDisplays
      }

      // Locate the spaces bar that contains the target space.
      var barList: AXUIElement?
      for display in displaySearchOrder {
        guard let mcSpaces = Self.axChildWithIdentifier(display, identifier: "mc.spaces"),
          let mcSpacesList = Self.axChildWithIdentifier(mcSpaces, identifier: "mc.spaces.list")
        else { continue }
        let buttons = Self.axChildren(mcSpacesList)
        if buttons.contains(where: {
          Self.axStringAttribute($0, name: "AXTitle") == targetSpaceTitle
        }) {
          barList = mcSpacesList
          break
        }
      }

      guard let barList else {
        print("moveWindowInMC: Space \"\(targetSpaceTitle)\" not found on any display")
        Self.dismissMissionControl()
        return
      }

      // Grab and nudge to initiate drag
      Self.postMouseMoveAndGrab(at: windowCenter)
      let nudge = CGPoint(x: windowCenter.x, y: windowCenter.y - 15)
      Self.postMouseDragToPoint(from: windowCenter, to: nudge, steps: 3)

      // Homing glide: one continuous motion that re-reads the tile's position
      // every few steps and bends toward the latest reading. The path heads
      // straight for the tile's pre-drag position; when the drag crosses into
      // the bar, MC expands it and shifts every tile, and the re-reads bend the
      // path onto the tile's new center. AX references are live, so re-reading
      // the bar's children reflects the current layout.
      var targetButton: AXUIElement?
      let readTargetCenter: () -> CGPoint? = {
        let buttons = Self.axChildren(barList)
        guard
          let match = buttons.first(where: {
            Self.axStringAttribute($0, name: "AXTitle") == targetSpaceTitle
          })
        else { return nil }
        targetButton = match
        return Self.axCenter(match)
      }
      let arrival = Self.homingDrag(
        from: nudge,
        read: readTargetCenter,
        move: { point in
          Self.postMouseDragEvent(at: point)
          Thread.sleep(forTimeInterval: 0.008)
        }
      )
      guard let arrival, let targetButton else {
        print("moveWindowInMC: Space \"\(targetSpaceTitle)\" not found during drag")
        Self.postMouseUp(at: nudge)
        Self.dismissMissionControl()
        return
      }

      if verbose { print("  Target: \"\(targetSpaceTitle)\" at \(arrival)") }

      // Hold until the bar's relayout fully settles, following any residual
      // shift so the drop lands dead-center.
      var dropPoint = arrival
      if let settled = Self.awaitStablePoint(
        read: readTargetCenter, delay: { Thread.sleep(forTimeInterval: 0.04) }),
        abs(settled.point.x - dropPoint.x) > 2 || abs(settled.point.y - dropPoint.y) > 2
      {
        Self.postMouseDragToPoint(from: dropPoint, to: settled.point, steps: 4)
        dropPoint = settled.point
      }
      Thread.sleep(forTimeInterval: 0.05)
      Self.postMouseUp(at: dropPoint)

      // Click the target space to switch to it (also dismisses MC)
      Thread.sleep(forTimeInterval: 0.3)
      AXUIElementPerformAction(targetButton, kAXPressAction as CFString)
      success = true
    }

    semaphore.wait()
    return success
  }

  // MARK: - Mission Control Diagnostics

  /// Dumps the full AX hierarchy of Mission Control for diagnostic purposes.
  public func dumpMissionControlAXTree() {
    guard AXIsProcessTrusted() else {
      print("dumpMissionControlAXTree: Accessibility not trusted")
      return
    }

    let semaphore = DispatchSemaphore(value: 0)

    DispatchQueue.global(qos: .userInteractive).async {
      guard let mc = Self.openMissionControlContext() else {
        Self.dismissMissionControl()
        semaphore.signal()
        return
      }

      print("=== Mission Control AX Tree ===\n")
      Self.dumpAXElement(mc.mcGroup, indent: 0)
      print("\n=== End AX Tree ===")

      Thread.sleep(forTimeInterval: 0.3)
      Self.dismissMissionControl()
      semaphore.signal()
    }

    semaphore.wait()
  }

  /// Opens Mission Control, grabs a window, nudges it to initiate drag,
  /// re-queries positions, then visits each space button (1.5s each)
  /// before dropping on a specified space. Used as a manual functional test.
  public func debugMCDragPositions(windowTitle: String, dropSpaceTitle: String? = nil) {
    guard AXIsProcessTrusted() else { return }

    let semaphore = DispatchSemaphore(value: 0)

    DispatchQueue.global(qos: .userInteractive).async {
      guard let mc = Self.openMissionControlContext() else {
        Self.dismissMissionControl()
        semaphore.signal()
        return
      }

      // Find the window thumbnail
      guard let windowButton = mc.findWindowButton(titled: windowTitle),
        let windowCenter = Self.axCenter(windowButton)
      else {
        let matches = mc.findWindowButtons(titleContaining: windowTitle)
        if matches.count > 1 {
          print("Multiple windows match \"\(windowTitle)\":")
          for m in matches {
            print("  - \(Self.axStringAttribute(m, name: "AXTitle") ?? "?")")
          }
        } else {
          print("Window \"\(windowTitle)\" not found")
        }
        Self.dismissMissionControl()
        semaphore.signal()
        return
      }

      // Grab and nudge to initiate drag
      Self.postMouseMoveAndGrab(at: windowCenter)
      let nudge = CGPoint(x: windowCenter.x, y: windowCenter.y - 15)
      Self.postMouseDragToPoint(from: windowCenter, to: nudge, steps: 3)
      Thread.sleep(forTimeInterval: 0.8)

      // Re-query positions after drag initiation
      let spaceButtons = mc.spaceButtons
      var lastPoint = nudge

      // Visit each space button
      for (i, btn) in spaceButtons.enumerated() {
        let title = Self.axStringAttribute(btn, name: "AXTitle") ?? "?"
        guard let center = Self.axCenter(btn) else { continue }
        print("Moving to [\(i)] \"\(title)\" at \(center)")
        Self.postMouseDragToPoint(from: lastPoint, to: center, steps: 10)
        lastPoint = center
        Thread.sleep(forTimeInterval: 1.5)
      }

      // Drop on the specified space, or the last one visited
      let dropTitle =
        dropSpaceTitle
        ?? Self.axStringAttribute(spaceButtons.last!, name: "AXTitle") ?? ""
      if let dropButton = mc.findSpaceButton(titled: dropTitle),
        let dropCenter = Self.axCenter(dropButton)
      {
        print("Dropping on \"\(dropTitle)\" at \(dropCenter)")
        Self.postMouseDragToPoint(from: lastPoint, to: dropCenter, steps: 10)
        Thread.sleep(forTimeInterval: 0.5)
        Self.postMouseUp(at: dropCenter)
      } else {
        print("Drop target \"\(dropTitle)\" not found, releasing at last position")
        Self.postMouseUp(at: lastPoint)
      }

      Thread.sleep(forTimeInterval: 0.3)
      Self.dismissMissionControl()
      print("Done.")
      semaphore.signal()
    }

    semaphore.wait()
  }

  /// Recursively prints an AX element and all its children.
  private static func dumpAXElement(_ element: AXUIElement, indent: Int) {
    let prefix = String(repeating: "  ", count: indent)

    let identifier = axStringAttribute(element, name: "AXIdentifier") ?? "-"
    let role = axStringAttribute(element, name: "AXRole") ?? "-"
    let subrole = axStringAttribute(element, name: "AXSubrole") ?? "-"
    let title = axStringAttribute(element, name: "AXTitle") ?? "-"
    let desc = axStringAttribute(element, name: "AXDescription") ?? "-"
    let posStr = axPosition(element).map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "-"
    let sizeStr = axSize(element).map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"
    let children = axChildren(element)

    print(
      "\(prefix)[\(role)/\(subrole)] id=\(identifier) title=\"\(title)\" desc=\"\(desc)\""
        + " pos=\(posStr) size=\(sizeStr) children=\(children.count)")

    var namesRef: CFArray?
    if AXUIElementCopyAttributeNames(element, &namesRef) == .success,
      let names = namesRef as? [String]
    {
      let printed = Set([
        "AXIdentifier", "AXRole", "AXSubrole", "AXTitle", "AXDescription",
        "AXPosition", "AXSize", "AXChildren", "AXParent", "AXTopLevelUIElement",
        "AXWindow",
      ])
      let interesting = names.filter { !printed.contains($0) }
      if !interesting.isEmpty {
        print("\(prefix)  attrs: \(interesting.joined(separator: ", "))")
        for name in interesting {
          var valRef: CFTypeRef?
          if AXUIElementCopyAttributeValue(element, name as CFString, &valRef) == .success,
            let val = valRef
          {
            if let str = val as? String {
              print("\(prefix)    \(name) = \"\(str)\"")
            } else if let num = val as? NSNumber {
              print("\(prefix)    \(name) = \(num)")
            }
          }
        }
      }
    }

    for child in children {
      dumpAXElement(child, indent: indent + 1)
    }
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
    findAXWindowBruteForceResult(pid: pid, targetCGWindowID: targetCGWindowID).element
  }

  private struct AXWindowBruteForceResult {
    let element: AXUIElement?
    let scannedCount: UInt64
    let highestElementID: UInt64?
    let timedOut: Bool
    let timeoutMilliseconds: Int
    let matchedWindowIDCount: Int
    let rejectedSubroles: [String]

    var diagnosticsSummary: String {
      let highest = highestElementID.map(String.init) ?? "none"
      let rejected =
        rejectedSubroles.isEmpty ? "[]" : "[\(rejectedSubroles.joined(separator: ","))]"
      return
        "brute-scanned=\(scannedCount) brute-highest=\(highest) brute-timeout-ms=\(timeoutMilliseconds) brute-timed-out=\(timedOut) brute-window-id-matches=\(matchedWindowIDCount) brute-rejected-subroles=\(rejected)"
    }
  }

  private func findAXWindowBruteForceResult(
    pid: pid_t, targetCGWindowID: CGWindowID, timeout: TimeInterval = 1.0
  ) -> AXWindowBruteForceResult {
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
    let timeoutNanos = UInt64(timeout * 1_000_000_000)
    let timeoutMilliseconds = Int(timeout * 1000)
    var scannedCount: UInt64 = 0
    var highestElementID: UInt64?
    var timedOut = false
    var matchedWindowIDCount = 0
    var rejectedSubroles: [String] = []

    func elapsedPastTimeout() -> Bool {
      DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds > timeoutNanos
    }

    func result(_ element: AXUIElement?) -> AXWindowBruteForceResult {
      AXWindowBruteForceResult(
        element: element,
        scannedCount: scannedCount,
        highestElementID: highestElementID,
        timedOut: timedOut,
        timeoutMilliseconds: timeoutMilliseconds,
        matchedWindowIDCount: matchedWindowIDCount,
        rejectedSubroles: rejectedSubroles)
    }

    for elementID: UInt64 in 0..<maxElementID {
      scannedCount += 1
      highestElementID = elementID
      tokenData.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })

      guard
        let unmanaged = _AXUIElementCreateWithRemoteToken(tokenData as CFData),
        case let element = unmanaged.takeRetainedValue()
      else {
        if elapsedPastTimeout() {
          timedOut = true
          break
        }
        continue
      }

      // Check CGWindowID first — eliminates elements not in our target window.
      var cgWid: CGWindowID = 0
      guard _AXUIElementGetWindow(element, &cgWid) == .success,
        cgWid == targetCGWindowID
      else {
        if elapsedPastTimeout() {
          timedOut = true
          break
        }
        continue
      }
      matchedWindowIDCount += 1

      // CGWindowID matches — verify this is a window element, not a child
      // (buttons, text fields etc. also report their containing window's ID).
      var subroleRef: CFTypeRef?
      if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        == .success,
        let subrole = subroleRef as? String,
        subrole == kAXStandardWindowSubrole as String
          || subrole == kAXDialogSubrole as String
      {
        return result(element)
      }
      if rejectedSubroles.count < 8 {
        if let subrole = subroleRef as? String {
          rejectedSubroles.append(subrole)
        } else {
          rejectedSubroles.append("unreadable")
        }
      }
      if elapsedPastTimeout() {
        timedOut = true
        break
      }
    }

    return result(nil)
  }

  func activationContextForDiagnostics(windowID: Int) -> String {
    let spaces = getAllSpaces()
    let currentSpaces = spaces.filter(\.isCurrent).map(formatSpaceForActivationDiagnostics)
    let targetSpaceIDs = dataSource.fetchSpacesForWindow(windowID)
    let targetSpaces = targetSpaceIDs.map { spaceID in
      spaces.first(where: { $0.id == spaceID }).map(formatSpaceForActivationDiagnostics)
        ?? "id=\(spaceID) metadata=missing"
    }
    return
      "currentSpaces=\(formatActivationDiagnosticsList(currentSpaces)) targetSpaceIDs=\(formatActivationDiagnosticsIDs(targetSpaceIDs)) targetSpaces=\(formatActivationDiagnosticsList(targetSpaces))"
  }

  func spaceWakeFallbackTargetForActivation(windowID: Int) -> SpaceInfo? {
    let spaces = getAllSpaces()
    let targetSpaceIDs = dataSource.fetchSpacesForWindow(windowID)
    guard targetSpaceIDs.count == 1, let targetSpaceID = targetSpaceIDs.first else {
      return nil
    }
    guard let targetSpace = spaces.first(where: { $0.id == targetSpaceID }) else {
      return nil
    }
    guard targetSpace.type == .desktop, !targetSpace.isCurrent else {
      return nil
    }
    return targetSpace
  }

  private func currentSpacesForActivationDiagnostics() -> String {
    formatActivationDiagnosticsList(
      getAllSpaces().filter(\.isCurrent).map(formatSpaceForActivationDiagnostics))
  }

  private func waitForCurrentSpace(_ spaceID: UInt64, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if getAllSpaces().contains(where: { $0.id == spaceID && $0.isCurrent }) {
        return true
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return getAllSpaces().contains(where: { $0.id == spaceID && $0.isCurrent })
  }

  private func logSpaceChangeAfterSkyLight(
    windowID: Int, ownerName: String, beforeCurrentSpaces: String, phase: String
  ) {
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(750)) {
      [self] in
      let afterCurrentSpaces = currentSpacesForActivationDiagnostics()
      Diagnostics.log(
        "activate",
        "windowID=\(windowID) skylight-space-check phase=\(phase) delay=750ms beforeCurrentSpaces=\(beforeCurrentSpaces) afterCurrentSpaces=\(afterCurrentSpaces) changed=\(beforeCurrentSpaces != afterCurrentSpaces)",
        app: ownerName)
    }
  }

  private func formatSpaceForActivationDiagnostics(_ space: SpaceInfo) -> String {
    let type: String
    switch space.type {
    case .desktop: type = "desktop"
    case .fullscreen: type = "fullscreen"
    }
    return
      "id=\(space.id) uuid=\(space.uuid) display=\(space.displayUUID) type=\(type) current=\(space.isCurrent)"
  }

  private func formatActivationDiagnosticsList(_ values: [String]) -> String {
    values.isEmpty ? "[]" : "[\(values.joined(separator: "; "))]"
  }

  private func formatActivationDiagnosticsIDs(_ values: [UInt64]) -> String {
    values.isEmpty ? "[]" : "[\(values.map(String.init).joined(separator: ","))]"
  }

}

// MARK: - Diagnostics snapshot

extension SpaceManager: SpaceManagerSnapshotProvider {
  public func spaceSnapshotForDiagnostics() -> [String] {
    let spaces = getAllSpaces()
    return spaces.map { s in
      let typeStr: String
      switch s.type {
      case .desktop: typeStr = "desktop"
      case .fullscreen: typeStr = "fullscreen"
      }
      return
        "id=\(s.id) uuid=\(s.uuid) display=\(s.displayUUID) type=\(typeStr) current=\(s.isCurrent)"
    }
  }
}
