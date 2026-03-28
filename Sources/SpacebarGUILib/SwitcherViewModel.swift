import Cocoa
import SpacebarCore

// MARK: - Data Types

public struct SwitcherSection: Identifiable {
  public let id: UInt64  // space ID
  public let spaceUUID: String
  public let displayUUID: String
  public let displayName: String
  public let label: String
  public let isCurrent: Bool
  /// The macOS ordinal label for this space (e.g. "Desktop 3"), used as a badge
  /// so users can correlate custom names with macOS Mission Control names.
  public let ordinalLabel: String
  public var windows: [SwitcherRow]

  public init(
    id: UInt64, spaceUUID: String = "", displayUUID: String = "",
    displayName: String = "", label: String, isCurrent: Bool, ordinalLabel: String = "",
    windows: [SwitcherRow]
  ) {
    self.id = id
    self.spaceUUID = spaceUUID
    self.displayUUID = displayUUID
    self.displayName = displayName
    self.label = label
    self.isCurrent = isCurrent
    self.ordinalLabel = ordinalLabel
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

// MARK: - Selection

public enum SelectedItem: Equatable, Hashable {
  case spaceHeader(UInt64)  // space ID
  case windowRow(Int)  // CGWindowID
  case settings
}

// MARK: - ViewModel

public final class SwitcherViewModel: ObservableObject {
  @Published public var sections: [SwitcherSection] = []
  @Published public var searchText: String = ""
  @Published public var selectedItem: SelectedItem?
  @Published public var renamingSpaceID: UInt64? = nil
  @Published public var renameText: String = ""

  public var isRenaming: Bool { renamingSpaceID != nil }

  public let spaceManager: SpaceManager
  public let spaceNameStore: SpaceNameStoring

  /// When true, keyboard navigation and per-panel rendering filter by display.
  public var filterByDisplay: Bool = false

  /// Display UUIDs in navigation order (active display first).
  /// Non-empty signals mode 3 (multi-panel per-display).
  public var displayOrder: [String] = []

  /// When true, spaces with no windows are included in the switcher.
  public var showEmptySpaces: Bool = true

  /// How to order sections: MRU, desktop number, or alphabetical.
  public var spaceSortOrder: SpaceSortOrder = .mru

  /// Override the focused display UUID (used for display cycling via Cmd+Left/Right and for testing).
  public var overrideDisplayUUID: String?

  /// In mode 3, tracks which display group the user was navigating when .settings was selected.
  private var settingsDisplayIndex: Int = 0

  /// Persistent MRU history of space IDs, most recent first.
  /// Updated on each refresh() when the current space changes.
  private var spaceMRUHistory: [UInt64] = []

  /// Persistent MRU history of CGWindowIDs, most recently activated first.
  /// Updated when Spacebar activates a window via activateSelected().
  private var windowMRUHistory: [Int] = []

  /// Cache app icons by bundle identifier to avoid repeated lookups.
  private var iconCache: [pid_t: NSImage] = [:]

  /// Window IDs that have been closed/quit but may still linger in CGWindowList.
  /// Filtered out during refresh() until they actually disappear.
  private var pendingCloseWindowIDs = Set<Int>()

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
    let displayNames = Self.displayNameMap()

    // Prune pending-close IDs that have actually disappeared from CGWindowList.
    let activeWindowIDs = Set(allWindows.map(\.id))
    pendingCloseWindowIDs = pendingCloseWindowIDs.filter { activeWindowIDs.contains($0) }

    // Filter out windows that are pending close (optimistic removal)
    // and windows that are hidden on a current space. Off-screen windows
    // on non-current spaces are expected (cross-space) and kept.
    let currentSpaceIDs = Set(spaces.filter(\.isCurrent).map(\.id))
    var windowMap = rawWindowMap
    for (spaceID, windows) in windowMap {
      windowMap[spaceID] = windows.filter { window in
        if pendingCloseWindowIDs.contains(window.id) { return false }
        if !window.isOnscreen
          && window.spaceIDs.allSatisfy({ currentSpaceIDs.contains($0) })
        {
          return false
        }
        return true
      }
    }

    // Determine the current space on the focused display.
    // With multiple displays, each has its own current space (from CGS isCurrent).
    // NSScreen.main identifies which display has keyboard focus.
    let focusedDisplayUUID = overrideDisplayUUID ?? Self.focusedDisplayUUID()
    let focusedCurrentSpace: UInt64? = {
      if let uuid = focusedDisplayUUID {
        return spaces.first(where: { $0.isCurrent && $0.displayUUID == uuid })?.id
      }
      return spaces.first(where: \.isCurrent)?.id
    }()

    // Sync the frontmost window on the focused space into windowMRUHistory.
    // Uses .optionOnScreenOnly which guarantees front-to-back Z-order, unlike
    // .optionAll which has unspecified ordering. This ensures the actually-focused
    // window appears first even when activated outside Spacebar (clicking, Cmd+Tab, etc.).
    if let focusedSpace = focusedCurrentSpace,
      let frontWindowID = spaceManager.frontmostWindowID(onSpace: focusedSpace)
    {
      windowMRUHistory.removeAll { $0 == frontWindowID }
      windowMRUHistory.insert(frontWindowID, at: 0)
    }

    // Reorder windows within each space by MRU history.
    for (spaceID, windows) in windowMap {
      windowMap[spaceID] = reorderByMRU(windows)
    }

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

    // Filter to only the focused display's spaces when enabled.
    if filterByDisplay, let uuid = focusedDisplayUUID {
      spaceMRUOrder = spaceMRUOrder.filter { spaceInfoMap[$0]?.displayUUID == uuid }
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

    // Apply configured sort order.
    switch spaceSortOrder {
    case .mru:
      break  // already in MRU order
    case .desktopNumber:
      // Use the system ordinal order (Desktop 1, 2, 3, ...).
      // Fullscreen spaces (no ordinal) sort after desktops.
      spaceMRUOrder.sort { a, b in
        let oa = desktopOrdinal[a] ?? Int.max
        let ob = desktopOrdinal[b] ?? Int.max
        return oa < ob
      }
    case .alphabetical:
      spaceMRUOrder.sort { a, b in
        let labelA = self.spaceLabel(
          for: a, info: spaceInfoMap[a], ordinal: desktopOrdinal[a],
          windowsBySpace: windowMap)
        let labelB = self.spaceLabel(
          for: b, info: spaceInfoMap[b], ordinal: desktopOrdinal[b],
          windowsBySpace: windowMap)
        return labelA.localizedCaseInsensitiveCompare(labelB) == .orderedAscending
      }
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
      let ordinalLabel: String
      if let info = spaceInfo {
        let ordinal = desktopOrdinal[info.id] ?? 1
        switch info.type {
        case .fullscreen:
          let appName = windows.first?.ownerName ?? "App"
          label = "Fullscreen — \(appName)"
          ordinalLabel = ""
        case .desktop:
          let defaultLabel = "Desktop \(ordinal)"
          ordinalLabel = defaultLabel
          if let customName = spaceNameStore.customName(forSpaceUUID: info.uuid) {
            label = customName
          } else {
            label = defaultLabel
          }
        }
      } else {
        label = "Space \(spaceID)"
        ordinalLabel = ""
      }

      let isCurrent = spaceID == activeSpaceID
      let rows =
        windows
        .filter { seenWindowIDs.insert($0.id).inserted }
        .map { makeRow(from: $0) }

      guard !rows.isEmpty || showEmptySpaces else { continue }

      let dispUUID = spaceInfo?.displayUUID ?? ""
      newSections.append(
        SwitcherSection(
          id: spaceID,
          spaceUUID: spaceUUID,
          displayUUID: dispUUID,
          displayName: displayNames[dispUUID] ?? "",
          label: label,
          isCurrent: isCurrent,
          ordinalLabel: ordinalLabel,
          windows: rows
        ))
    }

    sections = newSections
    searchText = ""
    selectedItem = nil

    // Prune window MRU entries for windows that no longer exist.
    windowMRUHistory.removeAll { !activeWindowIDs.contains($0) }
  }

  /// Computes the display label for a space (used for alphabetical sorting).
  private func spaceLabel(
    for spaceID: UInt64, info: SpaceInfo?, ordinal: Int?,
    windowsBySpace: [UInt64: [WindowInfo]]
  ) -> String {
    guard let info else { return "Space \(spaceID)" }
    switch info.type {
    case .fullscreen:
      let appName = windowsBySpace[spaceID]?.first?.ownerName ?? "App"
      return "Fullscreen — \(appName)"
    case .desktop:
      if let customName = spaceNameStore.customName(forSpaceUUID: info.uuid) {
        return customName
      }
      return "Desktop \(ordinal ?? 1)"
    }
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
        displayUUID: section.displayUUID,
        label: section.label,
        isCurrent: section.isCurrent,
        ordinalLabel: section.ordinalLabel,
        windows: filtered
      )
    }
  }

  public var flatFilteredRows: [SwitcherRow] {
    filteredSections.flatMap(\.windows)
  }

  /// All selectable items in tab-cycle order.
  /// Mode 3 (multi-panel): groups by `displayOrder`, omits `.settings`.
  /// Modes 1&2: flat MRU order + `.settings` at the end.
  public var flatSelectableItems: [SelectedItem] {
    var items: [SelectedItem] = []
    let sections = filteredSections

    if !displayOrder.isEmpty {
      // Mode 3: group sections by display in displayOrder
      for uuid in displayOrder {
        for section in sections where section.displayUUID == uuid {
          if section.windows.isEmpty {
            items.append(.spaceHeader(section.id))
          } else {
            for window in section.windows {
              items.append(.windowRow(window.id))
            }
          }
        }
      }
      // Include any sections whose display isn't in displayOrder (shouldn't happen, but safe)
      let ordered = Set(displayOrder)
      for section in sections where !ordered.contains(section.displayUUID) {
        if section.windows.isEmpty {
          items.append(.spaceHeader(section.id))
        } else {
          for window in section.windows {
            items.append(.windowRow(window.id))
          }
        }
      }
    } else {
      for section in sections {
        if section.windows.isEmpty {
          items.append(.spaceHeader(section.id))
        } else {
          for window in section.windows {
            items.append(.windowRow(window.id))
          }
        }
      }
    }
    items.append(.settings)
    return items
  }

  // MARK: - Selection Convenience

  public var settingsSelected: Bool {
    selectedItem == .settings
  }

  public var selectedRowID: Int? {
    if case .windowRow(let id) = selectedItem { return id }
    return nil
  }

  public var selectedSpaceID: UInt64? {
    if case .spaceHeader(let id) = selectedItem { return id }
    return nil
  }

  // MARK: - Selection

  /// Display group boundary indices within `flatSelectableItems` (excluding the trailing `.settings`).
  /// Returns (startIndex, endIndex) pairs, one per display in `displayOrder`.
  private func displayGroupRanges() -> [(start: Int, end: Int)] {
    guard !displayOrder.isEmpty else { return [] }
    let sections = filteredSections
    var ranges: [(start: Int, end: Int)] = []
    var idx = 0
    for uuid in displayOrder {
      let start = idx
      for section in sections where section.displayUUID == uuid {
        idx += section.windows.isEmpty ? 1 : section.windows.count
      }
      if idx > start {
        ranges.append((start: start, end: idx - 1))
      }
    }
    return ranges
  }

  public func moveSelectionDown() {
    let items = flatSelectableItems
    guard items.count > 1 else { return }

    // Mode 3: .settings acts as a stop between each display group
    if !displayOrder.isEmpty {
      let ranges = displayGroupRanges()
      guard !ranges.isEmpty else { return }

      if selectedItem == .settings {
        // From .settings, continue to the next display's first item (wrapping)
        let nextGroup = (settingsDisplayIndex + 1) % ranges.count
        selectedItem = items[ranges[nextGroup].start]
        return
      }

      guard let current = selectedItem, let idx = items.firstIndex(of: current) else {
        selectedItem = items.first
        return
      }

      // At end of a display group → go to .settings
      if let groupIdx = ranges.firstIndex(where: { $0.end == idx }) {
        settingsDisplayIndex = groupIdx
        selectedItem = .settings
        return
      }

      // Normal: next item within the group
      selectedItem = items[idx + 1]
      return
    }

    // Modes 1 & 2: flat navigation
    guard let current = selectedItem,
      let idx = items.firstIndex(of: current)
    else {
      selectedItem = items.first
      return
    }

    let next = idx + 1
    selectedItem = next >= items.count ? items.first : items[next]
  }

  public func moveSelectionUp() {
    let items = flatSelectableItems
    guard items.count > 1 else { return }

    // Mode 3: .settings acts as a stop between each display group
    if !displayOrder.isEmpty {
      let ranges = displayGroupRanges()
      guard !ranges.isEmpty else { return }

      if selectedItem == .settings {
        // From .settings, go back to the last item of the source display group
        selectedItem = items[ranges[settingsDisplayIndex].end]
        return
      }

      guard let current = selectedItem, let idx = items.firstIndex(of: current) else {
        selectedItem = items.last
        return
      }

      // At start of a display group → go to .settings (source = previous group, wrapping)
      if let groupIdx = ranges.firstIndex(where: { $0.start == idx }) {
        settingsDisplayIndex = (groupIdx - 1 + ranges.count) % ranges.count
        selectedItem = .settings
        return
      }

      // Normal: previous item within the group
      selectedItem = items[idx - 1]
      return
    }

    // Modes 1 & 2: flat navigation
    guard let current = selectedItem,
      let idx = items.firstIndex(of: current)
    else {
      selectedItem = items.last
      return
    }

    let prev = idx - 1
    selectedItem = prev < 0 ? items.last : items[prev]
  }

  public func resetSelection() {
    let items = flatSelectableItems
    selectedItem = items.first(where: {
      if case .windowRow = $0 { return true }
      return false
    })
  }

  /// Builds a window-ID → space-ID lookup from the current sections.
  private func windowSpaceMap() -> [Int: UInt64] {
    var map: [Int: UInt64] = [:]
    for section in sections {
      for window in section.windows {
        map[window.id] = section.id
      }
    }
    return map
  }

  /// Returns the space ID for the given selectable item using the supplied lookup.
  private func spaceID(for item: SelectedItem, using map: [Int: UInt64]) -> UInt64? {
    switch item {
    case .spaceHeader(let id): return id
    case .windowRow(let id): return map[id]
    case .settings: return nil
    }
  }

  public func moveToNextSpace() {
    let items = flatSelectableItems
    guard !items.isEmpty else { return }
    let map = windowSpaceMap()

    guard let current = selectedItem, let currentPos = items.firstIndex(of: current) else {
      selectedItem = items.first(where: { spaceID(for: $0, using: map) != nil })
      return
    }

    let currentSpace = spaceID(for: current, using: map)

    // Scan forward (with wrap) for the first item in a different section
    for offset in 1..<items.count {
      let pos = (currentPos + offset) % items.count
      let item = items[pos]
      let itemSpace = spaceID(for: item, using: map)
      guard itemSpace != nil else { continue }  // skip .settings
      if itemSpace != currentSpace {
        selectedItem = item
        return
      }
    }
  }

  public func moveToPreviousSpace() {
    let items = flatSelectableItems
    guard !items.isEmpty else { return }
    let map = windowSpaceMap()

    guard let current = selectedItem, let currentPos = items.firstIndex(of: current) else {
      selectedItem = items.last(where: { spaceID(for: $0, using: map) != nil })
      return
    }

    let currentSpace = spaceID(for: current, using: map)

    // Scan backward (with wrap) for the first item in a different section,
    // then continue to find the FIRST item of that section.
    var targetSpace: UInt64?
    var targetPos: Int?
    for offset in 1..<items.count {
      let pos = (currentPos - offset + items.count) % items.count
      let item = items[pos]
      let itemSpace = spaceID(for: item, using: map)
      guard let space = itemSpace else { continue }  // skip .settings
      if space != currentSpace {
        if targetSpace == nil {
          targetSpace = space
          targetPos = pos
        } else if space == targetSpace {
          targetPos = pos
        } else {
          break
        }
      } else if targetSpace != nil {
        break
      }
    }

    if let pos = targetPos {
      selectedItem = items[pos]
    }
  }

  // MARK: - Multi-Panel Display Navigation

  /// Returns the display UUID of the section containing the currently selected item.
  public var activeDisplayUUID: String? {
    switch selectedItem {
    case .spaceHeader(let spaceID):
      return filteredSections.first(where: { $0.id == spaceID })?.displayUUID
    case .windowRow(let windowID):
      return filteredSections.first(where: { $0.windows.contains(where: { $0.id == windowID }) })?
        .displayUUID
    case .settings, nil:
      return nil
    }
  }

  /// Moves selection to the first window (or header) on the given display.
  public func selectFirstWindow(onDisplay uuid: String) {
    let sections = filteredSections.filter { $0.displayUUID == uuid }
    for section in sections {
      if let first = section.windows.first {
        selectedItem = .windowRow(first.id)
        return
      }
    }
    // No windows — select the first header on this display
    if let section = sections.first {
      selectedItem = .spaceHeader(section.id)
    }
  }

  // MARK: - Inline Rename

  /// Whether the current selection supports space renaming (space header or first window row).
  public var canRenameFromCurrentSelection: Bool {
    switch selectedItem {
    case .spaceHeader:
      return true
    case .windowRow(let id):
      return filteredSections.contains(where: { $0.windows.first?.id == id })
    default:
      return false
    }
  }

  public func startRenaming() {
    let spaceID: UInt64
    switch selectedItem {
    case .spaceHeader(let id):
      spaceID = id
    case .windowRow(let windowID):
      guard let section = filteredSections.first(where: { $0.windows.first?.id == windowID })
      else { return }
      spaceID = section.id
    default:
      return
    }
    guard let section = sections.first(where: { $0.id == spaceID }) else { return }
    // Don't rename fullscreen spaces (auto-generated labels)
    if section.label.hasPrefix("Fullscreen") { return }
    renamingSpaceID = spaceID
    renameText = section.label
  }

  public func commitRename() {
    guard let spaceID = renamingSpaceID else { return }
    guard let section = sections.first(where: { $0.id == spaceID }) else {
      cancelRename()
      return
    }

    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      spaceNameStore.setCustomName(nil, forSpaceUUID: section.spaceUUID)
    } else {
      spaceNameStore.setCustomName(trimmed, forSpaceUUID: section.spaceUUID)
    }

    let savedSelection = selectedItem
    renamingSpaceID = nil
    renameText = ""
    refresh()
    selectedItem = savedSelection
  }

  public func cancelRename() {
    renamingSpaceID = nil
    renameText = ""
  }

  // MARK: - Activation

  public func activateSelected() {
    let windowID: Int
    switch selectedItem {
    case .windowRow(let id):
      windowID = id
    case .spaceHeader(let spaceID):
      guard let section = filteredSections.first(where: { $0.id == spaceID })
      else { return }
      if let firstWindow = section.windows.first {
        // Activate the first window in this space to trigger space switch
        windowID = firstWindow.id
      } else {
        // Empty space — switch via Dock accessibility (Mission Control)
        let allSpaces = spaceManager.getAllSpaces()
        let displaySpaces = allSpaces.filter { $0.displayUUID == section.displayUUID }
          .filter { $0.type == .desktop }
        guard let spaceIndex = displaySpaces.firstIndex(where: { $0.id == spaceID }) else {
          return
        }
        guard let screenNumber = SpaceManager.displayIDForUUID(section.displayUUID) else { return }
        spaceManager.switchToSpace(spaceIndex: spaceIndex, screenNumber: screenNumber)
        return
      }
    case .settings, nil:
      return
    }

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
    guard case .windowRow(let windowID) = selectedItem else { return }
    let rows = flatFilteredRows
    guard let row = rows.first(where: { $0.id == windowID }) else { return }

    // Closing our own window (e.g. Settings) via AX kills the app.
    // Use NSApp to close it safely instead.
    let pid = pid_t(row.pid)
    if pid == ProcessInfo.processInfo.processIdentifier {
      for window in NSApp.windows where window.windowNumber == windowID {
        window.close()
      }
      windowMRUHistory.removeAll { $0 == windowID }
      pendingCloseWindowIDs.insert(windowID)
      removeWindowFromSections(windowID)
      return
    }

    do {
      try spaceManager.closeWindow(id: windowID)
    } catch {
      print("Failed to close window \(windowID): \(error)")
      return
    }
    windowMRUHistory.removeAll { $0 == windowID }
    pendingCloseWindowIDs.insert(windowID)
    removeWindowFromSections(windowID)
  }

  /// Quits the app that owns the currently selected window and refreshes.
  /// For Finder, closes the window instead (Finder auto-relaunches on terminate).
  public func quitSelectedApp() {
    guard case .windowRow(let windowID) = selectedItem else { return }
    let rows = flatFilteredRows
    guard let row = rows.first(where: { $0.id == windowID }) else { return }

    let pid = pid_t(row.pid)

    // Don't quit ourselves through the switcher
    if pid == ProcessInfo.processInfo.processIdentifier { return }

    // Finder auto-relaunches on terminate — close just this window instead
    if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.finder" {
      closeSelectedWindow()
      return
    }

    do {
      try spaceManager.quitApp(owningWindowID: windowID)
    } catch {
      print("Failed to quit app for window \(windowID): \(error)")
      return
    }
    // Remove all MRU entries and rows for the quitting app immediately
    let appWindowIDs = Set(rows.filter { $0.pid == row.pid }.map(\.id))
    windowMRUHistory.removeAll { appWindowIDs.contains($0) }
    for wid in appWindowIDs {
      pendingCloseWindowIDs.insert(wid)
      removeWindowFromSections(wid)
    }
  }

  /// Optimistically removes a window from the published sections and advances
  /// the selection to the next row. Gives instant visual feedback before the
  /// OS finishes tearing down the window.
  private func removeWindowFromSections(_ windowID: Int) {
    let previousIndex = flatFilteredRows.firstIndex(where: { $0.id == windowID })

    // Remove the window from sections, dropping empty sections (unless showEmptySpaces)
    sections = sections.compactMap { section in
      let filtered = section.windows.filter { $0.id != windowID }
      guard !filtered.isEmpty || showEmptySpaces else { return nil }
      return SwitcherSection(
        id: section.id,
        spaceUUID: section.spaceUUID,
        displayUUID: section.displayUUID,
        displayName: section.displayName,
        label: section.label,
        isCurrent: section.isCurrent,
        ordinalLabel: section.ordinalLabel,
        windows: filtered
      )
    }

    // Advance selection to the next row at the same position
    let rows = flatFilteredRows
    if let idx = previousIndex, !rows.isEmpty {
      let clampedIndex = min(idx, rows.count - 1)
      selectedItem = .windowRow(rows[clampedIndex].id)
    } else {
      selectedItem = rows.first.map { .windowRow($0.id) }
    }
  }

  /// Refreshes sections while keeping the selection on the next available row.
  func refreshKeepingSelection() {
    let previous = selectedItem
    // Capture the position of the selected window before refresh so we can
    // select the next item at the same index if it disappears.
    let previousIndex: Int?
    if case .windowRow(let prevID) = previous {
      previousIndex = flatFilteredRows.firstIndex(where: { $0.id == prevID })
    } else {
      previousIndex = nil
    }

    refresh()
    let rows = flatFilteredRows
    if case .windowRow(let prevID) = previous, rows.contains(where: { $0.id == prevID }) {
      selectedItem = .windowRow(prevID)
    } else if let idx = previousIndex, !rows.isEmpty {
      // Window was removed — stay at the same position (or clamp to last)
      let clampedIndex = min(idx, rows.count - 1)
      selectedItem = .windowRow(rows[clampedIndex].id)
    } else {
      selectedItem = rows.first.map { .windowRow($0.id) }
    }
  }

  // MARK: - Helpers

  /// Returns the CGS display UUID for the screen with keyboard focus.
  /// Maps NSScreen.main's CGDirectDisplayID → UUID via CGDisplayCreateUUIDFromDisplayID.
  private static func focusedDisplayUUID() -> String? {
    guard
      let screenNumber = NSScreen.main?.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    else { return nil }
    let cfUUID = CGDisplayCreateUUIDFromDisplayID(screenNumber)?.takeUnretainedValue()
    guard let cfUUID else { return nil }
    return CFUUIDCreateString(nil, cfUUID) as String
  }

  /// Builds a mapping from CGS display UUID → NSScreen.localizedName.
  private static func displayNameMap() -> [String: String] {
    var map: [String: String] = [:]
    for screen in NSScreen.screens {
      guard
        let screenNumber = screen.deviceDescription[
          NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
      else { continue }
      let cfUUID = CGDisplayCreateUUIDFromDisplayID(screenNumber)?.takeUnretainedValue()
      guard let cfUUID else { continue }
      let uuid = CFUUIDCreateString(nil, cfUUID) as String
      map[uuid] = screen.localizedName
    }
    return map
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
