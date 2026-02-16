import Cocoa
import SpacebarCore

// MARK: - Data Types

public struct SwitcherSection: Identifiable {
  public let id: UInt64  // space ID
  public let spaceUUID: String
  public let label: String
  public let isCurrent: Bool
  public var windows: [SwitcherRow]

  public init(
    id: UInt64, spaceUUID: String = "", label: String, isCurrent: Bool, windows: [SwitcherRow]
  ) {
    self.id = id
    self.spaceUUID = spaceUUID
    self.label = label
    self.isCurrent = isCurrent
    self.windows = windows
  }
}

public struct SwitcherRow: Identifiable {
  public let id: Int  // CGWindowID
  public let appName: String
  public let windowTitle: String
  public let appIcon: NSImage?
  public let pid: Int
  public let isSticky: Bool

  public init(
    id: Int, appName: String, windowTitle: String,
    appIcon: NSImage?, pid: Int, isSticky: Bool
  ) {
    self.id = id
    self.appName = appName
    self.windowTitle = windowTitle
    self.appIcon = appIcon
    self.pid = pid
    self.isSticky = isSticky
  }
}

// MARK: - ViewModel

public final class SwitcherViewModel: ObservableObject {
  @Published public var sections: [SwitcherSection] = []
  @Published public var searchText: String = ""
  @Published public var selectedRowID: Int?
  @Published public var settingsSelected: Bool = false

  public let spaceManager: SpaceManager
  public let spaceNameStore: SpaceNameStoring

  /// Persistent MRU history of space IDs, most recent first.
  /// Updated on each refresh() when the current space changes.
  private var spaceMRUHistory: [UInt64] = []

  /// Persistent MRU history of CGWindowIDs, most recently activated first.
  /// Updated when Spacebar activates a window via activateSelected().
  private var windowMRUHistory: [Int] = []

  /// Cache app icons by bundle identifier to avoid repeated lookups.
  private var iconCache: [pid_t: NSImage] = [:]

  public init(
    spaceManager: SpaceManager = SpaceManager(),
    spaceNameStore: SpaceNameStoring = SpaceNameStore()
  ) {
    self.spaceManager = spaceManager
    self.spaceNameStore = spaceNameStore
  }

  // MARK: - Refresh

  public func refresh() {
    let (spaces, rawWindowMap) = spaceManager.windowsBySpace()
    let allWindows = spaceManager.getAllWindows()

    // Reorder windows within each space by MRU history.
    var windowMap = rawWindowMap
    for (spaceID, windows) in windowMap {
      windowMap[spaceID] = reorderByMRU(windows)
    }

    // Determine the current space on the focused display.
    // With multiple displays, each has its own current space (from CGS isCurrent).
    // NSScreen.main identifies which display has keyboard focus.
    let focusedDisplayUUID = Self.focusedDisplayUUID()
    let focusedCurrentSpace: UInt64? = {
      if let uuid = focusedDisplayUUID {
        return spaces.first(where: { $0.isCurrent && $0.displayUUID == uuid })?.id
      }
      return spaces.first(where: \.isCurrent)?.id
    }()

    // Update the persistent MRU history: move the current space to the front.
    // This preserves ordering across space switches — e.g., switching from
    // Desktop 3 → Desktop 2 gives history [2, 3, ...] so Desktop 3 stays
    // second even though Z-order won't reflect its recency.
    if let currentID = focusedCurrentSpace {
      spaceMRUHistory.removeAll { $0 == currentID }
      spaceMRUHistory.insert(currentID, at: 0)
    }

    // Build the final space order:
    // 1. Spaces from MRU history (preserves cross-switch recency)
    // 2. Other displays' current spaces
    // 3. Remaining spaces by window Z-order
    // 4. Empty spaces
    var spaceMRUOrder: [UInt64] = []
    var seenSpaces = Set<UInt64>()

    // First: spaces we've visited, in MRU order
    for spaceID in spaceMRUHistory {
      if seenSpaces.insert(spaceID).inserted {
        spaceMRUOrder.append(spaceID)
      }
    }

    // Then: other displays' current spaces (not yet in history)
    for space in spaces where space.isCurrent && !seenSpaces.contains(space.id) {
      seenSpaces.insert(space.id)
      spaceMRUOrder.append(space.id)
    }

    // Then: remaining spaces by window Z-order
    for window in allWindows {
      for spaceID in window.spaceIDs {
        if seenSpaces.insert(spaceID).inserted {
          spaceMRUOrder.append(spaceID)
        }
      }
    }

    // Finally: spaces with no windows
    for space in spaces where !seenSpaces.contains(space.id) {
      spaceMRUOrder.append(space.id)
    }

    // Build a lookup for space info
    var spaceInfoMap: [UInt64: SpaceInfo] = [:]
    for space in spaces {
      spaceInfoMap[space.id] = space
    }

    // Build global ordinal labels: "Desktop 1", "Desktop 2", etc.
    // Only count desktop-type spaces (fullscreen spaces get their own label).
    // Number globally across all displays so there's no duplicate "Desktop 1".
    var desktopOrdinal: [UInt64: Int] = [:]
    var globalCounter = 0
    for space in spaces where space.type == .desktop {
      globalCounter += 1
      desktopOrdinal[space.id] = globalCounter
    }

    // Mark only the FIRST current space as "active" for the (current) label.
    // With multiple displays, this is the current space with the frontmost window.
    let activeSpaceID = spaceMRUOrder.first

    // Build sections in MRU order.
    // Sticky windows (visible on all spaces) appear in every space's window list,
    // so track seen window IDs to avoid duplicates. Show each window only once,
    // in the first (most-recently-used) space it appears in.
    var newSections: [SwitcherSection] = []
    var seenWindowIDs = Set<Int>()

    for spaceID in spaceMRUOrder {
      let spaceInfo = spaceInfoMap[spaceID]
      let windows = windowMap[spaceID] ?? []
      guard !windows.isEmpty || spaceInfo != nil else { continue }

      let spaceUUID = spaceInfo?.uuid ?? ""
      let label: String
      if let info = spaceInfo {
        let ordinal = desktopOrdinal[info.id] ?? 1
        switch info.type {
        case .fullscreen:
          let appName = windows.first?.ownerName ?? "App"
          label = "Fullscreen — \(appName)"
        case .desktop:
          if let customName = spaceNameStore.customName(forSpaceUUID: info.uuid) {
            label = customName
          } else {
            label = "Desktop \(ordinal)"
          }
        }
      } else {
        label = "Space \(spaceID)"
      }

      let isCurrent = spaceID == activeSpaceID
      let rows = windows
        .filter { seenWindowIDs.insert($0.id).inserted }
        .map { makeRow(from: $0) }

      guard !rows.isEmpty else { continue }

      newSections.append(SwitcherSection(
        id: spaceID,
        spaceUUID: spaceUUID,
        label: label,
        isCurrent: isCurrent,
        windows: rows
      ))
    }

    sections = newSections
    searchText = ""
    settingsSelected = false

    // Prune window MRU entries for windows that no longer exist.
    let activeWindowIDs = Set(allWindows.map(\.id))
    windowMRUHistory.removeAll { !activeWindowIDs.contains($0) }
  }

  // MARK: - Filtering

  public var filteredSections: [SwitcherSection] {
    guard !searchText.isEmpty else { return sections }
    let query = searchText.lowercased()
    return sections.compactMap { section in
      let filtered = section.windows.filter {
        $0.appName.lowercased().contains(query)
          || $0.windowTitle.lowercased().contains(query)
      }
      guard !filtered.isEmpty else { return nil }
      return SwitcherSection(
        id: section.id,
        spaceUUID: section.spaceUUID,
        label: section.label,
        isCurrent: section.isCurrent,
        windows: filtered
      )
    }
  }

  public var flatFilteredRows: [SwitcherRow] {
    filteredSections.flatMap(\.windows)
  }

  // MARK: - Selection

  public func moveSelectionDown() {
    let rows = flatFilteredRows
    guard !rows.isEmpty else { return }

    if settingsSelected {
      // Wrap from settings back to first row
      settingsSelected = false
      selectedRowID = rows.first?.id
      return
    }

    if let current = selectedRowID,
      let idx = rows.firstIndex(where: { $0.id == current })
    {
      let next = idx + 1
      if next >= rows.count {
        // Past last row → select settings
        selectedRowID = nil
        settingsSelected = true
      } else {
        selectedRowID = rows[next].id
      }
    } else {
      selectedRowID = rows.first?.id
    }
  }

  public func moveSelectionUp() {
    let rows = flatFilteredRows
    guard !rows.isEmpty else { return }

    if settingsSelected {
      // Up from settings → last row
      settingsSelected = false
      selectedRowID = rows.last?.id
      return
    }

    if let current = selectedRowID,
      let idx = rows.firstIndex(where: { $0.id == current })
    {
      let prev = idx - 1
      if prev < 0 {
        // Before first row → select settings
        selectedRowID = nil
        settingsSelected = true
      } else {
        selectedRowID = rows[prev].id
      }
    } else {
      selectedRowID = rows.last?.id
    }
  }

  public func resetSelection() {
    settingsSelected = false
    let rows = flatFilteredRows
    selectedRowID = rows.first?.id
  }

  // MARK: - Activation

  public func activateSelected() {
    guard let windowID = selectedRowID else { return }
    windowMRUHistory.removeAll { $0 == windowID }
    windowMRUHistory.insert(windowID, at: 0)
    do {
      try spaceManager.activateWindow(id: windowID)
    } catch {
      print("Failed to activate window \(windowID): \(error)")
    }
  }

  // MARK: - Close / Quit

  /// Closes the currently selected window and refreshes the list.
  public func closeSelectedWindow() {
    guard let windowID = selectedRowID else { return }
    do {
      try spaceManager.closeWindow(id: windowID)
    } catch {
      print("Failed to close window \(windowID): \(error)")
      return
    }
    windowMRUHistory.removeAll { $0 == windowID }
    // Brief delay so the window has time to close before we re-enumerate
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
      self?.refreshKeepingSelection()
    }
  }

  /// Quits the app that owns the currently selected window and refreshes.
  public func quitSelectedApp() {
    guard let windowID = selectedRowID else { return }
    let rows = flatFilteredRows
    let affectedPid = rows.first(where: { $0.id == windowID })?.pid
    do {
      try spaceManager.quitApp(owningWindowID: windowID)
    } catch {
      print("Failed to quit app for window \(windowID): \(error)")
      return
    }
    // Remove all MRU entries for windows belonging to the quitting app
    if let pid = affectedPid {
      let appWindowIDs = Set(rows.filter { $0.pid == pid }.map(\.id))
      windowMRUHistory.removeAll { appWindowIDs.contains($0) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      self?.refreshKeepingSelection()
    }
  }

  /// Refreshes sections while keeping the selection on the next available row.
  private func refreshKeepingSelection() {
    let previousID = selectedRowID
    refresh()
    let rows = flatFilteredRows
    if let prev = previousID, rows.contains(where: { $0.id == prev }) {
      selectedRowID = prev
    } else {
      // Previous window is gone — select the first row
      selectedRowID = rows.first?.id
    }
  }

  // MARK: - Helpers

  /// Returns the CGS display UUID for the screen with keyboard focus.
  /// Maps NSScreen.main's CGDirectDisplayID → UUID via CGDisplayCreateUUIDFromDisplayID.
  private static func focusedDisplayUUID() -> String? {
    guard let screenNumber = NSScreen.main?.deviceDescription[
      NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    else { return nil }
    let cfUUID = CGDisplayCreateUUIDFromDisplayID(screenNumber)?.takeUnretainedValue()
    guard let cfUUID else { return nil }
    return CFUUIDCreateString(nil, cfUUID) as String
  }

  private func reorderByMRU(_ windows: [WindowInfo]) -> [WindowInfo] {
    guard !windowMRUHistory.isEmpty else { return windows }
    var mruRank: [Int: Int] = [:]
    for (index, wid) in windowMRUHistory.enumerated() {
      mruRank[wid] = index
    }
    let maxRank = windowMRUHistory.count
    return windows.enumerated().sorted { a, b in
      let aRank = mruRank[a.element.id] ?? (maxRank + a.offset)
      let bRank = mruRank[b.element.id] ?? (maxRank + b.offset)
      return aRank < bRank
    }.map(\.element)
  }

  private func makeRow(from window: WindowInfo) -> SwitcherRow {
    let pid = pid_t(window.pid)
    let icon: NSImage?

    if let cached = iconCache[pid] {
      icon = cached
    } else if let app = NSRunningApplication(processIdentifier: pid) {
      icon = app.icon
      if let icon { iconCache[pid] = icon }
    } else {
      icon = nil
    }

    return SwitcherRow(
      id: window.id,
      appName: window.ownerName,
      windowTitle: window.name ?? "",
      appIcon: icon,
      pid: window.pid,
      isSticky: window.isSticky
    )
  }
}
