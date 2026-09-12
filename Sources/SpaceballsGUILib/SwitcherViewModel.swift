import Cocoa
import Dispatch
import SpaceballsCore

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
  public var isMinimized: Bool

  public init(
    id: Int, appName: String, windowTitle: String,
    appIcon: NSImage?, pid: Int, isSticky: Bool, isMinimized: Bool = false
  ) {
    self.id = id
    self.appName = appName
    self.windowTitle = windowTitle
    self.appIcon = appIcon
    self.pid = pid
    self.isSticky = isSticky
    self.isMinimized = isMinimized
  }
}

// MARK: - Selection

public enum SelectedItem: Equatable, Hashable {
  case spaceHeader(UInt64)  // space ID
  case windowRow(Int)  // CGWindowID
  case spaces
  case settings
  case eject
}

// MARK: - Display Context

struct SwitcherDisplayContext: Equatable {
  let focusedDisplayUUID: String?
  let displayNamesByUUID: [String: String]
}

protocol SwitcherDisplayContextProviding {
  func currentContext() -> SwitcherDisplayContext
}

private struct AppKitSwitcherDisplayContextProvider: SwitcherDisplayContextProviding {
  func currentContext() -> SwitcherDisplayContext {
    dispatchPrecondition(condition: .onQueue(.main))

    var displayNamesByUUID: [String: String] = [:]
    for screen in NSScreen.screens {
      guard let uuid = spaceballsDisplayUUID(for: screen) else { continue }
      displayNamesByUUID[uuid] = screen.localizedName
    }

    return SwitcherDisplayContext(
      focusedDisplayUUID: NSScreen.main.flatMap(spaceballsDisplayUUID(for:)),
      displayNamesByUUID: displayNamesByUUID
    )
  }
}

// MARK: - ViewModel

public final class SwitcherViewModel: ObservableObject {
  @Published public var sections: [SwitcherSection] = []
  @Published public var searchText: String = ""
  @Published public var selectedItem: SelectedItem?
  @Published public var renamingSpaceID: UInt64? = nil
  @Published public var renameText: String = ""

  /// Brief toast text shown when the sort order changes.
  /// Cleared automatically after a delay.
  @Published public var sortOverlayText: String?

  /// Incremented each time the overlay is shown, so stale dismiss timers are ignored.
  @Published public var sortOverlayGeneration: Int = 0

  // MARK: - Move Mode

  /// When true, the user has marked a window for moving to another space.
  @Published public var moveMode: Bool = false

  /// The CGWindowID of the window marked for moving. Set when entering move mode.
  @Published public var markedWindowID: Int? = nil

  /// The space ID that the marked window currently belongs to (for UI highlighting).
  @Published public var markedWindowSpaceID: UInt64? = nil

  // MARK: - Space Move Mode

  /// When true, the user has marked a Space for moving to another display.
  @Published public var spaceMoveMode: Bool = false

  /// The space ID marked for moving between displays.
  @Published public var markedSpaceID: UInt64? = nil

  /// The display the marked space was on when space-move mode was entered
  /// (for no-op detection and UI highlighting).
  @Published public var markedSpaceOriginDisplayUUID: String? = nil

  /// The ordered display cycle captured at mode entry (CGS display order, so
  /// it matches the CLI's display ordinals).
  private var spaceMoveDisplays: [(uuid: String, name: String)] = []

  // MARK: - Create Space Menu

  public enum PanelMode {
    case normal
    case createSpace
  }

  public struct CreateMenuItem: Identifiable {
    public let id: Int
    public let label: String
    public let workspaceIndex: Int?  // nil = "New Space" (unnamed)
  }

  @Published public var panelMode: PanelMode = .normal
  @Published public var createMenuItems: [CreateMenuItem] = []
  @Published public var createMenuSelection: Int? = nil
  /// The display UUID the user was on when entering create mode.
  public var createModeDisplayUUID: String?

  /// Special sentinel workspace indices.
  public static let backWorkspaceIndex = -2
  public static let allSpacesWorkspaceIndex = -1

  public func enterCreateMode(workspaces: [WorkspaceConfig], displayUUID: String? = nil) {
    createModeDisplayUUID = displayUUID
    var items: [CreateMenuItem] = []
    items.append(
      CreateMenuItem(id: 0, label: "Back", workspaceIndex: Self.backWorkspaceIndex))
    items.append(CreateMenuItem(id: 1, label: "New Space", workspaceIndex: nil))
    for (i, ws) in workspaces.enumerated() {
      items.append(CreateMenuItem(id: i + 2, label: ws.name, workspaceIndex: i))
    }
    if !workspaces.isEmpty {
      items.append(
        CreateMenuItem(
          id: workspaces.count + 2, label: "All Workspaces",
          workspaceIndex: Self.allSpacesWorkspaceIndex))
    }
    createMenuItems = items
    createMenuSelection = 1  // Select "New Space" by default (skip "Back")
    panelMode = .createSpace
  }

  public func exitCreateMode() {
    panelMode = .normal
    createMenuItems = []
    createMenuSelection = nil
    createModeDisplayUUID = nil
  }

  public func moveCreateSelectionDown() {
    guard !createMenuItems.isEmpty else { return }
    if let current = createMenuSelection {
      createMenuSelection = (current + 1) % createMenuItems.count
    } else {
      createMenuSelection = 0
    }
  }

  public func moveCreateSelectionUp() {
    guard !createMenuItems.isEmpty else { return }
    if let current = createMenuSelection {
      createMenuSelection = (current - 1 + createMenuItems.count) % createMenuItems.count
    } else {
      createMenuSelection = createMenuItems.count - 1
    }
  }

  public var isRenaming: Bool { renamingSpaceID != nil }

  public let spaceManager: SpaceManager
  public let spaceNameStore: SpaceNameStoring

  /// When true, keyboard navigation and per-panel rendering filter by display.
  public var filterByDisplay: Bool = false

  /// Display UUIDs in navigation order (active display first).
  /// Non-empty signals mode 3 (multi-panel per-display).
  public var displayOrder: [String] = []

  /// Physical display layout used for directional (Shift+arrow) display
  /// targeting. Set by the app when the panel opens; when nil (tests, no
  /// AppKit context) directional moves fall back to cycling in CGS order.
  public var displayArrangement: DisplayArrangement?

  /// In mode 3 ("All" panels), the display whose panel hosts the Spaces and
  /// Settings rows — every other panel hides them, and the ↑/↓ space cycle
  /// visits them at this display's bottom boundary. nil (single-panel modes)
  /// shows them on every panel with no traversal detour.
  public var metaRowsDisplayUUID: String?

  /// When true, spaces with no windows are included in the switcher.
  public var showEmptySpaces: Bool = true

  /// When true, activating a window warps the cursor onto it — on any
  /// display, unless the cursor is already over the window — and activating
  /// an empty Space on another display recenters the cursor there (issue #17).
  /// Synced from AppSettings by the app delegate.
  public var warpCursorOnActivation: Bool = false

  /// When true (default), a moved window or Space is activated after the move.
  /// Synced from AppSettings by the app delegate.
  public var activateMovedItem: Bool = true

  /// How to order sections: MRU, desktop number, or alphabetical.
  public var spaceSortOrder: SpaceSortOrder = .mru

  /// Override the focused display UUID (used for display cycling via Cmd+Left/Right and for testing).
  public var overrideDisplayUUID: String?

  /// Resolves the built-in display's UUID for Eject-row gating; overridable
  /// for tests.
  public var builtinDisplayUUID: () -> String? = { SpaceManager.builtinDisplayUUID() }

  /// Whether the Eject meta row is offered. False when every Space already
  /// sits on the built-in display — an eject would have nothing to move.
  /// Fails open when the built-in display can't be identified. Recomputed
  /// each refresh (display reconfigurations trigger one).
  @Published public private(set) var ejectAvailable: Bool = true

  /// In mode 3, tracks which display group the user was navigating when .settings was selected.
  private var settingsDisplayIndex: Int = 0

  /// The display UUID the user is currently navigating in Mode 3.
  /// Used so the meta rows only highlight on the relevant panel.
  @Published public var navigationDisplayUUID: String?

  /// Display of the most-recently-used space as of the last refresh,
  /// regardless of the configured sort order. The app delegate leads the
  /// multi-panel display order with it so the panel holding the selection is
  /// the one showing the space the user most recently activated — keyboard
  /// focus (NSScreen.main) can lag or never follow activations of empty or
  /// freshly moved spaces.
  public private(set) var mruTopDisplayUUID: String?

  /// Focused-display state at the last refresh, used to stamp the space MRU
  /// only on actual transitions. A steady-state refresh must not re-stamp:
  /// it would demote a space the user explicitly activated but that keyboard
  /// focus can't follow (an empty space has no window to take key).
  private var lastFocusedSpaceID: UInt64?
  private var lastFrontWindowID: Int?

  /// Set when executeMoveSpace stamps an explicitly activated move. Moving the
  /// focused display's current space away makes CGS slide a replacement space
  /// in beneath the user, which the next refresh would misread as the user
  /// switching to it. The explicit activation is authoritative: the first
  /// transition stamp from the origin display ranks behind it instead of on top.
  private var pendingMoveStamp: (spaceID: UInt64, originDisplayUUID: String?)?

  /// Persistent MRU history of space IDs, most recent first.
  /// Updated on each refresh() when the current space changes.
  private var spaceMRUHistory: [UInt64] = []

  /// Persistent MRU history of CGWindowIDs, most recently activated first.
  /// Updated when Spaceballs activates a window via activateSelected().
  private var windowMRUHistory: [Int] = []

  /// Cache app icons by bundle identifier to avoid repeated lookups.
  private var iconCache: [pid_t: NSImage] = [:]

  /// Window IDs that have been closed/quit but may still linger in CGWindowList.
  /// Filtered out during refresh() until they actually disappear.
  private var pendingCloseWindowIDs = Set<Int>()

  private let displayContextProvider: any SwitcherDisplayContextProviding
  private let minimizeWindow: (Int) throws -> Void

  public convenience init(
    spaceManager: SpaceManager = SpaceManager(),
    spaceNameStore: SpaceNameStoring = SpaceNameStore()
  ) {
    self.init(
      spaceManager: spaceManager,
      spaceNameStore: spaceNameStore,
      displayContextProvider: AppKitSwitcherDisplayContextProvider()
    )
  }

  init(
    spaceManager: SpaceManager = SpaceManager(),
    spaceNameStore: SpaceNameStoring = SpaceNameStore(),
    minimizeWindow: ((Int) throws -> Void)? = nil,
    displayContextProvider: any SwitcherDisplayContextProviding
  ) {
    self.spaceManager = spaceManager
    self.spaceNameStore = spaceNameStore
    self.minimizeWindow = minimizeWindow ?? { try spaceManager.minimizeWindow(id: $0) }
    self.displayContextProvider = displayContextProvider
  }

  // MARK: - Refresh

  public func refresh() {
    let (spaces, rawWindowMap) = spaceManager.windowsBySpace()
    let allWindows = spaceManager.getAllWindows()
    let displayContext = displayContextProvider.currentContext()

    // Prune pending-close IDs that have actually disappeared from CGWindowList.
    let activeWindowIDs = Set(allWindows.map(\.id))
    pendingCloseWindowIDs = pendingCloseWindowIDs.filter { activeWindowIDs.contains($0) }

    // Filter out windows that are pending close (optimistic removal).
    var windowMap = rawWindowMap
    for (spaceID, windows) in windowMap {
      windowMap[spaceID] = windows.filter { window in
        !pendingCloseWindowIDs.contains(window.id)
      }
    }

    // Determine the current space on the focused display.
    // With multiple displays, each has its own current space (from CGS isCurrent).
    // The live display context uses NSScreen.main to identify keyboard focus.
    let focusedDisplayUUID = overrideDisplayUUID ?? displayContext.focusedDisplayUUID
    let focusedCurrentSpace: UInt64? = {
      if let uuid = focusedDisplayUUID {
        return spaces.first(where: { $0.isCurrent && $0.displayUUID == uuid })?.id
      }
      return spaces.first(where: \.isCurrent)?.id
    }()

    // Sync the frontmost window on the focused space into windowMRUHistory.
    // Uses .optionOnScreenOnly which guarantees front-to-back Z-order, unlike
    // .optionAll which has unspecified ordering. This ensures the actually-focused
    // window appears first even when activated outside Spaceballs (clicking, Cmd+Tab, etc.).
    let frontWindowID = focusedCurrentSpace.flatMap {
      spaceManager.frontmostWindowID(onSpace: $0)
    }
    if let frontWindowID {
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
    //
    // Stamp only on a transition (focused space or frontmost window changed
    // since the last refresh). A steady-state re-stamp would demote a space
    // the user explicitly activated via `activateSelected` but that focus
    // cannot follow — an empty space has no window to take keyboard focus,
    // so NSScreen.main keeps reporting the old display (issue: empty space
    // pinned to the bottom of the switcher no matter how often activated).
    if let currentID = focusedCurrentSpace {
      if currentID != lastFocusedSpaceID || frontWindowID != lastFrontWindowID {
        spaceMRUHistory.removeAll { $0 == currentID }
        var insertionIndex = 0
        if let pending = pendingMoveStamp {
          // The origin display's replacement space still earns that display's
          // most-recent rank — just beneath the explicitly activated space.
          let currentDisplayUUID = spaces.first(where: { $0.id == currentID })?.displayUUID
          if currentID != pending.spaceID, currentDisplayUUID == pending.originDisplayUUID,
            let stampedIndex = spaceMRUHistory.firstIndex(of: pending.spaceID)
          {
            insertionIndex = stampedIndex + 1
          }
          pendingMoveStamp = nil
        }
        spaceMRUHistory.insert(currentID, at: insertionIndex)
      }
      lastFocusedSpaceID = currentID
      lastFrontWindowID = frontWindowID
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

    // Record the MRU-top space's display before any sort reshuffles the order.
    mruTopDisplayUUID = spaceMRUOrder.first.flatMap { spaceInfoMap[$0]?.displayUUID }

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
          displayName: displayContext.displayNamesByUUID[dispUUID] ?? "",
          label: label,
          isCurrent: isCurrent,
          ordinalLabel: ordinalLabel,
          windows: rows
        ))
    }

    let builtin = builtinDisplayUUID()
    ejectAvailable = builtin.map { b in spaces.contains { $0.displayUUID != b } } ?? true

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
    items.append(.spaces)
    items.append(.settings)
    if ejectAvailable {
      items.append(.eject)
    }
    return items
  }

  /// The bottom-most meta row currently offered.
  private var bottomMetaRow: SelectedItem {
    ejectAvailable ? .eject : .settings
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
    let map = windowSpaceMap()
    return spaceID(for: selectedItem ?? .settings, using: map)
  }

  // MARK: - Selection

  /// Display group boundary indices within `flatSelectableItems` (excluding the trailing meta rows).
  /// Returns (startIndex, endIndex, displayUUID) triples, one per display in `displayOrder`.
  private func displayGroupRanges() -> [(start: Int, end: Int, uuid: String)] {
    guard !displayOrder.isEmpty else { return [] }
    let sections = filteredSections
    var ranges: [(start: Int, end: Int, uuid: String)] = []
    var idx = 0
    for uuid in displayOrder {
      let start = idx
      for section in sections where section.displayUUID == uuid {
        idx += section.windows.isEmpty ? 1 : section.windows.count
      }
      if idx > start {
        ranges.append((start: start, end: idx - 1, uuid: uuid))
      }
    }
    return ranges
  }

  public func moveSelectionDown() {
    let items = flatSelectableItems
    guard items.count > 1 else { return }

    // Mode 3: the meta rows act as stops between display groups
    if !displayOrder.isEmpty {
      let ranges = displayGroupRanges()
      guard !ranges.isEmpty else { return }

      if selectedItem == .spaces {
        selectedItem = .settings
        return
      }

      if selectedItem == .settings, ejectAvailable {
        selectedItem = .eject
        return
      }

      if selectedItem == .settings || selectedItem == .eject {
        // From the bottom meta row, continue to the next display's first
        // item (wrapping)
        let nextGroup = (settingsDisplayIndex + 1) % ranges.count
        selectedItem = items[ranges[nextGroup].start]
        return
      }

      guard let current = selectedItem, let idx = items.firstIndex(of: current) else {
        selectedItem = items.first
        return
      }

      // At end of a display group → visit the meta rows when this group's
      // panel hosts them, otherwise flow straight into the next group.
      if let groupIdx = ranges.firstIndex(where: { $0.end == idx }) {
        if metaRowsDisplayUUID == nil || ranges[groupIdx].uuid == metaRowsDisplayUUID {
          settingsDisplayIndex = groupIdx
          selectedItem = .spaces
        } else {
          let nextGroup = (groupIdx + 1) % ranges.count
          selectedItem = items[ranges[nextGroup].start]
        }
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

    // Mode 3: the meta rows act as stops between display groups
    if !displayOrder.isEmpty {
      let ranges = displayGroupRanges()
      guard !ranges.isEmpty else { return }

      if selectedItem == .eject {
        selectedItem = .settings
        return
      }

      if selectedItem == .settings {
        selectedItem = .spaces
        return
      }

      if selectedItem == .spaces {
        // From .spaces, go back to the last item of the source display group
        selectedItem = items[ranges[settingsDisplayIndex].end]
        return
      }

      guard let current = selectedItem, let idx = items.firstIndex(of: current) else {
        selectedItem = items.last
        return
      }

      // At start of a display group → back into the previous group
      // (wrapping): through the bottom meta row when that group's panel
      // hosts the meta rows, else straight onto its last item.
      if let groupIdx = ranges.firstIndex(where: { $0.start == idx }) {
        let prevGroup = (groupIdx - 1 + ranges.count) % ranges.count
        if metaRowsDisplayUUID == nil || ranges[prevGroup].uuid == metaRowsDisplayUUID {
          settingsDisplayIndex = prevGroup
          selectedItem = bottomMetaRow
        } else {
          selectedItem = items[ranges[prevGroup].end]
        }
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
    guard !items.isEmpty else {
      selectedItem = nil
      return
    }
    // Always select the first item so that the subsequent moveDown
    // (from Cmd+Tab) lands on the second item. This ensures we always
    // end up on the 2nd row in the list.
    selectedItem = items.first
  }

  /// True when the Cmd+Tab that just opened the panel should keep the
  /// selection on the first row instead of advancing. Normally the advance
  /// lands on the second row — the user rarely wants the window they're
  /// already on. But when the active window is the ONLY window on its
  /// display's ONLY visible space, the second row lives on a different
  /// space entirely, and the highlight opening far from the space the user
  /// is looking at reads as wrong — hold it on the active window instead.
  public var shouldKeepInitialSelectionOnOpen: Bool {
    guard case .windowRow(let id)? = selectedItem,
      let section = filteredSections.first(where: {
        $0.windows.contains(where: { $0.id == id })
      }),
      section.isCurrent,
      section.windows.count == 1
    else { return false }
    return filteredSections.filter { $0.displayUUID == section.displayUUID }.count == 1
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
    case .spaces: return nil
    case .settings: return nil
    case .eject: return nil
    }
  }

  /// First selectable item of the display reached by walking the physical
  /// arrangement in `direction`, plus which display it landed on. Entering
  /// downward lands on that display's first space, entering upward on its
  /// last — the spatially nearest end. Walks past displays with no visible
  /// sections and wraps past the far edge; nil when no display lies on that
  /// axis at all.
  private func verticalNeighborLanding(
    from displayUUID: String, direction: ArrangementDirection
  ) -> (item: SelectedItem, displayUUID: String)? {
    guard let arrangement = displayArrangement else { return nil }
    var visited: Set<String> = [displayUUID]
    var current = displayUUID
    while let next = arrangement.wrappedNeighborUUID(of: current, direction: direction),
      !visited.contains(next)
    {
      visited.insert(next)
      let displaySections = filteredSections.filter { $0.displayUUID == next }
      if let target = direction == .down ? displaySections.first : displaySections.last {
        let item =
          target.windows.first.map { SelectedItem.windowRow($0.id) }
          ?? .spaceHeader(target.id)
        return (item, next)
      }
      current = next
    }
    return nil
  }

  /// Records the display group containing `position` so meta-row
  /// selection knows which group the user came from (highlight context and
  /// the ↑-from-Spaces return path).
  private func rememberSettingsGroup(containing position: Int) {
    let ranges = displayGroupRanges()
    if let groupIdx = ranges.firstIndex(where: {
      position >= $0.start && position <= $0.end
    }) {
      settingsDisplayIndex = groupIdx
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

    // Explicit handling for the meta rows
    if case .spaces = current {
      selectedItem = .settings
      return
    }
    if case .settings = current, ejectAvailable {
      selectedItem = .eject
      return
    }
    if current == .settings || current == .eject {
      if !displayOrder.isEmpty {
        // Meta display set: ↓ off Eject continues the vertical crossing
        // from the meta display's bottom (wrapping past the far edge).
        if let metaDisplay = metaRowsDisplayUUID,
          let landing = verticalNeighborLanding(from: metaDisplay, direction: .down)
        {
          selectedItem = landing.item
          return
        }
        // Mode 3: go to next display group's first space
        let ranges = displayGroupRanges()
        let nextGroup = (settingsDisplayIndex + 1) % ranges.count
        settingsDisplayIndex = nextGroup
        // Find the first space item in the next group
        let start = ranges[nextGroup].start
        selectedItem = items[start]
      } else {
        // Mode 1/2: wrap to first space
        if let first = items.first(where: { spaceID(for: $0, using: map) != nil }) {
          selectedItem = first
        }
      }
      return
    }

    let currentSpace = spaceID(for: current, using: map)

    // Mode 3 with a known arrangement: at a display's last space, ↓ continues
    // onto the display physically BELOW, entering at its first space — the
    // crossing follows the arrangement, not displayOrder (which is MRU-led).
    // Past the bottom display it wraps to the top; no vertical axis at all
    // is a no-op.
    if !displayOrder.isEmpty, displayArrangement != nil, let currentSpace,
      let currentSection = filteredSections.first(where: { $0.id == currentSpace }),
      filteredSections.last(where: { $0.displayUUID == currentSection.displayUUID })?.id
        == currentSpace
    {
      // The meta display's panel ends with the Spaces, Settings, and Eject
      // rows — ↓ visits them before crossing off the display.
      if currentSection.displayUUID == metaRowsDisplayUUID {
        rememberSettingsGroup(containing: currentPos)
        selectedItem = .spaces
        return
      }
      if let landing = verticalNeighborLanding(
        from: currentSection.displayUUID, direction: .down)
      {
        selectedItem = landing.item
      }
      return
    }

    // In Mode 3, find the display group boundary so we stop at .spaces
    let groupEnd: Int?
    if !displayOrder.isEmpty {
      let ranges = displayGroupRanges()
      groupEnd = ranges.first(where: { currentPos <= $0.end })?.end
    } else {
      groupEnd = nil
    }

    // Scan forward for the first item in a different section, or a meta row
    for offset in 1..<items.count {
      let pos = (currentPos + offset) % items.count
      let item = items[pos]
      if case .settings = item {
        selectedItem = item
        return
      }
      if case .spaces = item {
        selectedItem = item
        return
      }
      if case .eject = item {
        selectedItem = item
        return
      }

      // In Mode 3, if we've crossed the group boundary, stop at .spaces
      if let end = groupEnd, pos > end {
        // Track which group we came from
        let ranges = displayGroupRanges()
        if let groupIdx = ranges.firstIndex(where: { $0.end == end }) {
          settingsDisplayIndex = groupIdx
        }
        selectedItem = .spaces
        return
      }

      let itemSpace = spaceID(for: item, using: map)
      guard itemSpace != nil else { continue }
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
      selectedItem = items.last
      return
    }

    // Eject → Settings → Spaces → last section
    if case .eject = current {
      selectedItem = .settings
      return
    }
    if case .settings = current {
      selectedItem = .spaces
      return
    }
    if case .spaces = current {
      // Find the last section's first item in the current display group
      let searchEnd: Int
      if !displayOrder.isEmpty {
        let ranges = displayGroupRanges()
        searchEnd = ranges[settingsDisplayIndex].end
      } else {
        // Find last item before .spaces
        searchEnd = (currentPos - 1 + items.count) % items.count
      }
      var lastSpace: UInt64?
      var lastPos: Int?
      for i in stride(from: searchEnd, through: 0, by: -1) {
        let item = items[i]
        if let space = spaceID(for: item, using: map) {
          if lastSpace == nil { lastSpace = space }
          if space == lastSpace { lastPos = i } else { break }
        }
      }
      if let pos = lastPos { selectedItem = items[pos] }
      return
    }

    let currentSpace = spaceID(for: current, using: map)

    // Mode 3 with a known arrangement: at a display's first space, ↑ continues
    // onto the display physically ABOVE, entering at its last space. Past the
    // top display it wraps to the bottom; no vertical axis at all is a no-op.
    if !displayOrder.isEmpty, displayArrangement != nil, let currentSpace,
      let currentSection = filteredSections.first(where: { $0.id == currentSpace }),
      filteredSections.first(where: { $0.displayUUID == currentSection.displayUUID })?.id
        == currentSpace
    {
      if let landing = verticalNeighborLanding(
        from: currentSection.displayUUID, direction: .up)
      {
        // Entering the meta display from below lands on its bottom-most
        // offered row first: Eject (when shown), then Settings, then
        // Spaces, then its last space.
        if landing.displayUUID == metaRowsDisplayUUID {
          if let pos = items.firstIndex(of: landing.item) {
            rememberSettingsGroup(containing: pos)
          }
          selectedItem = bottomMetaRow
        } else {
          selectedItem = landing.item
        }
      } else if currentSection.displayUUID == metaRowsDisplayUUID {
        // Nothing above (single display, or no vertical axis): the meta
        // display's carousel wraps through its own bottom rows — mirrors
        // ↓'s fallback, which wraps from the bottom meta row to the first
        // space.
        rememberSettingsGroup(containing: currentPos)
        selectedItem = bottomMetaRow
      }
      return
    }

    // In Mode 3, find the display group boundary
    let groupStart: Int?
    if !displayOrder.isEmpty {
      let ranges = displayGroupRanges()
      groupStart = ranges.first(where: { currentPos >= $0.start && currentPos <= $0.end })?.start
    } else {
      groupStart = nil
    }

    // Scan backward for the first item in a different section or a meta row
    var targetSpace: UInt64?
    var targetPos: Int?
    for offset in 1..<items.count {
      let pos = (currentPos - offset + items.count) % items.count
      let item = items[pos]

      // Wrap-around: hitting the trailing meta-row stops means we wrapped
      // past the start of items. Associate with the LAST display group so the highlight
      // appears on the correct panel.
      if case .eject = item, targetSpace == nil {
        if !displayOrder.isEmpty {
          let ranges = displayGroupRanges()
          if !ranges.isEmpty { settingsDisplayIndex = ranges.count - 1 }
        }
        selectedItem = item
        return
      }
      if case .settings = item, targetSpace == nil {
        if !displayOrder.isEmpty {
          let ranges = displayGroupRanges()
          if !ranges.isEmpty { settingsDisplayIndex = ranges.count - 1 }
        }
        selectedItem = item
        return
      }
      if case .spaces = item, targetSpace == nil {
        if !displayOrder.isEmpty {
          let ranges = displayGroupRanges()
          if !ranges.isEmpty { settingsDisplayIndex = ranges.count - 1 }
        }
        selectedItem = item
        return
      }
      if case .eject = item { break }
      if case .settings = item { break }
      if case .spaces = item { break }

      // In Mode 3, if we've crossed the group boundary going backward, stop at the
      // bottom meta row of the PREVIOUS display group (mirrors moveToNextSpace which
      // stops at .spaces of the current group when crossing forward).
      if let start = groupStart, pos < start, targetSpace == nil {
        let ranges = displayGroupRanges()
        if let prevGroupIdx = ranges.firstIndex(where: { pos >= $0.start && pos <= $0.end }) {
          settingsDisplayIndex = prevGroupIdx
        }
        selectedItem = bottomMetaRow
        return
      }
      let itemSpace = spaceID(for: item, using: map)
      guard let space = itemSpace else { continue }
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

  // MARK: - Sort Order Cycling

  /// Cycles to the next sort order and refreshes sections.
  public func cycleSortOrder() {
    let all = SpaceSortOrder.allCases
    guard let idx = all.firstIndex(of: spaceSortOrder) else { return }
    let nextIdx = (idx + 1) % all.count
    spaceSortOrder = all[nextIdx]

    let savedSelection = selectedItem
    refresh()
    selectedItem = savedSelection

    sortOverlayText = "Sorting: \(spaceSortOrder.label)"
    sortOverlayGeneration += 1
  }

  // MARK: - Multi-Panel Display Navigation

  /// Returns the display UUID of the section containing the currently selected item.
  public var activeDisplayUUID: String? {
    switch selectedItem {
    case .spaces, .settings, .eject, nil:
      return nil
    default:
      return panelDisplayUUID(for: selectedItem)
    }
  }

  /// Returns the display UUID of the panel that renders the given item — the
  /// panel that must be the key window for keyboard input (e.g. inline rename)
  /// to reach it. Unlike `activeDisplayUUID`, meta rows resolve to the panel
  /// that hosts them.
  public func panelDisplayUUID(for item: SelectedItem?) -> String? {
    switch item {
    case .spaceHeader(let spaceID):
      return filteredSections.first(where: { $0.id == spaceID })?.displayUUID
    case .windowRow(let windowID):
      return filteredSections.first(where: { $0.windows.contains(where: { $0.id == windowID }) })?
        .displayUUID
    case .spaces, .settings, .eject:
      return metaRowsDisplayUUID
    case nil:
      return nil
    }
  }

  /// Returns the display UUID the user was navigating when they reached
  /// a meta row. Falls back to activeDisplayUUID for normal items.
  public var contextDisplayUUID: String? {
    if let uuid = activeDisplayUUID { return uuid }
    // When on a meta row, use the display group we came from
    guard !displayOrder.isEmpty else {
      // Mode 1/2: use the first section's display (or focused display)
      return filteredSections.first?.displayUUID
    }
    // Mode 3: settingsDisplayIndex tracks which group
    guard settingsDisplayIndex < displayOrder.count else { return displayOrder.first }
    return displayOrder[settingsDisplayIndex]
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
      let targetDisplay = filteredSections.first(where: {
        $0.windows.contains(where: { $0.id == id })
      })?.displayUUID
      warpCursorIfNeeded(targetDisplayUUID: targetDisplay, windowID: id)
    case .spaceHeader(let spaceID):
      guard let section = filteredSections.first(where: { $0.id == spaceID })
      else {
        Diagnostics.log("activate", "spaceHeader \(spaceID) not in filteredSections; ignoring")
        return
      }
      warpCursorIfNeeded(
        targetDisplayUUID: section.displayUUID, windowID: section.windows.first?.id)
      if let firstWindow = section.windows.first {
        // Activate the first window in this space to trigger space switch
        windowID = firstWindow.id
      } else {
        // Empty space — see activateSpace(id:) for the MRU stamping rationale.
        activateSpace(id: spaceID)
        return
      }
    case .spaces, .settings, .eject, nil:
      return
    }

    windowMRUHistory.removeAll { $0 == windowID }
    windowMRUHistory.insert(windowID, at: 0)
    do {
      try spaceManager.activateWindow(id: windowID)
    } catch {
      Diagnostics.log("activate", "window \(windowID) failed: \(error)")
    }
  }

  /// Activates a Space and stamps it into the space MRU history. Focus-based
  /// inference in refresh() cannot see a switch to an empty Space — there is
  /// no window to move keyboard focus to its display — so every programmatic
  /// switch (panel header activation, the create-space flow) must route
  /// through here for the panel's recency ordering to hold. The stamp happens
  /// regardless of whether the underlying switch succeeds, matching the
  /// optimistic ordering activateSelected applies for windows.
  public func activateSpace(id spaceID: UInt64) {
    stampSpaceMRU(spaceID)
    do {
      try spaceManager.activateSpace(id: spaceID)
    } catch {
      Diagnostics.log("activate", "space \(spaceID) failed: \(error)")
    }
  }

  private func stampSpaceMRU(_ spaceID: UInt64) {
    spaceMRUHistory.removeAll { $0 == spaceID }
    spaceMRUHistory.insert(spaceID, at: 0)
  }

  /// Warps the cursor onto the activated window when the cursor-warp setting
  /// is on and `CursorWarpPlanner` says so (issue #17). Cursor position is
  /// global and display-scoped, not Space-scoped, so this needn't wait out any
  /// Space-switch animation.
  private func warpCursorIfNeeded(targetDisplayUUID: String?, windowID: Int?) {
    // Gate on the setting before the planner so the window-list read below
    // is skipped entirely when the feature is off.
    guard warpCursorOnActivation else { return }
    let destination = CursorWarpPlanner.destination(
      cursorPosition: SpaceManager.cursorPosition(),
      cursorDisplayUUID: SpaceManager.cursorDisplayUUID(),
      targetDisplayUUID: targetDisplayUUID,
      windowFrame: windowID.flatMap { spaceManager.windowBounds(forWindowID: $0) })
    switch destination {
    case .windowCenter(let point):
      SpaceManager.warpCursor(to: point)
    case .displayCenter(let displayUUID):
      if let displayID = SpaceManager.displayIDForUUID(displayUUID) {
        SpaceManager.warpCursorToDisplayCenter(displayID)
      }
    case nil:
      break
    }
  }

  // MARK: - Move Window to Space

  /// Toggles move mode. If a window row is selected, marks it for moving.
  public func toggleMoveMode() {
    if moveMode {
      cancelMoveMode()
      return
    }

    guard case .windowRow(let windowID) = selectedItem else { return }
    if spaceMoveMode { cancelSpaceMoveMode() }

    let spaceID = filteredSections.first(where: {
      $0.windows.contains(where: { $0.id == windowID })
    })?.id

    markedWindowID = windowID
    markedWindowSpaceID = spaceID
    moveMode = true
  }

  /// Visually moves the marked window to the next space in the list.
  public func moveMarkedWindowToNextSpace() {
    guard moveMode, let windowID = markedWindowID else { return }
    moveMarkedWindowToAdjacentSpace(forward: true, windowID: windowID)
  }

  /// Visually moves the marked window to the previous space in the list.
  public func moveMarkedWindowToPreviousSpace() {
    guard moveMode, let windowID = markedWindowID else { return }
    moveMarkedWindowToAdjacentSpace(forward: false, windowID: windowID)
  }

  /// Visually moves the marked window to the first section of the next display.
  /// Display-cycle counterpart to moveMarkedWindowToNextSpace, so Cmd+Left/Right
  /// stay usable inside move mode (issue #18).
  public func moveMarkedWindowToNextDisplay() {
    moveMarkedWindowToAdjacentDisplay(forward: true)
  }

  /// Visually moves the marked window to the first section of the previous display.
  public func moveMarkedWindowToPreviousDisplay() {
    moveMarkedWindowToAdjacentDisplay(forward: false)
  }

  /// Moves the marked window row toward the display in `direction` on the
  /// physical arrangement, wrapping past the far edge. No-op when no display
  /// lies on that axis (or the target has no visible section to receive the
  /// row); falls back to cycling when no arrangement is available.
  public func moveMarkedWindow(inDirection direction: ArrangementDirection) {
    guard moveMode, let windowID = markedWindowID,
      let sourceIdx = sections.firstIndex(where: {
        $0.windows.contains(where: { $0.id == windowID })
      })
    else { return }

    guard let arrangement = displayArrangement else {
      moveMarkedWindowToAdjacentDisplay(
        forward: direction == .right || direction == .down)
      return
    }

    guard
      let targetUUID = arrangement.wrappedNeighborUUID(
        of: sections[sourceIdx].displayUUID, direction: direction),
      let targetIdx = sections.firstIndex(where: { $0.displayUUID == targetUUID })
    else { return }
    moveMarkedWindowRow(windowID: windowID, from: sourceIdx, to: targetIdx)
  }

  private func moveMarkedWindowToAdjacentDisplay(forward: Bool) {
    guard moveMode, let windowID = markedWindowID,
      let sourceIdx = sections.firstIndex(where: {
        $0.windows.contains(where: { $0.id == windowID })
      })
    else { return }
    let currentDisplay = sections[sourceIdx].displayUUID

    // Display cycle in CGS order — the same cycle space-move mode uses.
    var displays: [String] = []
    for space in spaceManager.getAllSpaces() where !displays.contains(space.displayUUID) {
      displays.append(space.displayUUID)
    }
    guard displays.count > 1, let position = displays.firstIndex(of: currentDisplay)
    else { return }

    // First display in cycle order (skipping any with no visible section)
    // that can actually receive the row.
    let step = forward ? 1 : -1
    var targetIdx: Int?
    for i in 1..<displays.count {
      let candidate = displays[
        ((position + i * step) % displays.count + displays.count) % displays.count]
      if let idx = sections.firstIndex(where: { $0.displayUUID == candidate }) {
        targetIdx = idx
        break
      }
    }
    guard let targetIdx else { return }
    moveMarkedWindowRow(windowID: windowID, from: sourceIdx, to: targetIdx)
  }

  private func moveMarkedWindowRow(windowID: Int, from sourceIdx: Int, to targetIdx: Int) {
    guard let rowIdx = sections[sourceIdx].windows.firstIndex(where: { $0.id == windowID })
    else { return }

    var updated = sections
    let row = updated[sourceIdx].windows.remove(at: rowIdx)
    updated[targetIdx].windows.insert(row, at: 0)
    sections = updated

    selectedItem = .windowRow(windowID)
  }

  private func moveMarkedWindowToAdjacentSpace(forward: Bool, windowID: Int) {
    // Mode 3 with an arrangement: stepping past the window's display boundary
    // crosses to the physically adjacent display (wrapping past the far
    // edge), mirroring moveToNextSpace/moveToPreviousSpace — the flat scan
    // below would land on whichever group displayOrder puts next, which
    // needn't be the display below/above. With no display on the vertical
    // axis, the step wraps within the display's own spaces.
    if !displayOrder.isEmpty, let arrangement = displayArrangement,
      let currentSection = filteredSections.first(where: {
        $0.windows.contains(where: { $0.id == windowID })
      })
    {
      let displaySections = filteredSections.filter {
        $0.displayUUID == currentSection.displayUUID
      }
      let boundary = forward ? displaySections.last : displaySections.first
      if boundary?.id == currentSection.id {
        let targetUUID =
          arrangement.wrappedNeighborUUID(
            of: currentSection.displayUUID, direction: forward ? .down : .up)
          ?? currentSection.displayUUID
        let targetSections = filteredSections.filter { $0.displayUUID == targetUUID }
        guard let target = forward ? targetSections.first : targetSections.last,
          target.id != currentSection.id,
          let sourceIdx = sections.firstIndex(where: { $0.id == currentSection.id }),
          let targetIdx = sections.firstIndex(where: { $0.id == target.id })
        else { return }
        moveMarkedWindowRow(windowID: windowID, from: sourceIdx, to: targetIdx)
        return
      }
    }

    // Use the same navigation as moveToNextSpace/moveToPreviousSpace:
    // scan through flatSelectableItems to find the next/previous space,
    // then move the window row to that space in sections.
    let items = flatSelectableItems
    guard !items.isEmpty else { return }

    let map = windowSpaceMap()
    let currentSpaceID = map[windowID]

    // Find the window's current position in flatSelectableItems
    guard let currentPos = items.firstIndex(of: .windowRow(windowID)) else { return }

    // Scan for the first item in a different space (same logic as moveToNextSpace)
    var targetSpaceID: UInt64?
    let step = forward ? 1 : -1
    for i in 1..<items.count {
      let pos = (currentPos + i * step + items.count) % items.count
      let item = items[pos]
      // Skip the meta rows — wrap through them
      if case .spaces = item { continue }
      if case .settings = item { continue }
      if case .eject = item { continue }
      let itemSpace = spaceID(for: item, using: map)
      if let itemSpace, itemSpace != currentSpaceID {
        targetSpaceID = itemSpace
        break
      }
    }

    guard let targetSpaceID else { return }

    // Move the window row from its current section to the target section
    guard
      let sourceIdx = sections.firstIndex(where: {
        $0.windows.contains(where: { $0.id == windowID })
      }),
      let targetIdx = sections.firstIndex(where: { $0.id == targetSpaceID }),
      let rowIdx = sections[sourceIdx].windows.firstIndex(where: { $0.id == windowID })
    else { return }

    var updated = sections
    let row = updated[sourceIdx].windows.remove(at: rowIdx)
    updated[targetIdx].windows.insert(row, at: 0)
    sections = updated

    selectedItem = .windowRow(windowID)
  }

  /// Executes the move: moves the marked window to whatever space it's currently shown in.
  /// Returns `true` if a move was initiated.
  @discardableResult
  public func executeMoveWindow() -> Bool {
    guard moveMode, let windowID = markedWindowID else { return false }

    // Find which space the window is currently shown in (after visual moves)
    let targetSpaceID = sections.first(where: {
      $0.windows.contains(where: { $0.id == windowID })
    })?.id

    guard let targetSpaceID, targetSpaceID != markedWindowSpaceID else {
      cancelMoveMode()
      return false
    }

    let moveWindowID = windowID
    let moveTargetSpaceID = targetSpaceID
    cancelMoveMode()

    let activateAfterMove = activateMovedItem
    DispatchQueue.global(qos: .userInteractive).async { [spaceManager] in
      do {
        try spaceManager.moveWindowToSpace(
          windowID: moveWindowID, targetSpaceID: moveTargetSpaceID,
          activateAfterMove: activateAfterMove)
      } catch {
        Diagnostics.log(
          "move-window", "window \(moveWindowID) to space \(moveTargetSpaceID) failed: \(error)")
      }
    }

    return true
  }

  /// Cancels move mode and clears all move-related state.
  public func cancelMoveMode() {
    moveMode = false
    markedWindowID = nil
    markedWindowSpaceID = nil
  }

  // MARK: - Move Space to Display

  /// Toggles space-move mode. Marks the selected space header's space — or the
  /// space containing the selected window row — for moving to another display.
  /// No-op when fewer than two displays exist or the space is not a desktop.
  public func toggleSpaceMoveMode() {
    if spaceMoveMode {
      cancelSpaceMoveMode()
      return
    }

    let spaceID: UInt64?
    switch selectedItem {
    case .spaceHeader(let id):
      spaceID = id
    case .windowRow(let windowID):
      spaceID =
        filteredSections.first(where: {
          $0.windows.contains(where: { $0.id == windowID })
        })?.id
    default:
      spaceID = nil
    }

    guard let spaceID,
      let section = sections.first(where: { $0.id == spaceID })
    else { return }

    // A display's Default Space is pinned: it exists so the display always
    // keeps an anchor space, so moving it away would defeat its purpose.
    // Renaming it is the deliberate way to unpin it.
    if spaceNameStore.customName(forSpaceUUID: section.spaceUUID)
      == SpaceNameStore.defaultSpaceName
    {
      sortOverlayText = "\(SpaceNameStore.defaultSpaceName) is pinned to its display"
      sortOverlayGeneration += 1
      return
    }

    // Only desktop spaces can be moved; the display cycle needs somewhere to go.
    let allSpaces = spaceManager.getAllSpaces()
    guard allSpaces.first(where: { $0.id == spaceID })?.type == .desktop else { return }

    let nameByUUID = Dictionary(
      sections.map { ($0.displayUUID, $0.displayName) },
      uniquingKeysWith: { first, _ in first })
    var displays: [(uuid: String, name: String)] = []
    for space in allSpaces where !displays.contains(where: { $0.uuid == space.displayUUID }) {
      displays.append((space.displayUUID, nameByUUID[space.displayUUID] ?? ""))
    }
    guard displays.count > 1 else { return }

    if moveMode { cancelMoveMode() }
    markedSpaceID = spaceID
    markedSpaceOriginDisplayUUID = section.displayUUID
    spaceMoveDisplays = displays
    spaceMoveMode = true
    selectedItem = .spaceHeader(spaceID)
  }

  /// Visually retargets the marked space to the next display in the cycle.
  public func moveMarkedSpaceToNextDisplay() {
    retargetMarkedSpace(offset: 1)
  }

  /// Visually retargets the marked space to the previous display in the cycle.
  public func moveMarkedSpaceToPreviousDisplay() {
    retargetMarkedSpace(offset: -1)
  }

  /// Retargets the marked space toward the display in `direction` on the
  /// physical arrangement, wrapping past the far edge. No-op when no display
  /// lies on that axis; falls back to cycling when no arrangement is
  /// available.
  public func moveMarkedSpace(inDirection direction: ArrangementDirection) {
    guard spaceMoveMode, let spaceID = markedSpaceID,
      let sectionIndex = sections.firstIndex(where: { $0.id == spaceID })
    else { return }

    guard let arrangement = displayArrangement else {
      retargetMarkedSpace(offset: direction == .right || direction == .down ? 1 : -1)
      return
    }

    guard
      let targetUUID = arrangement.wrappedNeighborUUID(
        of: sections[sectionIndex].displayUUID, direction: direction),
      let target = spaceMoveDisplays.first(where: { $0.uuid == targetUUID })
    else { return }
    retargetMarkedSpace(to: target, sectionIndex: sectionIndex)
  }

  /// Retags the marked section with the adjacent display in the cycle. The
  /// per-display panels filter sections by `displayUUID`, so retagging is what
  /// visually moves the section between displays.
  private func retargetMarkedSpace(offset: Int) {
    guard spaceMoveMode, let spaceID = markedSpaceID,
      let sectionIndex = sections.firstIndex(where: { $0.id == spaceID }),
      !spaceMoveDisplays.isEmpty,
      let position = spaceMoveDisplays.firstIndex(where: {
        $0.uuid == sections[sectionIndex].displayUUID
      })
    else { return }

    let count = spaceMoveDisplays.count
    retargetMarkedSpace(
      to: spaceMoveDisplays[(position + offset + count) % count],
      sectionIndex: sectionIndex)
  }

  private func retargetMarkedSpace(
    to next: (uuid: String, name: String), sectionIndex: Int
  ) {
    let old = sections[sectionIndex]
    sections[sectionIndex] = SwitcherSection(
      id: old.id,
      spaceUUID: old.spaceUUID,
      displayUUID: next.uuid,
      displayName: next.name,
      label: old.label,
      isCurrent: old.isCurrent,
      ordinalLabel: old.ordinalLabel,
      windows: old.windows)
    selectedItem = .spaceHeader(old.id)
  }

  /// Executes the move: relocates the marked space to whatever display its
  /// section is currently shown on. Returns `true` if a move was initiated.
  @discardableResult
  public func executeMoveSpace() -> Bool {
    guard spaceMoveMode, let spaceID = markedSpaceID,
      let section = sections.first(where: { $0.id == spaceID })
    else { return false }

    let targetDisplayUUID = section.displayUUID
    let originDisplayUUID = markedSpaceOriginDisplayUUID
    cancelSpaceMoveMode()

    guard targetDisplayUUID != originDisplayUUID else { return false }

    let activateAfterMove = activateMovedItem
    if activateAfterMove {
      // The post-move activation happens deep inside SpaceManager (a Mission
      // Control tile press), which focus inference in refresh() may never
      // see — an activated space needn't take keyboard focus. Stamp the MRU
      // here so the next panel open shows the moved space as most recent.
      stampSpaceMRU(spaceID)
      pendingMoveStamp = (spaceID, originDisplayUUID)
    }
    let warpAfterMove = activateAfterMove && warpCursorOnActivation
    DispatchQueue.global(qos: .userInteractive).async { [spaceManager] in
      do {
        let moved = try spaceManager.moveSpaceToDisplay(
          spaceID: spaceID, targetDisplayUUID: targetDisplayUUID,
          activateAfterMove: activateAfterMove)
        // Center the cursor on the activated space's display. Deliberately
        // not routed through CursorWarpPlanner: there is no activated window
        // to aim at, and the MC drag already leaves the pointer on the target
        // display (at the drop point over the spaces bar), which the planner
        // would read as "already there" and leave alone.
        if moved && warpAfterMove,
          let displayID = SpaceManager.displayIDForUUID(targetDisplayUUID)
        {
          DispatchQueue.main.async {
            SpaceManager.warpCursorToDisplayCenter(displayID)
          }
        }
      } catch {
        Diagnostics.log(
          "move-space-display", "space \(spaceID) to \(targetDisplayUUID) failed: \(error)")
      }
    }

    return true
  }

  /// Cancels space-move mode and clears all related state. Any visual retag is
  /// restored on the next refresh, matching window-move-mode behavior.
  public func cancelSpaceMoveMode() {
    spaceMoveMode = false
    markedSpaceID = nil
    markedSpaceOriginDisplayUUID = nil
    spaceMoveDisplays = []
  }

  // MARK: - Close / Quit / Minimize

  /// Minimizes the currently selected window and advances to the next window,
  /// so the panel remains ready for another action.
  public func minimizeSelectedWindow() {
    guard case .windowRow(let windowID) = selectedItem else { return }
    let rowsBeforeMinimize = flatFilteredRows
    guard let selectedIndex = rowsBeforeMinimize.firstIndex(where: { $0.id == windowID }) else {
      return
    }
    let nextWindowID =
      rowsBeforeMinimize.count > 1
      ? rowsBeforeMinimize[(selectedIndex + 1) % rowsBeforeMinimize.count].id
      : nil

    do {
      try minimizeWindow(windowID)
      markWindowMinimized(windowID)
      if let nextWindowID {
        selectedItem = .windowRow(nextWindowID)
      }
    } catch {
      Diagnostics.log("window", "minimize \(windowID) failed: \(error)")
    }
  }

  /// Minimizes every non-minimized window in the selected Space, then leaves
  /// selection on that Space's header at the top of the group.
  public func minimizeSelectedSpace() {
    guard let spaceID = selectedSpaceID,
      let windows = sections.first(where: { $0.id == spaceID })?.windows
    else { return }

    for row in windows where !row.isMinimized {
      do {
        try minimizeWindow(row.id)
        markWindowMinimized(row.id)
      } catch {
        Diagnostics.log("window", "minimize \(row.id) failed: \(error)")
      }
    }
    selectedItem = .spaceHeader(spaceID)
  }

  private func markWindowMinimized(_ windowID: Int) {
    var updated = sections
    for sectionIndex in updated.indices {
      guard
        let rowIndex = updated[sectionIndex].windows.firstIndex(where: { $0.id == windowID })
      else { continue }

      var row = updated[sectionIndex].windows.remove(at: rowIndex)
      row.isMinimized = true
      updated[sectionIndex].windows.append(row)
    }
    sections = updated
  }

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
      // Own windows also linger in the window server, and AX can't inspect the
      // current process — tombstone directly so the row stays gone durably.
      spaceManager.markWindowClosed(id: windowID)
      removeWindowFromSections(windowID)
      return
    }

    do {
      try spaceManager.closeWindow(id: windowID)
    } catch {
      Diagnostics.log("window", "close \(windowID) failed: \(error)")
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
      Diagnostics.log("window", "quit app for window \(windowID) failed: \(error)")
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

  private func reorderByMRU(_ windows: [WindowInfo]) -> [WindowInfo] {
    let ordered: [WindowInfo]
    if windowMRUHistory.isEmpty {
      ordered = windows
    } else {
      var mruRank: [Int: Int] = [:]
      for (index, wid) in windowMRUHistory.enumerated() {
        mruRank[wid] = index
      }
      let maxRank = windowMRUHistory.count
      ordered = windows.enumerated().sorted { a, b in
        let aRank = mruRank[a.element.id] ?? (maxRank + a.offset)
        let bRank = mruRank[b.element.id] ?? (maxRank + b.offset)
        return aRank < bRank
      }.map(\.element)
    }
    return ordered.filter { !$0.isMinimized } + ordered.filter(\.isMinimized)
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
      isSticky: window.isSticky,
      isMinimized: window.isMinimized
    )
  }
}
