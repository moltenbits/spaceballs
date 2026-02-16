import CoreGraphics
import Testing

@testable import SpacebarCore
@testable import SpacebarGUILib

// MARK: - Mock Data Source

struct MockDataSource: SystemDataSource {
  var displaySpaces: [[String: Any]] = []
  var windowList: [[String: Any]] = []
  var windowSpaces: [Int: [UInt64]] = [:]

  func fetchManagedDisplaySpaces() -> [[String: Any]] {
    displaySpaces
  }

  func fetchWindowList() -> [[String: Any]] {
    windowList
  }

  func fetchSpacesForWindow(_ windowID: Int) -> [UInt64] {
    windowSpaces[windowID] ?? []
  }
}

// MARK: - Helpers

private func makeBoundsDict(x: Double, y: Double, width: Double, height: Double) -> CFDictionary {
  CGRectCreateDictionaryRepresentation(CGRect(x: x, y: y, width: width, height: height))
}

private func makeSpaceDict(id: Int, uuid: String = "space-uuid", type: Int = 0) -> [String: Any] {
  ["ManagedSpaceID": id, "uuid": uuid, "type": type]
}

private func makeDisplayDict(
  displayUUID: String,
  spaces: [[String: Any]],
  currentSpaceID: Int
) -> [String: Any] {
  [
    "Display Identifier": displayUUID,
    "Spaces": spaces,
    "Current Space": ["ManagedSpaceID": currentSpaceID],
  ]
}

private func makeWindowDict(
  id: Int,
  ownerName: String,
  name: String? = nil,
  pid: Int = 100,
  layer: Int = 0,
  bounds: CFDictionary? = nil
) -> [String: Any] {
  let defaultBounds = makeBoundsDict(x: 0, y: 0, width: 800, height: 600)
  var dict: [String: Any] = [
    "kCGWindowNumber": id,
    "kCGWindowOwnerName": ownerName,
    "kCGWindowOwnerPID": pid,
    "kCGWindowLayer": layer,
    "kCGWindowBounds": bounds ?? defaultBounds,
  ]
  if let name {
    dict["kCGWindowName"] = name
  }
  return dict
}

/// Creates a mock data source with two spaces and windows in a known Z-order.
/// Window list order = front-to-back = MRU order.
private func makeTwoSpaceDataSource() -> MockDataSource {
  var ds = MockDataSource()
  ds.displaySpaces = [
    makeDisplayDict(
      displayUUID: "display-1",
      spaces: [
        makeSpaceDict(id: 1, uuid: "uuid-1"),
        makeSpaceDict(id: 2, uuid: "uuid-2"),
      ],
      currentSpaceID: 1
    )
  ]
  // Window Z-order: frontmost first.
  // Window 20 (Space 2) is frontmost → Space 2 is MRU.
  ds.windowList = [
    makeWindowDict(id: 20, ownerName: "Terminal", name: "bash", pid: 200),
    makeWindowDict(id: 10, ownerName: "Safari", name: "Google", pid: 100),
    makeWindowDict(id: 11, ownerName: "Safari", name: "GitHub", pid: 100),
  ]
  ds.windowSpaces = [
    20: [2],
    10: [1],
    11: [1],
  ]
  return ds
}

// MARK: - MRU Ordering Tests

@Suite("MRU Ordering")
struct MRUOrderingTests {

  @Test("Current space is first, then Z-order for remaining")
  func spaceMRUOrder() {
    let ds = makeTwoSpaceDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    #expect(vm.sections.count == 2)
    // Space 1 is current → first, even though Space 2 has frontmost window
    #expect(vm.sections[0].id == 1)
    #expect(vm.sections[1].id == 2)
  }

  @Test("Current space first, then remaining by Z-order")
  func currentSpaceThenZOrder() {
    var ds = MockDataSource()
    ds.displaySpaces = [
      makeDisplayDict(
        displayUUID: "display-1",
        spaces: [
          makeSpaceDict(id: 1, uuid: "uuid-1"),
          makeSpaceDict(id: 2, uuid: "uuid-2"),
          makeSpaceDict(id: 3, uuid: "uuid-3"),
        ],
        currentSpaceID: 2
      )
    ]
    // Window 30 on Space 3 is frontmost in Z-order
    ds.windowList = [
      makeWindowDict(id: 30, ownerName: "Code", name: "main.swift", pid: 300),
      makeWindowDict(id: 10, ownerName: "Safari", name: "Google", pid: 100),
      makeWindowDict(id: 20, ownerName: "Terminal", name: "bash", pid: 200),
    ]
    ds.windowSpaces = [30: [3], 10: [1], 20: [2]]

    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    // Space 2 is current → first. Then Z-order: Space 3, Space 1
    #expect(vm.sections[0].id == 2)
    #expect(vm.sections[1].id == 3)
    #expect(vm.sections[2].id == 1)
  }

  @Test("Spaces with no windows are appended at the end")
  func emptySpacesAtEnd() {
    var ds = MockDataSource()
    ds.displaySpaces = [
      makeDisplayDict(
        displayUUID: "display-1",
        spaces: [
          makeSpaceDict(id: 1, uuid: "uuid-1"),
          makeSpaceDict(id: 2, uuid: "uuid-2"),
          makeSpaceDict(id: 3, uuid: "uuid-3"),
        ],
        currentSpaceID: 1
      )
    ]
    ds.windowList = [
      makeWindowDict(id: 10, ownerName: "Safari", name: "Google", pid: 100)
    ]
    ds.windowSpaces = [10: [1]]

    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    // Space 1 has windows → included. Spaces 2 and 3 have no windows → omitted.
    #expect(vm.sections.count == 1)
    #expect(vm.sections[0].id == 1)
    #expect(vm.sections[0].windows.count == 1)
  }

  @Test("Section labels use ordinal numbering")
  func sectionLabels() {
    let ds = makeTwoSpaceDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    // Space 1 is current → first. Ordinals match display order.
    #expect(vm.sections[0].label == "Desktop 1")
    #expect(vm.sections[1].label == "Desktop 2")
  }

  @Test("Fullscreen space label includes app name")
  func fullscreenLabel() {
    var ds = MockDataSource()
    ds.displaySpaces = [
      makeDisplayDict(
        displayUUID: "display-1",
        spaces: [
          makeSpaceDict(id: 1, uuid: "uuid-1", type: 4)  // fullscreen
        ],
        currentSpaceID: 1
      )
    ]
    ds.windowList = [
      makeWindowDict(id: 10, ownerName: "Keynote", name: "Presentation", pid: 100)
    ]
    ds.windowSpaces = [10: [1]]

    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    #expect(vm.sections[0].label == "Fullscreen — Keynote")
  }

  @Test("Current space is marked from CGS API")
  func currentSpaceMarked() {
    let ds = makeTwoSpaceDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    // Space 1 is current per CGS API
    let space1 = vm.sections.first(where: { $0.id == 1 })
    let space2 = vm.sections.first(where: { $0.id == 2 })
    #expect(space1?.isCurrent == true)
    #expect(space2?.isCurrent == false)
  }
}

// MARK: - Window MRU Ordering Tests

@Suite("Window MRU Ordering")
struct WindowMRUOrderingTests {

  @Test("Activated window moves to front within its space")
  func activatedWindowMovesToFront() {
    let ds = makeTwoSpaceDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    // Space 1 has windows [10, 11] in Z-order
    let space1 = vm.sections.first(where: { $0.id == 1 })!
    #expect(space1.windows[0].id == 10)
    #expect(space1.windows[1].id == 11)

    // Activate window 11 (second in Z-order)
    vm.selectedRowID = 11
    vm.activateSelected()

    // Refresh to rebuild sections with MRU ordering
    vm.refresh()

    let space1After = vm.sections.first(where: { $0.id == 1 })!
    #expect(space1After.windows[0].id == 11)  // now first
    #expect(space1After.windows[1].id == 10)
  }

  @Test("MRU ordering persists across refreshes")
  func mruPersistsAcrossRefreshes() {
    var ds = MockDataSource()
    ds.displaySpaces = [
      makeDisplayDict(
        displayUUID: "display-1",
        spaces: [makeSpaceDict(id: 1, uuid: "uuid-1")],
        currentSpaceID: 1
      )
    ]
    ds.windowList = [
      makeWindowDict(id: 10, ownerName: "Safari", name: "Google", pid: 100),
      makeWindowDict(id: 11, ownerName: "Safari", name: "GitHub", pid: 100),
      makeWindowDict(id: 12, ownerName: "Safari", name: "Reddit", pid: 100),
    ]
    ds.windowSpaces = [10: [1], 11: [1], 12: [1]]

    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    // Original Z-order: [10, 11, 12]
    #expect(vm.sections[0].windows.map(\.id) == [10, 11, 12])

    // Activate 12, then 11
    vm.selectedRowID = 12
    vm.activateSelected()
    vm.selectedRowID = 11
    vm.activateSelected()

    vm.refresh()

    // MRU order: 11 (most recent), 12, then 10 (never activated)
    #expect(vm.sections[0].windows.map(\.id) == [11, 12, 10])
  }

  @Test("Windows not in MRU keep Z-order")
  func untrackedWindowsKeepZOrder() {
    var ds = MockDataSource()
    ds.displaySpaces = [
      makeDisplayDict(
        displayUUID: "display-1",
        spaces: [makeSpaceDict(id: 1, uuid: "uuid-1")],
        currentSpaceID: 1
      )
    ]
    ds.windowList = [
      makeWindowDict(id: 10, ownerName: "Safari", name: "Google", pid: 100),
      makeWindowDict(id: 11, ownerName: "Safari", name: "GitHub", pid: 100),
      makeWindowDict(id: 12, ownerName: "Safari", name: "Reddit", pid: 100),
    ]
    ds.windowSpaces = [10: [1], 11: [1], 12: [1]]

    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    // Activate only window 12
    vm.selectedRowID = 12
    vm.activateSelected()

    vm.refresh()

    // Window 12 first (MRU), then 10 and 11 in original Z-order
    #expect(vm.sections[0].windows.map(\.id) == [12, 10, 11])
  }
}

// MARK: - Search Filtering Tests

@Suite("Search Filtering")
struct SearchFilteringTests {

  @Test("Empty search returns all sections")
  func emptySearch() {
    let ds = makeTwoSpaceDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    #expect(vm.filteredSections.count == 2)
  }

  @Test("Search by app name filters rows")
  func searchByAppName() {
    let ds = makeTwoSpaceDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    vm.searchText = "Safari"
    let filtered = vm.filteredSections

    #expect(filtered.count == 1)
    #expect(filtered[0].id == 1)  // Space 1 has Safari windows
    #expect(filtered[0].windows.count == 2)
  }

  @Test("Search by window title filters rows")
  func searchByTitle() {
    let ds = makeTwoSpaceDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    vm.searchText = "bash"
    let filtered = vm.filteredSections

    #expect(filtered.count == 1)
    #expect(filtered[0].windows.count == 1)
    #expect(filtered[0].windows[0].appName == "Terminal")
  }

  @Test("Search is case insensitive")
  func caseInsensitive() {
    let ds = makeTwoSpaceDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    vm.searchText = "SAFARI"
    #expect(vm.filteredSections.count == 1)

    vm.searchText = "safari"
    #expect(vm.filteredSections.count == 1)
  }

  @Test("Search with no matches returns empty")
  func noMatches() {
    let ds = makeTwoSpaceDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    vm.searchText = "nonexistent"
    #expect(vm.filteredSections.isEmpty)
  }

  @Test("Sections with no matching windows are excluded")
  func sectionsExcluded() {
    let ds = makeTwoSpaceDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    vm.searchText = "Terminal"
    let filtered = vm.filteredSections

    // Only Space 2 (Terminal) should remain
    #expect(filtered.count == 1)
    #expect(filtered[0].id == 2)
  }
}

// MARK: - Selection Navigation Tests

@Suite("Selection Navigation")
struct SelectionNavigationTests {

  @Test("moveSelectionDown selects first row when nothing selected")
  func moveDownFromNone() {
    let ds = makeTwoSpaceDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    vm.selectedRowID = nil
    vm.moveSelectionDown()

    // Space 1 is current → first. Window 10 is first row.
    #expect(vm.selectedRowID == 10)
  }

  @Test("moveSelectionDown advances through rows")
  func moveDownSequential() {
    let ds = makeTwoSpaceDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    // Order: Space 1 [10, 11], Space 2 [20]
    vm.selectedRowID = 10  // Space 1, window 10
    vm.moveSelectionDown()
    #expect(vm.selectedRowID == 11)  // Space 1, window 11

    vm.moveSelectionDown()
    #expect(vm.selectedRowID == 20)  // Space 2, window 20
  }

  @Test("moveSelectionDown wraps to top")
  func moveDownWraps() {
    let ds = makeTwoSpaceDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    vm.selectedRowID = 20  // last row
    vm.moveSelectionDown()
    #expect(vm.selectedRowID == 10)  // wraps to first
  }

  @Test("moveSelectionUp selects last row when nothing selected")
  func moveUpFromNone() {
    let ds = makeTwoSpaceDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    vm.selectedRowID = nil
    vm.moveSelectionUp()

    #expect(vm.selectedRowID == 20)  // last row
  }

  @Test("moveSelectionUp wraps to bottom")
  func moveUpWraps() {
    let ds = makeTwoSpaceDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    vm.selectedRowID = 10  // first row
    vm.moveSelectionUp()
    #expect(vm.selectedRowID == 20)  // wraps to last
  }

  @Test("resetSelection selects first row")
  func resetSelection() {
    let ds = makeTwoSpaceDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    vm.selectedRowID = 20  // some row
    vm.resetSelection()
    #expect(vm.selectedRowID == 10)  // first row (Space 1, current)
  }

  @Test("Navigation works with filtered results")
  func navigationWithFilter() {
    let ds = makeTwoSpaceDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    vm.searchText = "Safari"
    vm.selectedRowID = nil
    vm.moveSelectionDown()
    #expect(vm.selectedRowID == 10)  // first Safari window

    vm.moveSelectionDown()
    #expect(vm.selectedRowID == 11)  // second Safari window

    vm.moveSelectionDown()
    #expect(vm.selectedRowID == 10)  // wraps
  }

  @Test("Selection on empty results is a no-op")
  func emptyResultsNoOp() {
    let ds = MockDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    vm.moveSelectionDown()
    #expect(vm.selectedRowID == nil)

    vm.moveSelectionUp()
    #expect(vm.selectedRowID == nil)
  }
}

// MARK: - Refresh Tests

@Suite("Refresh Behavior")
struct RefreshTests {

  @Test("Refresh clears search text")
  func refreshClearsSearch() {
    let ds = makeTwoSpaceDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))

    vm.searchText = "something"
    vm.refresh()
    #expect(vm.searchText == "")
  }

  @Test("Refresh populates sections")
  func refreshPopulatesSections() {
    let ds = makeTwoSpaceDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))

    #expect(vm.sections.isEmpty)
    vm.refresh()
    #expect(!vm.sections.isEmpty)
  }

  @Test("Window rows have correct data")
  func windowRowData() {
    let ds = makeTwoSpaceDataSource()
    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    let terminalRow = vm.flatFilteredRows.first(where: { $0.id == 20 })
    #expect(terminalRow?.appName == "Terminal")
    #expect(terminalRow?.windowTitle == "bash")
    #expect(terminalRow?.pid == 200)
  }

  @Test("Sticky window is marked")
  func stickyWindowMarked() {
    var ds = MockDataSource()
    ds.displaySpaces = [
      makeDisplayDict(
        displayUUID: "display-1",
        spaces: [
          makeSpaceDict(id: 1, uuid: "uuid-1"),
          makeSpaceDict(id: 2, uuid: "uuid-2"),
        ],
        currentSpaceID: 1
      )
    ]
    ds.windowList = [
      makeWindowDict(id: 10, ownerName: "Finder", name: "Desktop", pid: 100)
    ]
    ds.windowSpaces = [10: [1, 2]]  // sticky — on both spaces

    let vm = SwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.refresh()

    let row = vm.flatFilteredRows.first(where: { $0.id == 10 })
    #expect(row?.isSticky == true)
  }
}
