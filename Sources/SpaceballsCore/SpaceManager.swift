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
  public let isMinimized: Bool

  /// Window appears on multiple spaces (e.g. "Assign to All Desktops")
  public var isSticky: Bool { spaceIDs.count > 1 }

  public init(
    id: Int, ownerName: String, name: String?,
    pid: Int, bounds: CGRect, spaceIDs: [UInt64],
    isOnscreen: Bool = true, isMinimized: Bool = false
  ) {
    self.id = id
    self.ownerName = ownerName
    self.name = name
    self.pid = pid
    self.bounds = bounds
    self.spaceIDs = spaceIDs
    self.isOnscreen = isOnscreen
    self.isMinimized = isMinimized
  }
}

// MARK: - SpaceManager

public class SpaceManager {
  private let dataSource: SystemDataSource
  private let instantSpaceSwitcher: any InstantSpaceSwitching
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

  /// User-tunable pauses for the Mission Control drag flows (space moves,
  /// eject, restore). See SpaceMoveTiming for the knobs and their defaults.
  public var moveTiming = SpaceMoveTiming()

  public init(dataSource: SystemDataSource = CGSDataSource()) {
    self.dataSource = dataSource
    self.instantSpaceSwitcher = DockSwipeSpaceSwitcher()
  }

  init(
    dataSource: SystemDataSource,
    instantSpaceSwitcher: any InstantSpaceSwitching
  ) {
    self.dataSource = dataSource
    self.instantSpaceSwitcher = instantSpaceSwitcher
  }

  /// Returns whether a window from the given PID should be included in results.
  private func shouldIncludeWindow(
    pid: pid_t, appInfoCache: inout [pid_t: AppInfo?]
  ) -> Bool {
    if pid == selfPID { return true }

    let info: AppInfo?
    if let cached = appInfoCache[pid] {
      info = cached
    } else {
      info = dataSource.appInfo(pid: pid)
      appInfoCache[pid] = info
    }

    // No LaunchServices-registered app owns this pid; keep its windows.
    guard let info else { return true }

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
    var appInfoCache: [pid_t: AppInfo?] = [:]
    var minimizedIDsByPID: [pid_t: Set<CGWindowID>?] = [:]

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
      let minimizedIDs: Set<CGWindowID>?
      if isOnscreen {
        minimizedIDs = nil
      } else if let cached = minimizedIDsByPID[pidT] {
        minimizedIDs = cached
      } else {
        minimizedIDs = dataSource.minimizedAXWindowIDs(pid: pidT)
        minimizedIDsByPID[pidT] = minimizedIDs
      }

      windows.append(
        WindowInfo(
          id: windowID,
          ownerName: ownerName,
          name: name,
          pid: pid,
          bounds: bounds,
          spaceIDs: spaceIDs,
          isOnscreen: isOnscreen,
          isMinimized: minimizedIDs?.contains(CGWindowID(windowID)) == true
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
      // A window positively identified as minimized is necessarily still live.
      if window.isMinimized {
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
    var appInfoCache: [pid_t: AppInfo?] = [:]

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

  /// Returns a window's frame in global CG coordinates (top-left origin), or
  /// nil when CGS has no record of the window or its bounds.
  public func windowBounds(forWindowID windowID: Int) -> CGRect? {
    dataSource.fetchWindowList()
      .first(where: { ($0[kCGWindowNumber as String] as? Int) == windowID })
      .flatMap(Self.windowBounds(in:))
  }

  /// Parses `kCGWindowBounds` from a raw window-list entry.
  static func windowBounds(in entry: [String: Any]) -> CGRect? {
    guard let boundsRef = entry[kCGWindowBounds as String] else { return nil }
    var bounds = CGRect.zero
    // swiftlint:disable:next force_cast
    let boundsDict = boundsRef as CFTypeRef as! CFDictionary
    guard CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds) else { return nil }
    return bounds
  }

  /// Warps the mouse cursor to a global point (CG coordinates, top-left
  /// origin). Public CoreGraphics API — no extra permissions needed, and no
  /// synthetic event that could interact with the key-interception tap.
  public static func warpCursor(to point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    // Warping starts a brief suppression interval for hardware mouse events;
    // re-associate immediately so the pointer stays responsive.
    CGAssociateMouseAndMouseCursorPosition(1)
  }

  /// Warps the mouse cursor to the center of the given display.
  public static func warpCursorToDisplayCenter(_ displayID: CGDirectDisplayID) {
    let bounds = CGDisplayBounds(displayID)
    warpCursor(to: CGPoint(x: bounds.midX, y: bounds.midY))
  }

  /// The CGS display UUID of the built-in display, or nil when none is
  /// active (clamshell mode, desktop Macs).
  public static func builtinDisplayUUID() -> String? {
    var count: UInt32 = 0
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    CGGetActiveDisplayList(16, &ids, &count)
    for i in 0..<Int(count) where CGDisplayIsBuiltin(ids[i]) != 0 {
      guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(ids[i])?.takeUnretainedValue()
      else { continue }
      return CFUUIDCreateString(nil, cfUUID) as String
    }
    return nil
  }

  /// The mouse cursor's position in global CG coordinates (top-left origin —
  /// the same space as `kCGWindowBounds` and `warpCursor(to:)`), or nil when
  /// no event can be synthesized to read it.
  public static func cursorPosition() -> CGPoint? {
    CGEvent(source: nil)?.location
  }

  /// Returns the display UUID currently containing the mouse cursor.
  public static func cursorDisplayUUID() -> String? {
    let location = NSEvent.mouseLocation  // global, bottom-left origin
    guard
      let screen = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }),
      let screenNumber = screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
      let cfUUID = CGDisplayCreateUUIDFromDisplayID(screenNumber)?.takeUnretainedValue()
    else { return nil }
    return CFUUIDCreateString(nil, cfUUID) as String
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
  /// Prefers a synthetic high-velocity DockSwipe, which performs the real
  /// transition without its slide animation. If that private path cannot be
  /// prepared safely, falls back to pressing the target tile through Mission
  /// Control's Accessibility hierarchy.
  public func switchToSpace(id spaceID: UInt64) throws {
    let allSpaces = getAllSpaces()
    guard let targetSpace = allSpaces.first(where: { $0.id == spaceID }) else {
      throw SpaceSwitchError.spaceNotFound(spaceID: spaceID)
    }

    guard targetSpace.type == .desktop else {
      throw SpaceSwitchError.notDesktopSpace(spaceID: spaceID)
    }

    // Already the active Space on its display — switching would only flash
    // Mission Control (the empty-space path) for a no-op.
    guard !targetSpace.isCurrent else { return }

    switch instantSpaceSwitcher.switchToSpace(targetSpace, among: allSpaces) {
    case .switched:
      Diagnostics.log("space-switch", "space \(spaceID) path=dock-swipe")
      return
    case .alreadyThere:
      return
    case .declined(let reason):
      Diagnostics.log(
        "space-switch",
        "space \(spaceID) dock-swipe declined (\(reason)); falling back to MC tile press")
    }

    guard Self.ensureAccessibilityTrusted() else {
      throw SpaceSwitchError.accessibilityNotTrusted
    }

    guard let spaceIndex = Self.perDisplayDesktopIndex(of: spaceID, in: allSpaces) else {
      throw SpaceSwitchError.spaceNotFound(spaceID: spaceID)
    }

    guard let screenNumber = Self.displayIDForUUID(targetSpace.displayUUID) else {
      throw SpaceSwitchError.displayNotFound(displayUUID: targetSpace.displayUUID)
    }

    switchToSpace(spaceIndex: spaceIndex, screenNumber: screenNumber)
  }

  /// The frontmost enumerated window on a Space, if any — drawn from the
  /// same filtered window set the switcher panel displays (exclusions and
  /// helper-window rules applied).
  public func frontWindow(onSpace spaceID: UInt64) -> WindowInfo? {
    getAllWindows().first { $0.spaceIDs.contains(spaceID) }
  }

  /// Activates a Space the way the switcher panel does: by activating a
  /// window on it when one exists — with an instant, verified DockSwipe
  /// pre-switch where supported — and only falling back to the direct Space
  /// switching path when the Space is empty.
  /// Returns true when the fast windowed path succeeded.
  @discardableResult
  public func activateSpace(id spaceID: UInt64) throws -> Bool {
    let lookupStart = Date()
    let window = frontWindow(onSpace: spaceID)
    Diagnostics.log(
      "space-switch",
      "space \(spaceID) front-window=\(window.map { String($0.id) } ?? "none") lookup=\(Int(Date().timeIntervalSince(lookupStart) * 1000))ms"
    )
    if let window {
      do {
        try activateWindow(id: window.id)
        return true
      } catch {
        Diagnostics.log(
          "space-switch",
          "window activation for space \(spaceID) failed (\(error)); using Mission Control")
      }
    }
    try switchToSpace(id: spaceID)
    return false
  }

  // MARK: - High-Level Space Operations

  /// Creates missing spaces from a list of default names, pruning stale
  /// name mappings first. Returns the number of spaces created.
  public func createDefaultSpaces(
    defaultNames: [String], spaceNameStore: SpaceNameStoring,
    completion: @escaping (Int) -> Void
  ) {
    let spaces = getAllSpaces()
    spaceNameStore.pruneStaleNames(currentSpaces: spaces)

    let missingNames = defaultNames.filter {
      spaceNameStore.spaceWithCustomName($0, in: spaces) == nil
    }

    guard !missingNames.isEmpty else {
      completion(0)
      return
    }

    // Snapshot UUIDs before creating: the new spaces are identified by diff,
    // never by list position (getAllSpaces enumerates display-by-display, so a
    // new space lands mid-list on multi-display setups).
    let beforeUUIDs = Set(getAllSpaces().map(\.uuid))

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

      // Wait for macOS to settle, then name exactly the spaces that appeared
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        let newSpaces = Self.newlyCreatedSpaces(before: beforeUUIDs, after: self.getAllSpaces())
        for (name, space) in zip(missingNames, newSpaces) {
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

    let spaces = getAllSpaces()
    spaceNameStore.pruneStaleNames(currentSpaces: spaces)

    let missingNames = defaultNames.filter {
      spaceNameStore.spaceWithCustomName($0, in: spaces) == nil
    }
    guard !missingNames.isEmpty else { return 0 }

    let beforeUUIDs = Set(getAllSpaces().map(\.uuid))
    // A single new space zooms straight into itself from the create session;
    // multi-space restores keep the no-switch create (each workspace is
    // visited in turn by the restorer anyway).
    try createSpaceSync(count: missingNames.count, switchToNewSpace: missingNames.count == 1)
    Thread.sleep(forTimeInterval: 1.0)

    let newSpaces = Self.newlyCreatedSpaces(before: beforeUUIDs, after: getAllSpaces())
    for (name, space) in zip(missingNames, newSpaces) {
      spaceNameStore.setCustomName(name, forSpaceUUID: space.uuid)
    }

    return newSpaces.count
  }

  /// Creates a single space and assigns a name to it.
  public func createNamedSpaceSync(name: String, spaceNameStore: SpaceNameStoring) throws {
    let beforeUUIDs = Set(getAllSpaces().map(\.uuid))
    try createSpaceSync(count: 1)
    Thread.sleep(forTimeInterval: 1.0)

    if let newSpace = Self.newlyCreatedSpaces(before: beforeUUIDs, after: getAllSpaces()).first {
      spaceNameStore.setCustomName(name, forSpaceUUID: newSpace.uuid)
    }
  }

  /// Returns the desktop spaces in `after` whose UUIDs are not in `before` —
  /// i.e. the spaces created between the two snapshots — in enumeration order.
  ///
  /// This is the only safe way to identify a just-created space: enumeration is
  /// display-by-display, so a new space appears at the end of its own display's
  /// sub-list (mid-list globally), and position-based guesses ("last unnamed
  /// space") assign workspace names to unrelated spaces on other displays.
  static func newlyCreatedSpaces(before: Set<String>, after: [SpaceInfo]) -> [SpaceInfo] {
    after.filter { $0.type == .desktop && !before.contains($0.uuid) }
  }

  /// The space's 0-based tile index among its display's desktop spaces —
  /// the per-display CGS order that matches Mission Control's bar
  /// (fullscreen spaces have no desktop tile). Nil for unknown or
  /// fullscreen spaces.
  static func perDisplayDesktopIndex(of spaceID: UInt64, in spaces: [SpaceInfo]) -> Int? {
    guard let space = spaces.first(where: { $0.id == spaceID }) else { return nil }
    return
      spaces
      .filter { $0.displayUUID == space.displayUUID && $0.type == .desktop }
      .firstIndex(where: { $0.id == spaceID })
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

  // MARK: - Close Space With Windows

  /// Closes every window trapped on a Space: apps whose windows all live on
  /// that Space are quit (graceful `terminate()`, so unsaved work still
  /// prompts); apps with windows elsewhere just lose their windows on this
  /// Space. Waits (bounded by `timeout`) on precise completion signals —
  /// process exit for quits, a confirmed AX press for closes — so a
  /// subsequent Space close doesn't dump still-open windows onto other
  /// Spaces, then calls `completion` — synchronously when there is nothing to
  /// close, otherwise on a background queue.
  public func closeWindowsInSpace(
    id spaceID: UInt64, timeout: TimeInterval = 3.0,
    completion: @escaping () -> Void
  ) {
    let plan = SpaceCloseWindowPlanner.plan(windows: getAllWindows(), spaceID: spaceID)
    guard !plan.actions.isEmpty else {
      completion()
      return
    }

    let describe: (SpaceCloseWindowPlanner.Action) -> String = {
      switch $0 {
      case .quitApp(let pid): return "quit-pid-\(pid)"
      case .closeWindow(let windowID, _): return "close-window-\(windowID)"
      }
    }
    Diagnostics.log(
      "close-space",
      "space \(spaceID) windows-phase start: \(plan.actions.map(describe).joined(separator: " "))")

    let state = WindowCloseWaitState()
    let started = Date()
    for action in plan.actions {
      switch action {
      case .quitApp(let pid):
        state.expectQuit(pid: pid)
        NSRunningApplication(processIdentifier: pid_t(pid))?.terminate()
      case .closeWindow(let windowID, let pid):
        state.expectWindow(windowID)
        performAXClose(windowID: windowID, pid: pid_t(pid)) { closed in
          state.resolveWindow(windowID, closed: closed)
        }
      }
    }

    let isRunning: (Int) -> Bool = { pid in
      guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { return false }
      return !app.isTerminated
    }
    DispatchQueue.global(qos: .userInteractive).async {
      let deadline = started.addingTimeInterval(timeout)
      while Date() < deadline, !state.allSettled(isRunning: isRunning) {
        Thread.sleep(forTimeInterval: 0.05)
      }
      // Brief grace so confirmed closes finish ordering out before MC opens.
      Thread.sleep(forTimeInterval: 0.15)

      let leftovers = state.unsettledSummary(isRunning: isRunning)
      Diagnostics.log(
        "close-space",
        "space \(spaceID) windows-phase done waited=\(Int(Date().timeIntervalSince(started) * 1000))ms\(leftovers.isEmpty ? "" : " relocating=[\(leftovers)]")"
      )
      completion()
    }
  }

  /// Closes a Space's windows first (quit-or-close per app), then closes the
  /// Space itself and removes its name mapping. Space-level guards run up
  /// front so a close that cannot succeed (last desktop, unknown ID) doesn't
  /// destroy windows first.
  public func closeSpaceWithWindowsAndRemoveName(
    id spaceID: UInt64, spaceNameStore: SpaceNameStoring,
    completion: @escaping (Result<Void, SpaceCloseError>) -> Void
  ) {
    let allSpaces = getAllSpaces()
    guard allSpaces.filter({ $0.type == .desktop }).count > 1 else {
      completion(.failure(.cannotCloseLastSpace))
      return
    }
    guard allSpaces.contains(where: { $0.id == spaceID }) else {
      completion(.failure(.spaceNotFound))
      return
    }

    closeWindowsInSpace(id: spaceID) { [self] in
      closeSpaceAndRemoveName(
        id: spaceID, spaceNameStore: spaceNameStore, completion: completion)
    }
  }

  /// Synchronous version for CLI usage.
  public func closeSpaceWithWindowsAndRemoveNameSync(
    id spaceID: UInt64, spaceNameStore: SpaceNameStoring
  ) throws {
    guard Self.ensureAccessibilityTrusted() else {
      throw SpaceCloseError.accessibilityNotTrusted
    }

    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<Void, SpaceCloseError>?

    closeSpaceWithWindowsAndRemoveName(id: spaceID, spaceNameStore: spaceNameStore) { r in
      result = r
      semaphore.signal()
    }

    semaphore.wait()

    if case .failure(let error) = result {
      throw error
    }
  }

  // MARK: - Space Creation

  /// Resolves the display used by Space creation. Workspace/default-space
  /// callers omit an override so creation remains on the primary display.
  static func creationDisplayID(
    requested: CGDirectDisplayID?,
    primary: CGDirectDisplayID
  ) -> CGDirectDisplayID {
    requested ?? primary
  }

  /// Creates a new desktop Space via the Dock's accessibility interface.
  /// Opens Mission Control, finds the "Add Desktop" button in the Spaces Bar,
  /// and clicks it.
  ///
  /// - Parameter count: Number of spaces to create (default 1).
  /// - Parameter screenNumber: Display to create the space on. Defaults to the
  ///   PRIMARY display — spaces on external displays are destroyed when the
  ///   display disconnects, collapsing their windows into a surviving space.
  /// - Parameter switchToNewSpace: When true (and exactly one space was
  ///   created), presses the new space's tile in the SAME Mission Control
  ///   session, so the session ends by zooming straight into the new space —
  ///   no dismissal, no settle pause, no separate switch. Verified via CGS;
  ///   falls back to a guarded dismiss + `switchToSpace(id:)` if the landing
  ///   isn't confirmed. Callers that must not change the active Space (eject's
  ///   Default Space creation) leave this false.
  /// - Parameter completion: Called on the main queue when done, with success/failure.
  public func createSpace(
    count: Int = 1, screenNumber: CGDirectDisplayID? = nil,
    switchToNewSpace: Bool = false,
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
    let beforeUUIDs = Set(getAllSpaces().map(\.uuid))
    Diagnostics.log(
      "space-create",
      "create started count=\(count) screen=\(screenNumber.map(String.init) ?? "primary")")

    CoreDockSendNotification("com.apple.expose.awake" as CFString)

    DispatchQueue.global(qos: .userInteractive).async {
      guard let tree = Self.awaitMissionControlTree(dockElement: dockElement, timeout: 1.0)
      else {
        completion?(.failure(.missionControlNotFound))
        return
      }

      Thread.sleep(forTimeInterval: 0.3)

      // Find the add button in the Spaces Bar on the target display.
      // With no explicit display, target the PRIMARY display (the menu-bar
      // display, normally the built-in one): spaces created on an external
      // display are destroyed when that display disconnects and macOS dumps
      // their windows into a surviving space, so workspace/default spaces must
      // never live on removable displays.
      let addResult: (button: AXUIElement, mcSpaces: AXUIElement)? = {
        let requestedScreen = Self.creationDisplayID(
          requested: screenNumber,
          primary: CGMainDisplayID())
        // Fall back to scanning every display's bar if the AX match fails.
        let displayElements = tree.display(matching: requestedScreen).map { [$0] } ?? tree.displays

        for displayChild in displayElements {
          if let mcSpaces = MissionControlTree.spacesBar(of: displayChild) {
            if let add = Self.axChildWithIdentifier(mcSpaces, identifier: "mc.spaces.add") {
              return (add, mcSpaces)
            }
            if let add = Self.findAddButton(in: mcSpaces) {
              return (add, mcSpaces)
            }
          }
        }
        return nil
      }()

      guard let addResult else {
        // Dismiss Mission Control before reporting error
        Self.dismissMissionControl()
        completion?(.failure(.addButtonNotFound))
        return
      }

      var created = 0
      for i in 0..<count {
        let result = AXUIElementPerformAction(addResult.button, kAXPressAction as CFString)
        guard result == .success else { break }
        created += 1
        if i < count - 1 {
          Thread.sleep(forTimeInterval: 0.5)
        }
      }

      // End the session by zooming straight into the new space when asked —
      // the dismiss-then-reswitch alternative costs a dismissal animation
      // plus settle pauses on the space the user is leaving anyway.
      if switchToNewSpace, created == 1,
        let newSpace = self.awaitNewSpace(before: beforeUUIDs, timeout: 1.5)
      {
        let landed = self.pressNewSpaceTileAndVerify(newSpace, mcSpaces: addResult.mcSpaces)
        if !landed {
          // Restore the invariant (MC gone), then the verified switch.
          Self.dismissMissionControlIfPresent(dockElement: dockElement)
          Self.awaitMissionControlDismissed(timeout: 2.0)
          try? self.switchToSpace(id: newSpace.id)
        }
        Diagnostics.log(
          "space-create",
          "created 1 of 1; new=[id=\(newSpace.id) uuid=\(newSpace.uuid)] switch-on-create=\(landed ? "landed" : "fallback")"
        )
        completion?(.success(created))
        return
      }

      Thread.sleep(forTimeInterval: 0.3)
      Self.dismissMissionControl()

      let newSpaces = Self.newlyCreatedSpaces(before: beforeUUIDs, after: self.getAllSpaces())
      Diagnostics.log(
        "space-create",
        "created \(created) of \(count); new=[\(newSpaces.map { "id=\($0.id) uuid=\($0.uuid)" }.joined(separator: "; "))] mc-dismiss-sent"
      )
      completion?(.success(created))
    }
  }

  /// Polls CGS until a space not in `before` appears — macOS registers the
  /// new space a beat after the add-button press.
  private func awaitNewSpace(before: Set<String>, timeout: TimeInterval) -> SpaceInfo? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let new = Self.newlyCreatedSpaces(before: before, after: getAllSpaces()).first {
        return new
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return nil
  }

  /// Presses the just-created space's tile in the still-open Mission Control
  /// session and confirms via CGS that the display landed on it. The bar is
  /// re-read AFTER the add press (the new tile shifted it), and the index
  /// comes from the per-display CGS desktop order — the same invariant the
  /// tile-press switching path relies on.
  private func pressNewSpaceTileAndVerify(
    _ newSpace: SpaceInfo, mcSpaces: AXUIElement
  ) -> Bool {
    guard
      let mcSpacesList = Self.axChildWithIdentifier(mcSpaces, identifier: "mc.spaces.list")
    else {
      Diagnostics.log("space-create", "switch-on-create: mc.spaces.list not found")
      return false
    }
    guard let tileIndex = Self.perDisplayDesktopIndex(of: newSpace.id, in: getAllSpaces())
    else {
      Diagnostics.log("space-create", "switch-on-create: no tile index for id=\(newSpace.id)")
      return false
    }

    // Give the fresh tile a beat to become interactive before pressing.
    Thread.sleep(forTimeInterval: 0.2)

    let children = Self.axChildren(mcSpacesList)
    guard tileIndex < children.count else {
      Diagnostics.log(
        "space-create",
        "switch-on-create: tile index \(tileIndex) out of range (have \(children.count))")
      return false
    }

    let tile = children[tileIndex]
    let title = Self.axStringAttribute(tile, name: "AXTitle") ?? "?"
    Diagnostics.log(
      "space-create",
      "switch-on-create pressing tile index=\(tileIndex)/\(children.count) title=\"\(title)\" target=id=\(newSpace.id)"
    )
    guard AXUIElementPerformAction(tile, kAXPressAction as CFString) == .success else {
      Diagnostics.log("space-create", "switch-on-create: tile press failed")
      return false
    }

    let deadline = Date().addingTimeInterval(2.0)
    while Date() < deadline {
      if getAllSpaces().contains(where: { $0.id == newSpace.id && $0.isCurrent }) {
        return true
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    Diagnostics.log("space-create", "switch-on-create: landing not confirmed by CGS")
    return false
  }

  /// Synchronous version for CLI usage.
  public func createSpaceSync(count: Int = 1, switchToNewSpace: Bool = false) throws {
    guard Self.ensureAccessibilityTrusted() else {
      throw SpaceCreateError.accessibilityNotTrusted
    }

    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<Int, SpaceCreateError>?

    createSpace(count: count, switchToNewSpace: switchToNewSpace) { r in
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
      guard let tree = Self.awaitMissionControlTree(dockElement: dockElement, timeout: 1.0)
      else {
        completion?(.failure(.missionControlNotFound))
        return
      }

      Thread.sleep(forTimeInterval: 0.3)

      // Navigate to the spaces list
      guard let mcDisplay = tree.display(matching: screenNumber) else {
        Self.dismissMissionControl()
        completion?(.failure(.spaceNotFound))
        return
      }

      guard let mcSpaces = MissionControlTree.spacesBar(of: mcDisplay),
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
  /// Error reporting for the Mission Control simulation flows: stdout for CLI
  /// users, the diagnostics log for the GUI — whose stdout goes nowhere, which
  /// previously made a failed automatic restore undiagnosable after the fact.
  private static func reportMCFailure(_ message: String) {
    print(message)
    Diagnostics.log("mc", message)
  }

  public func switchToSpace(spaceIndex: Int, screenNumber: CGDirectDisplayID) {
    guard AXIsProcessTrusted() else {
      Self.reportMCFailure("switchToSpace: Accessibility not trusted")
      return
    }

    guard
      let dockApp = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.dock"
      ).first
    else {
      Self.reportMCFailure("switchToSpace: Dock not running")
      return
    }

    let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)
    let before = currentSpace(onDisplayID: screenNumber)

    // Open Mission Control via the Dock's private CoreDock API.
    CoreDockSendNotification("com.apple.expose.awake" as CFString)

    DispatchQueue.global(qos: .userInteractive).async { [self] in
      guard let tree = Self.awaitMissionControlTree(dockElement: dockElement, timeout: 1.0)
      else {
        Self.reportMCFailure("switchToSpace: Mission Control AX tree not found")
        return
      }

      // Wait for Mission Control's animation to complete — the AX elements
      // appear in the tree before they're fully interactive.
      Thread.sleep(forTimeInterval: 0.3)

      // Navigate: mc.display (matching target display) → mc.spaces → mc.spaces.list
      guard let mcDisplay = tree.display(matching: screenNumber) else {
        Self.reportMCFailure("switchToSpace: mc.display not found for display \(screenNumber)")
        return
      }

      guard let mcSpaces = MissionControlTree.spacesBar(of: mcDisplay) else {
        Self.reportMCFailure("switchToSpace: mc.spaces not found")
        return
      }

      guard let mcSpacesList = Self.axChildWithIdentifier(mcSpaces, identifier: "mc.spaces.list")
      else {
        Self.reportMCFailure("switchToSpace: mc.spaces.list not found")
        return
      }

      let children = Self.axChildren(mcSpacesList)
      guard spaceIndex >= 0 && spaceIndex < children.count else {
        Self.reportMCFailure(
          "switchToSpace: space index \(spaceIndex) out of range (have \(children.count) spaces)")
        return
      }

      let spaceButton = children[spaceIndex]
      let tileTitle = Self.axStringAttribute(spaceButton, name: "AXTitle") ?? "?"
      Diagnostics.log(
        "space-switch",
        "mc-tile-press display=\(screenNumber) index=\(spaceIndex)/\(children.count) title=\"\(tileTitle)\" before=\(before.map { String($0.id) } ?? "?")"
      )
      let pressResult = AXUIElementPerformAction(spaceButton, kAXPressAction as CFString)
      guard pressResult == .success else {
        Self.reportMCFailure(
          "switchToSpace: tile press failed (\(pressResult.rawValue)) index=\(spaceIndex)")
        return
      }
      logLandedSpace(afterTilePressOn: screenNumber, requestedIndex: spaceIndex, before: before)
    }
  }

  /// The display's current Space per CGS, resolved via space display UUIDs.
  private func currentSpace(onDisplayID displayID: CGDirectDisplayID) -> SpaceInfo? {
    getAllSpaces().first {
      $0.isCurrent && Self.displayIDForUUID($0.displayUUID) == displayID
    }
  }

  /// Polls CGS after an MC tile press and logs where the display actually
  /// landed. The press itself is async and unverified — this is the only
  /// record of whether the requested tile index matched reality, which is
  /// exactly what goes wrong when the bar and the CGS snapshot disagree
  /// (e.g. right after a space is created).
  private func logLandedSpace(
    afterTilePressOn displayID: CGDirectDisplayID, requestedIndex: Int, before: SpaceInfo?
  ) {
    let deadline = Date().addingTimeInterval(2.0)
    var landed = currentSpace(onDisplayID: displayID)
    while Date() < deadline, landed?.id == before?.id {
      Thread.sleep(forTimeInterval: 0.1)
      landed = currentSpace(onDisplayID: displayID)
    }
    guard let landed else {
      Diagnostics.log(
        "space-switch", "mc-tile-press landed=unknown (no current space resolved)")
      return
    }
    let desktops = getAllSpaces().filter {
      $0.type == .desktop && $0.displayUUID == landed.displayUUID
    }
    let landedIndex = desktops.firstIndex(where: { $0.id == landed.id }) ?? -1
    Diagnostics.log(
      "space-switch",
      "mc-tile-press landed=\(landed.id) uuid=\(landed.uuid) index=\(landedIndex) requested=\(requestedIndex) match=\(landedIndex == requestedIndex) changed=\(landed.id != before?.id)"
    )
  }

  // MARK: - Dock AX Helpers

  static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
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

  static func axChildWithIdentifier(
    _ element: AXUIElement, identifier: String
  ) -> AXUIElement? {
    for child in axChildren(element) {
      if axStringAttribute(child, name: "AXIdentifier") == identifier {
        return child
      }
    }
    return nil
  }

  static func axStringAttribute(_ element: AXUIElement, name: String) -> String? {
    var valueRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &valueRef) == .success else {
      return nil
    }
    return valueRef as? String
  }

  // MARK: - Window Activation

  /// Activates (brings to front) the window with the given CGWindowID.
  ///
  /// Uses the same approach as AltTab:
  /// 1. Resolve the target window's owning process
  /// 2. Verify AX trust and pre-switch a uniquely mapped off-Space desktop
  ///    with DockSwipe
  /// 3. Find the target window's AXUIElement via standard or brute-force lookup
  ///    (kAXWindowsAttribute cannot see windows on other Spaces)
  /// 4. `_SLPSSetFrontProcessWithOptions` and `SLPSPostEventRecordTo` — target
  ///    the specific CGWindowID and synthesize key-window events
  /// 5. `AXUIElementPerformAction(kAXRaiseAction)` — z-order raise
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
    var spaceWakeFallbackTarget = spaceWakeFallbackTargetForActivation(windowID: windowID)

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

    if prepareInstantWindowActivation(windowID: windowID, timeout: 0.5) {
      spaceWakeFallbackTarget = nil
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

  // MARK: - Minimize Window

  /// Minimizes a window through Accessibility without activating it.
  /// Repeated requests are idempotent: an already-minimized window stays minimized.
  public func minimizeWindow(id windowID: Int) throws {
    let windows = getAllWindows()
    guard let window = windows.first(where: { $0.id == windowID }) else {
      throw WindowActivationError.windowNotFound(windowID: windowID)
    }

    if window.pid == selfPID {
      guard let appWindow = NSApp.windows.first(where: { $0.windowNumber == windowID }) else {
        throw WindowActivationError.windowNotFound(windowID: windowID)
      }
      if !appWindow.isMiniaturized {
        appWindow.miniaturize(nil)
      }
      return
    }

    guard AXIsProcessTrusted() else {
      throw WindowActivationError.accessibilityNotTrusted
    }

    performAXMinimize(windowID: windowID, pid: pid_t(window.pid))
  }

  private func performAXMinimize(windowID: Int, pid: pid_t) {
    let targetCGWindowID = CGWindowID(windowID)

    DispatchQueue.global(qos: .userInteractive).async { [self] in
      guard
        let axWindow = findAXWindowStandard(pid: pid, targetCGWindowID: targetCGWindowID)
          ?? findAXWindowBruteForce(pid: pid, targetCGWindowID: targetCGWindowID)
      else {
        Diagnostics.log("minimize-window", "windowID=\(windowID) AX element not found")
        return
      }

      var minimizedRef: CFTypeRef?
      if AXUIElementCopyAttributeValue(
        axWindow, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
        minimizedRef as? Bool == true
      {
        return
      }

      let result = AXUIElementSetAttributeValue(
        axWindow, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
      if result != .success {
        Diagnostics.log(
          "minimize-window",
          "windowID=\(windowID) kAXMinimizedAttribute write failed (\(result.rawValue))")
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

    performAXClose(windowID: windowID, pid: pid_t(window.pid))
  }

  /// Presses the window's AX close button on a background queue and reports
  /// whether the press was delivered. Confirmed closes are tombstoned so the
  /// window disappears from enumeration even on a non-current Space (where
  /// the window server keeps listing it and AX can't be consulted).
  func performAXClose(
    windowID: Int, pid: pid_t, completion: ((Bool) -> Void)? = nil
  ) {
    guard AXIsProcessTrusted() else {
      completion?(false)
      return
    }
    let targetCGWindowID = CGWindowID(windowID)

    DispatchQueue.global(qos: .userInteractive).async { [self] in
      guard
        let axWindow = findAXWindowStandard(pid: pid, targetCGWindowID: targetCGWindowID)
          ?? findAXWindowBruteForce(pid: pid, targetCGWindowID: targetCGWindowID)
      else {
        Diagnostics.log("close-window", "windowID=\(windowID) AX element not found")
        completion?(false)
        return
      }

      var closeButtonRef: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(
          axWindow, kAXCloseButtonAttribute as CFString, &closeButtonRef
        ) == .success,
        let closeButton = closeButtonRef
      else {
        Diagnostics.log("close-window", "windowID=\(windowID) close button not found")
        completion?(false)
        return
      }

      let result = AXUIElementPerformAction(
        closeButton as! AXUIElement, kAXPressAction as CFString)
      if result == .success {
        markWindowClosed(id: windowID)
      } else {
        Diagnostics.log(
          "close-window", "windowID=\(windowID) kAXPressAction failed (\(result.rawValue))")
      }
      completion?(result == .success)
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
    let mcSpaces: AXUIElement
    let mcSpacesList: AXUIElement

    /// All window thumbnail buttons currently shown in Mission Control.
    var windowButtons: [AXUIElement] { MissionControlTree.windowThumbnails(of: mcDisplay) }

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

    guard let tree = awaitMissionControlTree(dockElement: dockElement, timeout: 2.0) else {
      print("openMissionControlContext: Mission Control AX tree not found")
      return nil
    }

    // Wait for MC animation and AX tree to fully populate
    Thread.sleep(forTimeInterval: 0.5)

    // Find mc.display (match by screen number if provided, or use first/only)
    let mcDisplay = screenNumber.map(tree.display(matching:)) ?? tree.displays.first
    guard let mcDisplay else {
      print("openMissionControlContext: mc.display not found")
      return nil
    }

    guard let mcSpaces = MissionControlTree.spacesBar(of: mcDisplay),
      let mcSpacesList = axChildWithIdentifier(mcSpaces, identifier: "mc.spaces.list")
    else {
      print("openMissionControlContext: mc.spaces/mc.spaces.list not found")
      return nil
    }

    return MissionControlContext(
      mcGroup: tree.root, mcDisplay: mcDisplay, mcSpaces: mcSpaces, mcSpacesList: mcSpacesList)
  }

  // MARK: - Display Focus

  /// Establishes display focus without clicking through an application window.
  /// Single-display restores need no extra focus action after switching Spaces.
  public func focusDisplayForWorkspace(spaceID: UInt64) throws {
    let allSpaces = getAllSpaces()
    let displayCount = Set(allSpaces.map(\.displayUUID)).count
    guard displayCount > 1 else { return }
    let focusedSpaces =
      WindowResizer.focusedWindowID().map {
        dataSource.fetchSpacesForWindow(Int($0.windowID))
      } ?? []
    guard
      Self.workspaceDisplayNeedsFocus(
        displayCount: displayCount,
        focusedWindowSpaceIDs: focusedSpaces, targetSpaceID: spaceID)
    else { return }

    // Activate an actual workspace window rather than clicking an arbitrary point
    // inside it. The restorer verifies Space membership again after focus settles.
    if let window = getAllWindows().first(where: { $0.spaceIDs == [spaceID] }) {
      try activateWindow(id: window.id)
      return
    }

    guard let space = allSpaces.first(where: { $0.id == spaceID }),
      let screenNumber = Self.displayIDForUUID(space.displayUUID)
    else { throw WorkspaceRestorerError.targetSpaceFocusFailed(spaceID: spaceID) }

    // Find the NSScreen matching this display
    guard
      let screen = NSScreen.screens.first(where: {
        let desc = $0.deviceDescription
        return (desc[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
          == screenNumber
      })
    else { throw WorkspaceRestorerError.targetSpaceFocusFailed(spaceID: spaceID) }

    // Only an exposed desktop point is safe. Ignore our own click-through overlay
    // and desktop-layer windows, but count other visible windows as obstacles.
    let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
    let visible = screen.visibleFrame
    let frame = CGRect(
      x: visible.minX, y: primaryHeight - visible.maxY,
      width: visible.width, height: visible.height)
    var obstacles: [CGRect] = []
    for entry in dataSource.fetchOnScreenWindowList() {
      if (entry[kCGWindowOwnerPID as String] as? Int)
        == Int(ProcessInfo.processInfo.processIdentifier)
      {
        continue
      }
      if let layer = entry[kCGWindowLayer as String] as? Int, layer < 0 { continue }
      guard let bounds = Self.windowBounds(in: entry) else {
        throw WorkspaceRestorerError.targetSpaceFocusFailed(spaceID: spaceID)
      }
      obstacles.append(bounds)
    }
    guard let point = Self.workspaceDesktopFocusPoint(in: frame, occupiedBounds: obstacles) else {
      throw WorkspaceRestorerError.targetSpaceFocusFailed(spaceID: spaceID)
    }
    Self.postMouseClick(at: point)
  }

  static func workspaceDisplayNeedsFocus(
    displayCount: Int, focusedWindowSpaceIDs: [UInt64], targetSpaceID: UInt64
  ) -> Bool {
    displayCount > 1 && focusedWindowSpaceIDs != [targetSpaceID]
  }

  static func workspaceDesktopFocusPoint(in frame: CGRect, occupiedBounds: [CGRect]) -> CGPoint? {
    let inset = frame.insetBy(dx: 12, dy: 12)
    guard inset.width > 0, inset.height > 0 else { return nil }
    for y in [inset.minY, inset.maxY, inset.midY] {
      for x in [inset.minX, inset.maxX, inset.midX] {
        let point = CGPoint(x: x, y: y)
        if !occupiedBounds.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(point) }) {
          return point
        }
      }
    }
    return nil
  }

  /// Posts a click (mouseDown + mouseUp) at the given point.
  static func postMouseClick(at point: CGPoint) {
    if let down = makeSyntheticMouseEvent(type: .leftMouseDown, at: point, button: .left) {
      postTagged(down)
    }
    Thread.sleep(forTimeInterval: 0.05)
    if let up = makeSyntheticMouseEvent(type: .leftMouseUp, at: point, button: .left) {
      postTagged(up)
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

  /// Magic value stamped into `eventSourceUserData` on every synthetic mouse
  /// event Spaceballs posts. Real input devices never set this field, so a
  /// suppression tap (MouseInputBlocker) can pass Spaceballs's own drags
  /// through while consuming physical mouse input.
  public static let syntheticEventTag: Int64 = 0x5BACE

  /// A private source keeps Spaceballs's synthetic button state independent
  /// from the session's physical HID state. Without it, hardware movement
  /// arriving while Spaceballs holds a synthetic button can be interpreted as
  /// part of that drag before an event tap has a chance to distinguish it.
  private static let syntheticMouseEventSource: CGEventSource? = {
    guard let source = CGEventSource(stateID: .privateState) else { return nil }
    source.userData = syntheticEventTag
    source.setLocalEventsFilterDuringSuppressionState(
      [.permitLocalKeyboardEvents, .permitSystemDefinedEvents],
      state: .eventSuppressionStateRemoteMouseDrag)
    return source
  }()

  /// Builds an identifiable event from the shared private source. Keeping one
  /// source for the complete down/drag/up sequence preserves synthetic button
  /// state without sharing it with the user's mouse.
  static func makeSyntheticMouseEvent(
    type: CGEventType, at point: CGPoint, button: CGMouseButton
  ) -> CGEvent? {
    guard let source = syntheticMouseEventSource,
      let event = CGEvent(
        mouseEventSource: source,
        mouseType: type,
        mouseCursorPosition: point,
        mouseButton: button)
    else { return nil }
    event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
    return event
  }

  /// Tags a synthetic mouse event as Spaceballs-generated and posts it.
  private static func postTagged(_ event: CGEvent) {
    event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
    event.post(tap: .cghidEventTap)
  }

  /// Moves the cursor to a point without any button press (e.g. to hover-expand
  /// Mission Control's spaces bar).
  static func postMouseMove(at point: CGPoint) {
    if let move = makeSyntheticMouseEvent(type: .mouseMoved, at: point, button: .left) {
      postTagged(move)
    }
  }

  /// Moves the cursor to a point, pauses, then presses mouseDown to grab.
  static func postMouseMoveAndGrab(at point: CGPoint) {
    postMouseMove(at: point)
    Thread.sleep(forTimeInterval: 0.05)

    if let down = makeSyntheticMouseEvent(type: .leftMouseDown, at: point, button: .left) {
      postTagged(down)
    }
    Thread.sleep(forTimeInterval: 0.1)
  }

  /// Posts a single mouseDragged event (mouse must already be down).
  static func postMouseDragEvent(at point: CGPoint) {
    if let drag = makeSyntheticMouseEvent(type: .leftMouseDragged, at: point, button: .left) {
      postTagged(drag)
    }
  }

  /// Posts mouseDragged events in steps from one point to another (mouse must already be down).
  static func postMouseDragToPoint(
    from: CGPoint, to: CGPoint, steps: Int = 15, stepDelay: TimeInterval = 0.008
  ) {
    for i in 1...steps {
      let t = CGFloat(i) / CGFloat(steps)
      let point = CGPoint(
        x: from.x + (to.x - from.x) * t,
        y: from.y + (to.y - from.y) * t
      )
      postMouseDragEvent(at: point)
      Thread.sleep(forTimeInterval: stepDelay)
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
    if let up = makeSyntheticMouseEvent(type: .leftMouseUp, at: point, button: .left) {
      postTagged(up)
    }
  }

  // MARK: - Window Move

  /// Total time budget for a direct (AX frame write) window move: the write,
  /// the Space-membership + frame verification, the stability hold and the
  /// final race-guard read all share it. On expiry the move falls back to the
  /// Mission Control drag, so a silently refusing app costs at most this long.
  public var directMoveDeadline: TimeInterval = 1.0

  /// Test seam: stands in for both legs of a window move so routing and
  /// fallback can be asserted without AX or Mission Control. `nil` → `self`.
  var windowMoveExecutorOverride: (any WindowMoveExecuting)?

  /// Test seam: visible frames (global CG coordinates) by CGS display UUID.
  /// Defaults to live NSScreen geometry.
  var displayVisibleFramesProvider: () -> [String: CGRect] = {
    SpaceManager.currentDisplayVisibleFrames()
  }

  /// Moves a window to a different Space.
  ///
  /// When the window's Space and the target Space are both visible (each is
  /// the current Space on a different display) the window is relocated
  /// directly with an AX position write — the same mechanism the resize grid
  /// uses to cycle a window between displays — verified through CGS, and
  /// Mission Control is never opened. Every other case, and any direct attempt
  /// that fails verification, activates the window, opens Mission Control and
  /// simulates a drag to the target space. Routing is `WindowMovePlanner`.
  ///
  /// - Parameters:
  ///   - windowID: CGWindowID of the window to move.
  ///   - targetSpaceID: ManagedSpaceID of the destination space.
  ///   - activateAfterMove: bring the moved window to front afterwards. When
  ///     off, the user's current Spaces and focus are left untouched.
  /// - Throws: `WindowActivationError` if the window can't be found or activated.
  /// - Returns: `true` if the window was moved or was already on the target Space.
  @discardableResult
  public func moveWindowToSpace(
    windowID: Int, targetSpaceID: UInt64, activateAfterMove: Bool = true
  ) throws -> Bool {
    let token = Diagnostics.beginTiming(
      "move-space", "moveWindowToSpace",
      extras: ["windowID": "\(windowID)", "targetSpace": "\(targetSpaceID)"])
    // 1. Look up the window in the raw window list.
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

    // 2. Resolve the target Space.
    let allSpaces = getAllSpaces()
    guard allSpaces.contains(where: { $0.id == targetSpaceID }) else {
      Diagnostics.endTiming(token, outcome: "target-space-not-found")
      print("moveWindowToSpace: space \(targetSpaceID) not found")
      return false
    }
    let sourceSpaceIDs = dataSource.fetchSpacesForWindow(windowID)
    let executor: any WindowMoveExecuting = windowMoveExecutorOverride ?? self

    // 3. Both Spaces visible? Then a plain frame write moves the window —
    //    no activation, no Mission Control, no sleeps.
    let route = WindowMovePlanner.route(
      spaces: allSpaces, windowSpaceIDs: sourceSpaceIDs, targetSpaceID: targetSpaceID,
      windowBounds: Self.windowBounds(in: entry),
      windowIsOnscreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false,
      displayVisibleFrames: displayVisibleFramesProvider())
    var directFallbackReason: String?
    switch route {
    case .alreadyOnTarget:
      Diagnostics.endTiming(token, outcome: "already-on-target")
      return true
    case .direct(let targetFrame):
      guard let rawPID = entry[kCGWindowOwnerPID as String] as? Int else {
        directFallbackReason = "pid-unknown"
        break
      }
      Diagnostics.log(
        "move-space",
        "route=direct title=\(Diagnostics.titleForLogging(windowTitle)) → space \(targetSpaceID) frame=\(Self.frameString(targetFrame))"
      )
      let result = executor.performDirectWindowMove(
        DirectWindowMoveRequest(
          windowID: windowID, pid: pid_t(rawPID), targetSpaceID: targetSpaceID,
          targetFrame: targetFrame, activateAfterMove: activateAfterMove,
          deadline: directMoveDeadline))
      switch result {
      case .moved(let focused, let membershipVerified, let sizePreserved):
        var outcome = "direct"
        if !membershipVerified { outcome += "-membership-unverified" }
        if !sizePreserved { outcome += "-size-changed" }
        if focused == false { outcome += "-focus-unverified" }
        Diagnostics.endTiming(token, outcome: outcome)
        return true
      case .failed(let reason):
        // The window did not provably move, so the drag is still safe to run.
        directFallbackReason = reason
      }
    case .missionControl(let reason):
      Diagnostics.log("move-space", "route=mission-control reason=\(reason)")
    }
    if let directFallbackReason {
      Diagnostics.log(
        "move-space", "direct-fallback:\(directFallbackReason) — using Mission Control")
    }

    // A launch or delayed frame write may have placed the window since routing.
    // Recheck before dispatching the fallback, not only before the direct attempt.
    if dataSource.fetchSpacesForWindow(windowID).contains(targetSpaceID) {
      Diagnostics.endTiming(token, outcome: "already-on-target-before-drag")
      return true
    }

    // 4. Mission Control drag.
    let moved = try executor.performMissionControlWindowMove(
      MissionControlWindowMoveRequest(
        windowID: windowID, windowTitle: windowTitle, targetSpaceID: targetSpaceID,
        activateAfterMove: activateAfterMove))
    let fallbackPrefix = directFallbackReason.map { "direct-fallback:\($0):" } ?? ""
    Diagnostics.endTiming(
      token, outcome: "\(fallbackPrefix)mc-drag:\(moved ? "moved" : "failed")")
    return moved
  }

  /// The Mission Control leg of `moveWindowToSpace`: activate the window
  /// (switching to its Space), open Mission Control, drag its thumbnail onto
  /// the target space's tile, then re-activate it — or, for a no-activate
  /// move, put the user back on the Space they were viewing.
  func performMissionControlWindowMove(
    _ request: MissionControlWindowMoveRequest
  ) throws -> Bool {
    let windowID = request.windowID
    let activateAfterMove = request.activateAfterMove
    // A failed direct attempt may have spent up to a second; plan the drag
    // from a fresh Spaces snapshot, not the one routing used.
    let allSpaces = getAllSpaces()
    guard let targetSpace = allSpaces.first(where: { $0.id == request.targetSpaceID }) else {
      Diagnostics.log("move-space", "target space \(request.targetSpaceID) vanished before drag")
      print("moveWindowToSpace: space \(request.targetSpaceID) not found")
      return false
    }

    // 1. Resolve the target space's "Desktop N" label (what MC shows).
    //    MC uses global numbering across all displays, not per-display ordinals.
    let allDesktopSpaces = allSpaces.filter { $0.type == .desktop }
    guard let ordinalIndex = allDesktopSpaces.firstIndex(where: { $0.id == targetSpace.id })
    else {
      Diagnostics.log("move-space", "no-ordinal for space \(targetSpace.id)")
      print("moveWindowToSpace: could not determine ordinal for space \(targetSpace.id)")
      return false
    }
    let targetSpaceTitle = "Desktop \(ordinalIndex + 1)"
    Diagnostics.log(
      "move-space",
      "title=\(Diagnostics.titleForLogging(request.windowTitle)) → \(targetSpaceTitle) targetDisplay=\(targetSpace.displayUUID)"
    )

    // 2. Activate the window to switch to its space.
    // When the window is already on a current Space there is no space-switch
    // animation to wait out — only a brief settle for the activation itself.
    let currentSpaceIDs = Set(allSpaces.filter(\.isCurrent).map(\.id))
    let sourceSpaceIDs = dataSource.fetchSpacesForWindow(windowID)
    guard !sourceSpaceIDs.contains(targetSpace.id) else {
      Diagnostics.log("move-space", "window already on target before activation; skipping drag")
      return true
    }
    let needsSpaceSwitch = !sourceSpaceIDs.contains(where: { currentSpaceIDs.contains($0) })
    let sourceSpace = allSpaces.first(where: { sourceSpaceIDs.contains($0.id) })

    // For a no-activate move, remember the Space that was current on the
    // window's display before we switch away to grab it, so the user's view
    // can be restored afterwards.
    let originalCurrentSpaceID: UInt64? = {
      guard !activateAfterMove && needsSpaceSwitch, let sourceSpace else { return nil }
      return allSpaces.first(where: { $0.isCurrent && $0.displayUUID == sourceSpace.displayUUID })?
        .id
    }()

    try activateWindow(id: windowID)

    // 3. Wait for the space switch animation to complete.
    Thread.sleep(forTimeInterval: needsSpaceSwitch ? 0.8 : 0.25)

    // 4. Perform the MC drag. Pass target display so the space button is found
    //    on the correct display (supports cross-display moves), and source
    //    display so the thumbnail search trusts the window's own display first.
    let targetScreenNumber = Self.displayIDForUUID(targetSpace.displayUUID)
    let sourceScreenNumber = sourceSpace.flatMap { Self.displayIDForUUID($0.displayUUID) }
    let moved = moveWindowInMC(
      windowTitle: request.windowTitle, windowID: windowID, targetSpaceTitle: targetSpaceTitle,
      targetSpaceIndex: Self.perDisplayDesktopIndex(of: targetSpace.id, in: allSpaces),
      targetScreenNumber: targetScreenNumber, sourceScreenNumber: sourceScreenNumber,
      switchToTarget: activateAfterMove)

    if moved {
      if activateAfterMove {
        // 5. Activate the window again so it's in front on the target space.
        Thread.sleep(forTimeInterval: 0.3)
        try activateWindow(id: windowID)
      } else if let originalCurrentSpaceID {
        // 5b. No-activate: put the user back on the Space they were viewing
        // before the move switched away to grab the window. Best-effort —
        // the move itself already succeeded.
        Thread.sleep(forTimeInterval: 0.3)
        do {
          try switchToSpace(id: originalCurrentSpaceID)
        } catch {
          Diagnostics.log("move-space", "restore of original space failed: \(error)")
        }
      }
    }

    return moved
  }

  // MARK: - Direct Window Move (both Spaces visible)

  /// Live AX primitives for the direct move; tests substitute scripted ones.
  lazy var directMoveAXHooks = DirectMoveAXHooks(
    isAccessibilityTrusted: { Self.ensureAccessibilityTrusted() },
    setPosition: { [unowned self] pid, windowID, origin in
      self.liveSetAXPosition(pid: pid, windowID: windowID, origin: origin)
    },
    activateAndVerifyFocus: { [unowned self] windowID, pid in
      self.activateAndVerifyFocus(windowID: windowID, pid: pid)
    })

  /// Moves the window by writing its AX position, then verifies through CGS
  /// that WindowServer reassigned it to the target Space — what a manual
  /// cross-display drag does — and that the frame landed where planned with
  /// its size intact (`DirectMoveVerifier`). Only then, and only if asked, is
  /// the window activated, with focus verified as a hard postcondition through
  /// the exact oracle the resize grid uses, so a bare Cmd+Shift+D afterwards
  /// targets the moved window on its new display. Everything shares
  /// `request.deadline`; `.failed` is returned only while the window has not
  /// provably moved, so the caller can still fall back to Mission Control.
  func performDirectWindowMove(_ request: DirectWindowMoveRequest) -> DirectWindowMoveResult {
    let start = Date()
    let deadline = start.addingTimeInterval(request.deadline)
    let hooks = directMoveAXHooks

    guard hooks.isAccessibilityTrusted() else {
      return .failed(reason: "ax-not-trusted")
    }
    guard
      let writeAccepted = hooks.setPosition(
        request.pid, CGWindowID(request.windowID), request.targetFrame.origin)
    else {
      // Nothing was written, so nothing can have moved.
      return .failed(reason: "ax-element-not-found")
    }

    // Verify regardless of what the write reported: an AX call can return an
    // error (e.g. a messaging timeout) after the app has already started
    // applying it, and a window that is relocating must never be dragged.
    let verification = DirectMoveVerifier.verify(
      targetFrame: request.targetFrame, deadline: deadline,
      isOnTargetSpace: {
        dataSource.fetchSpacesForWindow(request.windowID).contains(request.targetSpaceID)
      },
      currentFrame: { windowBounds(forWindowID: request.windowID) })
    let sizePreserved: Bool
    switch verification {
    case .verified, .membershipLate, .frameOnly:
      // Size is never written by this path; a change here is AppKit clamping
      // a window larger than its new display, exactly as a manual drag would.
      let finalBounds = windowBounds(forWindowID: request.windowID)
      sizePreserved =
        finalBounds.map { DirectMoveVerifier.sizePreserved($0, request.targetFrame) } ?? true
      let sizeNote =
        finalBounds.map {
          sizePreserved
            ? "size-preserved" : "size-changed-by-app:\(Int($0.width))x\(Int($0.height))"
        } ?? "size-unknown"
      Diagnostics.log(
        "move-space",
        "direct moved windowID=\(request.windowID) writeAccepted=\(writeAccepted) verification=\(verification) \(sizeNote) in \(Int(Date().timeIntervalSince(start) * 1000))ms"
      )
    case .failed(let lastOnTarget, let lastFrame):
      let write = writeAccepted ? "verify-timeout" : "ax-set-position-refused"
      return .failed(
        reason:
          "\(write) member=\(lastOnTarget) frame=\(lastFrame.map(Self.frameString) ?? "?")")
    }
    let membershipVerified = verification != .frameOnly

    guard request.activateAfterMove else {
      return .moved(
        focused: nil, membershipVerified: membershipVerified, sizePreserved: sizePreserved)
    }
    let focused = hooks.activateAndVerifyFocus(request.windowID, request.pid)
    return .moved(
      focused: focused, membershipVerified: membershipVerified, sizePreserved: sizePreserved)
  }

  /// Resolves the window's AX element (standard lookup, then a short brute
  /// force) and writes its position. nil when no element was found.
  private func liveSetAXPosition(pid: pid_t, windowID: CGWindowID, origin: CGPoint) -> Bool? {
    guard
      let element = findAXWindowStandard(pid: pid, targetCGWindowID: windowID)
        ?? findAXWindowBruteForceResult(pid: pid, targetCGWindowID: windowID, timeout: 0.25)
        .element
    else { return nil }
    return WindowResizer.setAXPosition(element, origin)
  }

  /// Activates the window and verifies it became the window a resize-grid
  /// action would target — `WindowResizer.focusedWindowID()`: the frontmost
  /// application (NSWorkspace) must be the window's process and that app's AX
  /// focused window must be this CGWindowID — retrying the activation once.
  /// Returns whether focus was verified; the move itself is already done
  /// either way.
  private func activateAndVerifyFocus(windowID: Int, pid: pid_t) -> Bool {
    let attemptBudget: TimeInterval = 0.3
    let expected = CGWindowID(windowID)
    for attempt in 1...2 {
      do {
        try activateWindow(id: windowID)
      } catch {
        Diagnostics.log(
          "move-space", "direct activation failed attempt=\(attempt): \(error)")
        return false
      }
      let attemptDeadline = Date().addingTimeInterval(attemptBudget)
      while Date() < attemptDeadline {
        if let focused = WindowResizer.focusedWindowID(), focused.pid == pid,
          focused.windowID == expected
        {
          Diagnostics.log("move-space", "direct focus verified attempt=\(attempt)")
          return true
        }
        Thread.sleep(forTimeInterval: 0.025)
      }
    }
    let focused = WindowResizer.focusedWindowID()
    Diagnostics.log(
      "move-space",
      "direct focus unverified windowID=\(windowID) pid=\(pid) focused=\(focused.map { "\($0.windowID)@\($0.pid)" } ?? "none")"
    )
    return false
  }

  /// Visible frame (menu bar and Dock excluded) of every display in global CG
  /// coordinates, keyed by CGS display UUID.
  static func currentDisplayVisibleFrames() -> [String: CGRect] {
    var frames: [String: CGRect] = [:]
    for screen in NSScreen.screens {
      guard let uuid = spaceballsDisplayUUID(for: screen) else { continue }
      frames[uuid] = CGRect(
        origin: spaceballsAXOrigin(of: screen), size: screen.visibleFrame.size)
    }
    return frames
  }

  private static func frameString(_ rect: CGRect) -> String {
    "(\(Int(rect.minX)),\(Int(rect.minY)))/\(Int(rect.width))x\(Int(rect.height))"
  }

  /// Picks the Mission Control thumbnail matching `windowTitle` from
  /// per-display title lists. `displayTitles[0]` must be the display showing
  /// the window's own space when known — its thumbnails are trusted first.
  ///
  /// An exact title match wins wherever it appears (earlier displays break
  /// ties). Only when no exact match exists is a case-insensitive substring
  /// match accepted, and only unambiguously: unique on the source display,
  /// else unique across all displays. An ambiguous substring must never
  /// grab another app's window — a wrong match drags a bystander window
  /// between spaces.
  static func matchWindowThumbnail(
    displayTitles: [[String?]], windowTitle: String
  ) -> (display: Int, index: Int)? {
    for (display, titles) in displayTitles.enumerated() {
      if let index = titles.firstIndex(where: { $0 == windowTitle }) {
        return (display, index)
      }
    }

    var matches: [(display: Int, index: Int)] = []
    for (display, titles) in displayTitles.enumerated() {
      for (index, title) in titles.enumerated()
      where title?.localizedCaseInsensitiveContains(windowTitle) == true {
        matches.append((display, index))
      }
    }
    let onSourceDisplay = matches.filter { $0.display == 0 }
    if onSourceDisplay.count == 1 { return onSourceDisplay[0] }
    if onSourceDisplay.isEmpty && matches.count == 1 { return matches[0] }
    return nil
  }

  /// Moves a window to a different Space by simulating a drag in Mission Control.
  ///
  /// Opens Mission Control, searches ALL displays for the window thumbnail and
  /// target space button (supporting cross-display moves), initiates a drag,
  /// and drops the window on the target space.
  ///
  /// - Parameters:
  ///   - windowTitle: Substring to match against MC window thumbnail titles.
  ///   - windowID: The window's CGWindowID; wins over the title wherever MC
  ///     exposes thumbnails' `wid` (macOS 27+).
  ///   - targetSpaceTitle: Expected title of the target space (e.g., "Desktop 2"),
  ///     derived from CGS global order; the label used when the target tile can't
  ///     be located by index.
  ///   - targetSpaceIndex: The target space's index among its display's desktop
  ///     tiles. With `targetScreenNumber`, locates the tile without trusting the
  ///     CGS-derived title (MC titles a display's only desktop just "Desktop").
  ///   - targetScreenNumber: Screen number of the display containing the target space.
  ///   - sourceScreenNumber: Screen number of the display showing the window's
  ///     space; its thumbnails are searched first so a similarly-titled window
  ///     on another display cannot shadow the real one.
  ///   - verbose: Print diagnostic output.
  ///   - switchToTarget: When true (default), the target space button is pressed
  ///     after the drop, switching to it (and dismissing MC). When false, MC is
  ///     dismissed without a press so the current Space stays put.
  /// - Returns: `true` if the drag completed, `false` on any error.
  @discardableResult
  public func moveWindowInMC(
    windowTitle: String, windowID: Int? = nil, targetSpaceTitle: String,
    targetSpaceIndex: Int? = nil, targetScreenNumber: CGDirectDisplayID? = nil,
    sourceScreenNumber: CGDirectDisplayID? = nil, verbose: Bool = false,
    switchToTarget: Bool = true
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

      guard let tree = Self.awaitMissionControlTree(dockElement: dockElement, timeout: 2.0)
      else {
        Self.reportMCFailure("moveWindowInMC: Mission Control AX tree not found")
        Self.dismissMissionControlIfPresent(dockElement: dockElement)
        return
      }

      Thread.sleep(forTimeInterval: 0.5)

      // Search for the window thumbnail — by CGWindowID where MC exposes it,
      // else by title: the window's own display first, exact matches on ANY
      // display before any substring match. A substring match alone is
      // trusted only when unambiguous, so a similarly-titled window visible
      // on another display (e.g. a terminal at the project path) can't get
      // grabbed and dragged instead of the real one.
      let thumbnailSearchOrder = tree.displays(preferring: sourceScreenNumber)
      let buttonsPerDisplay = thumbnailSearchOrder.map(MissionControlTree.windowThumbnails(of:))
      let thumbnailsPerDisplay = buttonsPerDisplay.map { buttons in
        buttons.map { button in
          ThumbnailDescriptor(
            title: Self.axStringAttribute(button, name: "AXTitle"),
            windowID: MissionControlTree.windowID(of: button))
        }
      }
      guard
        let match = Self.matchWindowThumbnail(
          displays: thumbnailsPerDisplay, windowTitle: windowTitle, windowID: windowID)
      else {
        Self.reportMCFailure(
          "moveWindowInMC: No window matching \"\(Diagnostics.titleForLogging(windowTitle))\" on any display"
        )
        Self.dismissMissionControl()
        return
      }
      let windowButton = buttonsPerDisplay[match.display][match.index]
      guard let windowCenter = Self.axCenter(windowButton) else {
        Self.reportMCFailure("moveWindowInMC: matched window has no readable position")
        Self.dismissMissionControl()
        return
      }

      if verbose {
        let title = Self.axStringAttribute(windowButton, name: "AXTitle") ?? "?"
        print("  Window: \"\(title)\" at \(windowCenter)")
      }

      // Locate the target tile: by per-display index on the target display's
      // bar when known (MC labels tiles in display-arrangement order — and a
      // display's only desktop just "Desktop" — so a CGS-derived "Desktop N"
      // is only a guess), else the first bar holding a tile with that title.
      // The tile's own title is what the drag tracks: tiles shift when the
      // drag enters the bar (placeholder insertion), so an index goes stale.
      var barList: AXUIElement?
      var tileTitle = targetSpaceTitle
      if let targetSpaceIndex, let targetScreenNumber,
        let display = tree.display(matching: targetScreenNumber),
        let list = MissionControlTree.spacesList(of: display)
      {
        let tiles = Self.axChildren(list)
        if tiles.indices.contains(targetSpaceIndex),
          let title = Self.axStringAttribute(tiles[targetSpaceIndex], name: "AXTitle")
        {
          barList = list
          tileTitle = title
          if title != targetSpaceTitle {
            Diagnostics.log(
              "move-space",
              "target tile index=\(targetSpaceIndex) titled \"\(title)\", expected \"\(targetSpaceTitle)\""
            )
          }
        }
      }
      if barList == nil {
        for display in tree.displays(preferring: targetScreenNumber) {
          guard let list = MissionControlTree.spacesList(of: display) else { continue }
          if Self.axChildren(list).contains(where: {
            Self.axStringAttribute($0, name: "AXTitle") == targetSpaceTitle
          }) {
            barList = list
            break
          }
        }
      }

      guard let barList else {
        Self.reportMCFailure(
          "moveWindowInMC: Space \"\(targetSpaceTitle)\" not found on any display")
        Self.dismissMissionControl()
        return
      }

      // Grab and nudge to initiate drag. Hover, then hold the button a beat
      // before moving: macOS 27's Mission Control drops a grab that starts
      // moving immediately.
      Self.postMouseMove(at: windowCenter)
      Thread.sleep(forTimeInterval: 0.15)
      Self.postMouseMoveAndGrab(at: windowCenter)
      Thread.sleep(forTimeInterval: 0.25)
      let nudge = CGPoint(x: windowCenter.x, y: windowCenter.y - 15)
      Self.postMouseDragToPoint(from: windowCenter, to: nudge, steps: 6, stepDelay: 0.02)

      // Homing glide: one continuous motion that re-reads the tile's position
      // every few steps and bends toward the latest reading. The path heads
      // straight for the tile's pre-drag position; when the drag crosses into
      // the bar, MC expands it and shifts every tile, and the re-reads bend the
      // path onto the tile's new center. AX references are live, so re-reading
      // the bar's children reflects the current layout.
      // Aim at the tile's horizontal center on the BAR's vertical center
      // (`MissionControlTree.aimPoint`): a tile's AX frame is taller than the
      // bar and hangs below it, and macOS 27 reports tile positions as
      // centers, so the naive frame center lands on the tile's bottom-right
      // corner where the drop is refused.
      var targetButton: AXUIElement?
      let readTargetCenter: () -> CGPoint? = {
        guard
          let match = Self.axChildren(barList).first(where: {
            Self.axStringAttribute($0, name: "AXTitle") == tileTitle
          })
        else { return nil }
        targetButton = match
        return MissionControlTree.aimPoint(tile: match, in: barList)
      }
      let arrival = Self.homingDrag(
        from: nudge,
        stepLength: 20,
        read: readTargetCenter,
        move: { point in
          Self.postMouseDragEvent(at: point)
          Thread.sleep(forTimeInterval: 0.016)
        }
      )
      guard let arrival, let targetButton else {
        Self.reportMCFailure("moveWindowInMC: Space \"\(tileTitle)\" not found during drag")
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
      // Dwell over the tile with the button held before releasing — as the
      // space-tile drag does — with stationary drag events, not a bare
      // sleep, so the drag session stays alive until the drop.
      for _ in 0..<7 {
        Self.postMouseDragEvent(at: dropPoint)
        Thread.sleep(forTimeInterval: 0.05)
      }
      Diagnostics.log(
        "move-space", "drop tile=\"\(tileTitle)\" at (\(Int(dropPoint.x)),\(Int(dropPoint.y)))")
      Self.postMouseUp(at: dropPoint)

      Thread.sleep(forTimeInterval: 0.3)
      if switchToTarget {
        // Click the target space to switch to it (also dismisses MC)
        AXUIElementPerformAction(targetButton, kAXPressAction as CFString)
      } else {
        // Leave the current Space as-is; just close Mission Control.
        Self.dismissMissionControl()
      }
      success = true
    }

    semaphore.wait()
    return success
  }

  // MARK: - Space Move via Mission Control

  /// Moves an entire Space to another display by simulating the Mission Control
  /// drag of its tile from the source display's spaces bar onto the destination
  /// display's bar.
  ///
  /// Mission Control will not let a display's active Space be dragged, so when
  /// the space is current its display is first switched to a sibling (verified
  /// via CGS, not a blind sleep). When the space is the only desktop on its
  /// display, a sibling is created there first — a display must always retain
  /// at least one space.
  ///
  /// By default the moved space is switched to after the move, making it the
  /// target display's active Space. Pass `activateAfterMove: false` for pure
  /// layout surgery that leaves both displays' current spaces unchanged.
  ///
  /// - Returns: `true` when CGS confirms the space now lives on the target display.
  /// - Throws: `SpaceMoveError` for any resolvable precondition failure.
  @discardableResult
  public func moveSpaceToDisplay(
    spaceID: UInt64, targetDisplayUUID: String, activateAfterMove: Bool = true
  ) throws -> Bool {
    let token = Diagnostics.beginTiming(
      "move-space-display", "moveSpaceToDisplay",
      extras: ["spaceID": "\(spaceID)", "targetDisplay": targetDisplayUUID])

    // Pure guards run before any AX interaction so they work headless.
    var outcome: SpaceMovePlanner.Outcome
    do {
      outcome = try SpaceMovePlanner.plan(
        spaceID: spaceID, targetDisplayUUID: targetDisplayUUID, spaces: getAllSpaces()
      ).get()
    } catch {
      Diagnostics.endTiming(token, outcome: "plan-rejected")
      throw error
    }

    guard Self.ensureAccessibilityTrusted() else {
      Diagnostics.endTiming(token, outcome: "ax-not-trusted")
      throw SpaceMoveError.accessibilityNotTrusted
    }

    // The only desktop space on its display can't be switched away from, so
    // create a sibling there first, then re-plan against the fresh space list
    // (the new space shifts the global "Desktop N" numbering and becomes the
    // pre-switch target).
    if case .createSiblingFirst(let displayUUID) = outcome {
      guard let screen = Self.displayIDForUUID(displayUUID) else {
        Diagnostics.endTiming(token, outcome: "source-display-unresolvable")
        throw SpaceMoveError.displayNotResolvable(displayUUID: displayUUID)
      }
      Diagnostics.log("move-space-display", "creating sibling space on \(displayUUID)")
      let beforeUUIDs = Set(getAllSpaces().map(\.uuid))

      let semaphore = DispatchSemaphore(value: 0)
      var createResult: Result<Int, SpaceCreateError> = .failure(.missionControlNotFound)
      createSpace(count: 1, screenNumber: screen) { result in
        createResult = result
        semaphore.signal()
      }
      semaphore.wait()

      let siblingAppeared =
        (try? createResult.get()) == 1
        && poll(timeout: 3.0) {
          !Self.newlyCreatedSpaces(before: beforeUUIDs, after: self.getAllSpaces()).isEmpty
        }
      guard siblingAppeared else {
        Diagnostics.endTiming(token, outcome: "sibling-create-failed")
        throw SpaceMoveError.spaceCreationFailed(displayUUID: displayUUID)
      }

      do {
        outcome = try SpaceMovePlanner.plan(
          spaceID: spaceID, targetDisplayUUID: targetDisplayUUID, spaces: getAllSpaces()
        ).get()
      } catch {
        Diagnostics.endTiming(token, outcome: "replan-rejected")
        throw error
      }
    }

    guard case .ready(let plan) = outcome else {
      Diagnostics.endTiming(token, outcome: "replan-not-ready")
      throw SpaceMoveError.spaceCreationFailed(displayUUID: targetDisplayUUID)
    }

    guard let sourceScreen = Self.displayIDForUUID(plan.sourceDisplayUUID) else {
      Diagnostics.endTiming(token, outcome: "source-display-unresolvable")
      throw SpaceMoveError.displayNotResolvable(displayUUID: plan.sourceDisplayUUID)
    }
    guard let targetScreen = Self.displayIDForUUID(plan.targetDisplayUUID) else {
      Diagnostics.endTiming(token, outcome: "target-display-unresolvable")
      throw SpaceMoveError.displayNotResolvable(displayUUID: plan.targetDisplayUUID)
    }

    // MC refuses to drag the active space, so switch its display to the
    // sibling first, and verify via CGS that the switch actually landed —
    // switchToSpace is fire-and-forget.
    if let preSwitch = plan.preSwitch {
      Diagnostics.log(
        "move-space-display",
        "pre-switch display \(plan.sourceDisplayUUID) to space \(preSwitch.toSpaceID)")
      do {
        try activateSpace(id: preSwitch.toSpaceID)
      } catch {
        Diagnostics.log("move-space-display", "pre-switch activation failed: \(error)")
      }
      let switched = poll(timeout: 3.0) {
        self.getAllSpaces().first(where: { $0.id == spaceID })?.isCurrent == false
      }
      guard switched else {
        Diagnostics.endTiming(token, outcome: "pre-switch-failed")
        throw SpaceMoveError.preSwitchFailed(spaceID: spaceID)
      }
      // Let the space-switch animation finish before reopening MC.
      Thread.sleep(forTimeInterval: 0.8)
    }

    let moved = moveSpaceInMC(
      sourceSpaceIndex: plan.sourceSpaceIndex,
      sourceScreenNumber: sourceScreen,
      targetScreenNumber: targetScreen)
    guard moved else {
      Diagnostics.endTiming(token, outcome: "drag-failed")
      return false
    }

    // The drop animates before CGS reflects the new topology — poll rather
    // than trusting the drag's own success.
    let verified = poll(timeout: 2.0) {
      self.getAllSpaces().first(where: { $0.id == spaceID })?.displayUUID == targetDisplayUUID
    }

    // Make the moved space the target display's active Space (activating a
    // window on it when it has one — no Mission Control round). Best-effort:
    // the move itself already succeeded, so a failed switch only logs.
    if verified && activateAfterMove {
      do {
        try activateSpace(id: spaceID)
      } catch {
        Diagnostics.log("move-space-display", "post-move activation failed: \(error)")
      }
    }

    Diagnostics.endTiming(token, outcome: verified ? "moved" : "not-verified")
    return verified
  }

  /// Polls `condition` every `interval` until it holds or `timeout` elapses.
  func poll(
    interval: TimeInterval = 0.15, timeout: TimeInterval, until condition: () -> Bool
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      Thread.sleep(forTimeInterval: interval)
    }
    return condition()
  }

  /// Drags a Space tile from one display's Mission Control spaces bar onto
  /// another display's bar.
  ///
  /// Mirrors `moveWindowInMC`, with space-tile specifics: the source bar is
  /// hovered first so it expands (tile frames differ pre/post expansion), the
  /// nudge pulls DOWN out of the bar (in-bar motion reads as reordering), and
  /// the homing target is the destination bar's append position past its last
  /// tile rather than a tile center. No tile is pressed afterwards — that
  /// would switch the destination display's active space.
  ///
  /// The tile is located by INDEX among the source bar's desktop tiles, not by
  /// "Desktop N" title: MC numbers desktops in display-arrangement order
  /// (built-in first) while CGS enumerates displays in an order that can vary
  /// between calls, so a CGS-derived global title is unreliable. Per-display
  /// CGS space order does match the bar's tile order (the same invariant
  /// `switchToSpace(spaceIndex:screenNumber:)` relies on).
  ///
  /// - Parameters:
  ///   - sourceSpaceIndex: Position of the space among its display's desktop
  ///     tiles (0-based).
  ///   - sourceScreenNumber: Display currently owning the space.
  ///   - targetScreenNumber: Display to move the space to.
  ///   - verbose: Print diagnostic output.
  /// - Returns: `true` if the drag completed, `false` on any error.
  @discardableResult
  public func moveSpaceInMC(
    sourceSpaceIndex: Int, sourceScreenNumber: CGDirectDisplayID,
    targetScreenNumber: CGDirectDisplayID, verbose: Bool = false
  ) -> Bool {
    !moveSpacesInMCBatch(
      [
        SpaceTileDrag(
          sourceSpaceIndex: sourceSpaceIndex,
          sourceScreenNumber: sourceScreenNumber,
          targetScreenNumber: targetScreenNumber)
      ],
      verbose: verbose
    ).isEmpty
  }

  /// Performs several space-tile drags in ONE Mission Control session: open
  /// once, drag each, dismiss once. Returns the indices into `drags` of the
  /// drags that completed. Drags sharing a source display must be ordered by
  /// DESCENDING sourceSpaceIndex — completed removals then never shift the
  /// tile indices of drags still to run. The drop aims at the target bar's
  /// frame center, so a target bar gaining tiles never goes stale.
  /// `resolveSourceIndex` (optional) re-derives a drag's tile index just
  /// before its grab — completed drops shift the remaining tiles, so a
  /// fresh read beats the planned index; returning nil skips the drag.
  public func moveSpacesInMCBatch(
    _ drags: [SpaceTileDrag], verbose: Bool = false,
    resolveSourceIndex: ((_ dragIndex: Int) -> Int?)? = nil
  ) -> [Int] {
    guard !drags.isEmpty else { return [] }
    guard AXIsProcessTrusted() else {
      Self.reportMCFailure("moveSpacesInMCBatch: Accessibility not trusted")
      return []
    }

    let semaphore = DispatchSemaphore(value: 0)
    var completed: [Int] = []
    let timing = moveTiming

    DispatchQueue.global(qos: .userInteractive).async {
      defer { semaphore.signal() }

      guard
        let dockApp = NSRunningApplication.runningApplications(
          withBundleIdentifier: "com.apple.dock"
        ).first
      else {
        Self.reportMCFailure("moveSpacesInMCBatch: Dock not running")
        return
      }

      let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)

      // A lingering Mission Control (pre-switch tile press still closing, a
      // failed earlier attempt, or user-opened) would turn the awake TOGGLE
      // into a dismissal — make sure it's fully gone, then open fresh.
      if Self.axChildWithIdentifier(dockElement, identifier: "mc") != nil {
        Self.dismissMissionControl()
        _ = Self.awaitMissionControlDismissed(timeout: 2.0)
        Thread.sleep(forTimeInterval: 0.5)
      }
      CoreDockSendNotification("com.apple.expose.awake" as CFString)

      guard let tree = Self.awaitMissionControlTree(dockElement: dockElement, timeout: 2.0)
      else {
        Self.reportMCFailure("moveSpacesInMCBatch: Mission Control AX tree not found")
        Self.dismissMissionControlIfPresent(dockElement: dockElement)
        return
      }

      Thread.sleep(forTimeInterval: 0.5)

      let allDisplays = tree.displays

      // One mc.display per physical display. Fewer than two means there is no
      // other bar to drop onto (single display, mirroring, or "Displays have
      // separate Spaces" disabled).
      guard allDisplays.count >= 2 else {
        Self.reportMCFailure("moveSpacesInMCBatch: need at least two displays in Mission Control")
        Self.dismissMissionControlIfPresent(dockElement: dockElement)
        return
      }

      func displayMatching(_ screen: CGDirectDisplayID) -> AXUIElement? {
        allDisplays.first { MissionControlTree.displayID(of: $0) == screen }
      }

      func spacesBar(of display: AXUIElement) -> AXUIElement? {
        MissionControlTree.spacesList(of: display)
      }

      for (dragIndex, drag) in drags.enumerated() {
        guard let sourceDisplay = displayMatching(drag.sourceScreenNumber),
          let sourceBar = spacesBar(of: sourceDisplay),
          let targetDisplay = displayMatching(drag.targetScreenNumber),
          let targetBar = spacesBar(of: targetDisplay)
        else {
          Self.reportMCFailure("moveSpacesInMCBatch: displays for drag \(dragIndex) not found")
          continue
        }
        let sourceIndex: Int? =
          resolveSourceIndex.map { $0(dragIndex) } ?? drag.sourceSpaceIndex
        guard let sourceIndex else {
          if verbose { print("moveSpacesInMCBatch: drag \(dragIndex) skipped") }
          continue
        }
        if Self.performSpaceTileDrag(
          sourceBar: sourceBar, targetBar: targetBar,
          sourceSpaceIndex: sourceIndex, dropSettle: timing.dropSettle,
          verbose: verbose)
        {
          completed.append(dragIndex)
        }
        // Short bridge toward the next grab; the grab's own settle handles
        // the tail of Mission Control's re-layout.
        Thread.sleep(forTimeInterval: timing.interDragPause)
      }
      Self.dismissMissionControlIfPresent(dockElement: dockElement)
    }

    semaphore.wait()
    return completed
  }

  /// Drags one space tile from `sourceBar` onto `targetBar` within an open
  /// Mission Control session. Does NOT open or dismiss Mission Control —
  /// that's the session owner's job.
  private static func performSpaceTileDrag(
    sourceBar: AXUIElement, targetBar: AXUIElement,
    sourceSpaceIndex: Int, dropSettle: TimeInterval, verbose: Bool
  ) -> Bool {
    // Locate the tile by index among the bar's desktop tiles (fullscreen
    // spaces show app-titled tiles in the same bar and don't count), then
    // capture its title for the drag re-reads — MC doesn't renumber tiles
    // mid-drag, so the title is a stable handle while frames shift.
    func desktopTiles(in bar: AXUIElement) -> [AXUIElement] {
      Self.axChildren(bar).filter {
        MissionControlTree.isDesktopTile(title: Self.axStringAttribute($0, name: "AXTitle"))
      }
    }

    let tiles = desktopTiles(in: sourceBar)
    guard sourceSpaceIndex >= 0 && sourceSpaceIndex < tiles.count,
      let spaceTileTitle = Self.axStringAttribute(
        tiles[sourceSpaceIndex], name: "AXTitle")
    else {
      Self.reportMCFailure(
        "moveSpaceInMC: tile index \(sourceSpaceIndex) out of range (have \(tiles.count) desktop tiles)"
      )
      return false
    }

    let readTileCenter: () -> CGPoint? = {
      Self.axChildren(sourceBar).first(where: {
        Self.axStringAttribute($0, name: "AXTitle") == spaceTileTitle
      }).flatMap { MissionControlTree.aimPoint(tile: $0, in: sourceBar) }
    }

    // Hover the source bar so it expands, then wait for the tile's frame to
    // settle — collapsed-bar frames are stale the moment expansion starts.
    guard let barCenter = Self.axCenter(sourceBar) else {
      Self.reportMCFailure("moveSpaceInMC: source bar frame unreadable")
      return false
    }
    Self.postMouseMove(at: barCenter)
    guard
      let grab = Self.awaitStablePoint(
        read: readTileCenter, delay: { Thread.sleep(forTimeInterval: 0.04) })
    else {
      Self.reportMCFailure("moveSpaceInMC: tile \"\(spaceTileTitle)\" not found in source bar")
      return false
    }

    if verbose { print("  Tile: \"\(spaceTileTitle)\" at \(grab.point)") }

    // Grab, then pull DOWN out of the bar to detach — small horizontal
    // motion inside the bar reads as reordering, not removal.
    Self.postMouseMoveAndGrab(at: grab.point)
    let nudge = CGPoint(x: grab.point.x, y: grab.point.y + 30)
    Self.postMouseDragToPoint(from: grab.point, to: nudge, steps: 3)

    // Home toward the CENTER of the destination bar's frame. Tiles are laid
    // out centered in the bar, so the frame center lands mid-row — a clean
    // insertion point well inside the bar. Tile coordinates are NOT used for
    // the aim: collapsed-state tiles can report frames above the bar (seen
    // on portrait displays), and a stale read overshoots to the display's
    // top edge where MC refuses the drop. The bar expands as the drag
    // approaches; re-reads bend the path onto the live frame.
    let readDropTarget: () -> CGPoint? = {
      guard let barPos = Self.axPosition(targetBar), let barSize = Self.axSize(targetBar)
      else { return nil }
      return CGPoint(x: barPos.x + barSize.width / 2, y: barPos.y + barSize.height / 2)
    }

    // Cross-display paths span thousands of points on large displays, so
    // stride much longer than the window-move glide (40) — the tile doesn't
    // need pixel-accurate tracking mid-flight, and homingDrag lands exactly
    // on the aim for the final step. The settle + dwell at the bar are
    // unchanged.
    let arrival = Self.homingDrag(
      from: nudge,
      stepLength: 160,
      read: readDropTarget,
      move: { point in
        Self.postMouseDragEvent(at: point)
        Thread.sleep(forTimeInterval: 0.008)
      }
    )
    guard let arrival else {
      Self.reportMCFailure("moveSpaceInMC: destination bar unreadable during drag")
      Self.postMouseUp(at: nudge)
      return false
    }

    if verbose { print("  Drop target at \(arrival)") }

    var dropPoint = arrival
    if let settled = Self.awaitStablePoint(
      read: readDropTarget, delay: { Thread.sleep(forTimeInterval: 0.04) }),
      abs(settled.point.x - dropPoint.x) > 2 || abs(settled.point.y - dropPoint.y) > 2
    {
      Self.postMouseDragToPoint(from: dropPoint, to: settled.point, steps: 4)
      dropPoint = settled.point
    }

    // Dwell over the destination bar with the button held before releasing.
    // An immediate drop can snap the tile back to its source display — MC
    // needs a beat with the tile hovering over the bar to accept the drop.
    // Stationary drag events (not a bare sleep) keep the drag session alive.
    for _ in 0..<7 {
      Self.postMouseDragEvent(at: dropPoint)
      Thread.sleep(forTimeInterval: 0.05)
    }
    Self.postMouseUp(at: dropPoint)

    // Brief tail so the drop registers before the caller's next grab or
    // dismissal — the drop itself commits on mouse-up, and the next grab's
    // awaitStablePoint adaptively rides out any remaining re-layout. The
    // session owner dismisses WITHOUT pressing any tile — pressing would
    // switch the destination display's active space.
    Thread.sleep(forTimeInterval: dropSettle)
    return true
  }

  /// Dismisses Mission Control only when its AX group is still present. The
  /// awake notification TOGGLES Mission Control, so firing it blind after a
  /// drop that already dismissed MC would re-open it.
  private static func dismissMissionControlIfPresent(dockElement: AXUIElement) {
    if axChildWithIdentifier(dockElement, identifier: "mc") != nil {
      dismissMissionControl()
    }
  }

  /// True when the Dock currently exposes a Mission Control AX group.
  static func missionControlPresent() -> Bool {
    guard
      let dockApp = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.dock"
      ).first
    else { return false }
    let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)
    return axChildWithIdentifier(dockElement, identifier: "mc") != nil
  }

  /// Polls until Mission Control's AX group disappears from the Dock.
  /// Sequencing guard for flows that must not send the awake TOGGLE while a
  /// previous Mission Control appearance is still closing.
  @discardableResult
  static func awaitMissionControlDismissed(timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !missionControlPresent() { return true }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return !missionControlPresent()
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
      guard
        let dockApp = NSRunningApplication.runningApplications(
          withBundleIdentifier: "com.apple.dock"
        ).first
      else {
        print("dumpMissionControlAXTree: Dock not running")
        semaphore.signal()
        return
      }
      let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)
      CoreDockSendNotification("com.apple.expose.awake" as CFString)
      guard let tree = Self.awaitMissionControlTree(dockElement: dockElement, timeout: 2.0)
      else {
        print("dumpMissionControlAXTree: Mission Control AX tree not found")
        Self.dismissMissionControlIfPresent(dockElement: dockElement)
        semaphore.signal()
        return
      }
      Thread.sleep(forTimeInterval: 0.5)

      let host = tree.root == tree.dockGroup ? "Dock" : "WindowManager"
      print("=== Mission Control AX Tree (hosted by \(host)) ===\n")
      Self.dumpAXElement(tree.root, indent: 0)
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
    var actionsRef: CFArray?
    let actions =
      AXUIElementCopyActionNames(element, &actionsRef) == .success
      ? (actionsRef as? [String]) ?? [] : []

    print(
      "\(prefix)[\(role)/\(subrole)] id=\(identifier) title=\"\(title)\" desc=\"\(desc)\""
        + " pos=\(posStr) size=\(sizeStr) children=\(children.count) actions=\(actions)")

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

  /// Moves to an off-Space window's unique desktop with a DockSwipe before
  /// activating it. Once CGS confirms the target is current, the ordinary
  /// SkyLight/AX activation no longer triggers macOS's slide animation.
  /// Returns false when the target is sticky/current/unsupported, the instant
  /// path declines, or WindowServer does not confirm the switch in time.
  func prepareInstantWindowActivation(
    windowID: Int, timeout: TimeInterval
  ) -> Bool {
    guard let target = spaceWakeFallbackTargetForActivation(windowID: windowID) else {
      return false
    }
    let spaces = getAllSpaces()
    let instantResult = instantSpaceSwitcher.switchToSpace(target, among: spaces)
    if case .declined(let reason) = instantResult {
      Diagnostics.log(
        "activate",
        "windowID=\(windowID) dock-swipe declined (\(reason)) targetSpaceID=\(target.id)")
    }
    guard instantResult == .switched else { return false }
    let switched = waitForCurrentSpace(target.id, timeout: timeout)
    Diagnostics.log(
      "activate",
      "windowID=\(windowID) path=dock-swipe targetSpaceID=\(target.id) verified=\(switched)")
    return switched
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

// MARK: - Window Move Executor Conformance

/// Production executor for both legs of `moveWindowToSpace`; tests swap in a
/// recorder via `windowMoveExecutorOverride`.
extension SpaceManager: WindowMoveExecuting {}
