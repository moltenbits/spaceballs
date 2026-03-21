import CoreGraphics
import Foundation
import Testing

@testable import SpacebarCore

// MARK: - Mock Data Source

struct MockDataSource: SystemDataSource {
  var displaySpaces: [[String: Any]] = []
  var windowList: [[String: Any]] = []
  var onScreenWindowList: [[String: Any]]?
  var windowSpaces: [Int: [UInt64]] = [:]

  func fetchManagedDisplaySpaces() -> [[String: Any]] {
    displaySpaces
  }

  func fetchWindowList() -> [[String: Any]] {
    windowList
  }

  func fetchOnScreenWindowList() -> [[String: Any]] {
    onScreenWindowList ?? windowList
  }

  func fetchSpacesForWindow(_ windowID: Int) -> [UInt64] {
    windowSpaces[windowID] ?? []
  }
}

// MARK: - Helpers

/// Creates a bounds dictionary matching what CGWindowListCopyWindowInfo returns.
func makeBoundsDict(x: Double, y: Double, width: Double, height: Double) -> CFDictionary {
  let rect = CGRect(x: x, y: y, width: width, height: height)
  return CGRectCreateDictionaryRepresentation(rect)
}

/// Creates a raw space dictionary matching CGSCopyManagedDisplaySpaces output.
private func makeSpaceDict(id: Int, uuid: String = "space-uuid", type: Int = 0) -> [String: Any] {
  ["ManagedSpaceID": id, "uuid": uuid, "type": type]
}

/// Creates a raw display dictionary with spaces and a current space.
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

/// Creates a raw window dictionary matching CGWindowListCopyWindowInfo output.
func makeWindowDict(
  id: Int,
  ownerName: String,
  name: String? = "Window",
  pid: Int = 100,
  layer: Int = 0,
  bounds: CFDictionary? = nil,
  isOnscreen: Bool = true
) -> [String: Any] {
  let defaultBounds = makeBoundsDict(x: 0, y: 0, width: 800, height: 600)
  var dict: [String: Any] = [
    "kCGWindowNumber": id,
    "kCGWindowOwnerName": ownerName,
    "kCGWindowOwnerPID": pid,
    "kCGWindowLayer": layer,
    "kCGWindowBounds": bounds ?? defaultBounds,
    "kCGWindowIsOnscreen": isOnscreen,
  ]
  if let name {
    dict["kCGWindowName"] = name
  }
  return dict
}

// MARK: - Space Parsing Tests

@Suite("Space Parsing")
struct SpaceParsingTests {

  @Test("Parses spaces from a single display")
  func parseSingleDisplay() {
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

    let manager = SpaceManager(dataSource: ds)
    let spaces = manager.getAllSpaces()

    #expect(spaces.count == 2)
    #expect(spaces[0].id == 1)
    #expect(spaces[0].uuid == "uuid-1")
    #expect(spaces[0].displayUUID == "display-1")
    #expect(spaces[0].isCurrent == true)
    #expect(spaces[1].id == 2)
    #expect(spaces[1].isCurrent == false)
  }

  @Test("Parses spaces from multiple displays")
  func parseMultipleDisplays() {
    var ds = MockDataSource()
    ds.displaySpaces = [
      makeDisplayDict(
        displayUUID: "display-1",
        spaces: [makeSpaceDict(id: 1)],
        currentSpaceID: 1
      ),
      makeDisplayDict(
        displayUUID: "display-2",
        spaces: [makeSpaceDict(id: 10), makeSpaceDict(id: 11)],
        currentSpaceID: 11
      ),
    ]

    let manager = SpaceManager(dataSource: ds)
    let spaces = manager.getAllSpaces()

    #expect(spaces.count == 3)

    let display1Spaces = spaces.filter { $0.displayUUID == "display-1" }
    let display2Spaces = spaces.filter { $0.displayUUID == "display-2" }
    #expect(display1Spaces.count == 1)
    #expect(display2Spaces.count == 2)

    #expect(display2Spaces.first { $0.id == 10 }?.isCurrent == false)
    #expect(display2Spaces.first { $0.id == 11 }?.isCurrent == true)
  }

  @Test("Detects space types correctly")
  func spaceTypes() {
    var ds = MockDataSource()
    ds.displaySpaces = [
      makeDisplayDict(
        displayUUID: "display-1",
        spaces: [
          makeSpaceDict(id: 1, type: 0),
          makeSpaceDict(id: 2, type: 4),
        ],
        currentSpaceID: 1
      )
    ]

    let manager = SpaceManager(dataSource: ds)
    let spaces = manager.getAllSpaces()

    #expect(spaces[0].type == .desktop)
    #expect(spaces[1].type == .fullscreen)
  }

  @Test("Unknown space type defaults to desktop")
  func unknownSpaceType() {
    var ds = MockDataSource()
    ds.displaySpaces = [
      makeDisplayDict(
        displayUUID: "display-1",
        spaces: [makeSpaceDict(id: 1, type: 99)],
        currentSpaceID: 1
      )
    ]

    let manager = SpaceManager(dataSource: ds)
    let spaces = manager.getAllSpaces()

    #expect(spaces.count == 1)
    #expect(spaces[0].type == .desktop)
  }

  @Test("Returns empty array when data source returns empty")
  func emptyData() {
    let ds = MockDataSource()
    let manager = SpaceManager(dataSource: ds)
    #expect(manager.getAllSpaces().isEmpty)
  }

  @Test("Skips malformed display entries")
  func malformedDisplayEntries() {
    var ds = MockDataSource()
    ds.displaySpaces = [
      // Missing "Display Identifier"
      ["Spaces": [[String: Any]](), "Current Space": ["ManagedSpaceID": 1]],
      // Missing "Spaces"
      ["Display Identifier": "d1", "Current Space": ["ManagedSpaceID": 1]],
      // Missing "Current Space"
      ["Display Identifier": "d1", "Spaces": [makeSpaceDict(id: 1)]],
      // Valid entry
      makeDisplayDict(
        displayUUID: "valid",
        spaces: [makeSpaceDict(id: 42)],
        currentSpaceID: 42
      ),
    ]

    let manager = SpaceManager(dataSource: ds)
    let spaces = manager.getAllSpaces()

    #expect(spaces.count == 1)
    #expect(spaces[0].id == 42)
  }

  @Test("Skips malformed space entries within a valid display")
  func malformedSpaceEntries() {
    var ds = MockDataSource()
    ds.displaySpaces = [
      makeDisplayDict(
        displayUUID: "display-1",
        spaces: [
          // Missing uuid
          ["ManagedSpaceID": 1, "type": 0],
          // Missing type
          ["ManagedSpaceID": 2, "uuid": "u2"],
          // Valid
          makeSpaceDict(id: 3, uuid: "u3"),
        ],
        currentSpaceID: 3
      )
    ]

    let manager = SpaceManager(dataSource: ds)
    let spaces = manager.getAllSpaces()

    #expect(spaces.count == 1)
    #expect(spaces[0].id == 3)
  }
}

// MARK: - Window Filtering Tests

@Suite("Window Filtering")
struct WindowFilteringTests {

  @Test("Returns layer-0 windows with sufficient size")
  func normalWindows() {
    var ds = MockDataSource()
    ds.windowList = [
      makeWindowDict(id: 1, ownerName: "Safari", name: "Google", layer: 0)
    ]
    ds.windowSpaces = [1: [100]]

    let manager = SpaceManager(dataSource: ds)
    let windows = manager.getAllWindows()

    #expect(windows.count == 1)
    #expect(windows[0].id == 1)
    #expect(windows[0].ownerName == "Safari")
    #expect(windows[0].name == "Google")
  }

  @Test("Filters out non-layer-0 windows")
  func nonZeroLayer() {
    var ds = MockDataSource()
    ds.windowList = [
      makeWindowDict(id: 1, ownerName: "Dock", name: "Dock", layer: 20),
      makeWindowDict(id: 2, ownerName: "Menubar", name: "Menubar", layer: 25),
      makeWindowDict(id: 3, ownerName: "App", name: "Main", layer: 0),
    ]
    ds.windowSpaces = [3: [100]]

    let manager = SpaceManager(dataSource: ds)
    let windows = manager.getAllWindows()

    #expect(windows.count == 1)
    #expect(windows[0].id == 3)
  }

  @Test("Filters out tiny windows (<=50px in either dimension)")
  func tinyWindows() {
    var ds = MockDataSource()
    ds.windowList = [
      makeWindowDict(
        id: 1, ownerName: "Helper", name: "Helper",
        bounds: makeBoundsDict(x: 0, y: 0, width: 30, height: 30)
      ),
      makeWindowDict(
        id: 2, ownerName: "ThinBar", name: "ThinBar",
        bounds: makeBoundsDict(x: 0, y: 0, width: 200, height: 10)
      ),
      makeWindowDict(
        id: 3, ownerName: "NarrowBar", name: "NarrowBar",
        bounds: makeBoundsDict(x: 0, y: 0, width: 10, height: 200)
      ),
      makeWindowDict(
        id: 4, ownerName: "Normal", name: "Main",
        bounds: makeBoundsDict(x: 0, y: 0, width: 100, height: 100)
      ),
    ]
    ds.windowSpaces = [4: [100]]

    let manager = SpaceManager(dataSource: ds)
    let windows = manager.getAllWindows()

    #expect(windows.count == 1)
    #expect(windows[0].id == 4)
  }

  @Test("Filters out windows with no title")
  func windowWithoutTitle() {
    var ds = MockDataSource()
    ds.windowList = [
      makeWindowDict(id: 1, ownerName: "App", name: nil),
      makeWindowDict(id: 2, ownerName: "App", name: ""),
      makeWindowDict(id: 3, ownerName: "App", name: "Real Window"),
    ]
    ds.windowSpaces = [3: [100]]

    let manager = SpaceManager(dataSource: ds)
    let windows = manager.getAllWindows()

    #expect(windows.count == 1)
    #expect(windows[0].id == 3)
  }

  @Test("Skips entries with missing required fields")
  func malformedWindowEntries() {
    var ds = MockDataSource()
    ds.windowList = [
      // Missing kCGWindowNumber
      ["kCGWindowOwnerName": "App", "kCGWindowOwnerPID": 1, "kCGWindowLayer": 0],
      // Missing kCGWindowOwnerName
      ["kCGWindowNumber": 1, "kCGWindowOwnerPID": 1, "kCGWindowLayer": 0],
      // Missing kCGWindowLayer
      ["kCGWindowNumber": 2, "kCGWindowOwnerName": "App", "kCGWindowOwnerPID": 1],
    ]

    let manager = SpaceManager(dataSource: ds)
    let windows = manager.getAllWindows()

    #expect(windows.isEmpty)
  }

  @Test("Returns empty array when no windows exist")
  func emptyWindowList() {
    let ds = MockDataSource()
    let manager = SpaceManager(dataSource: ds)
    #expect(manager.getAllWindows().isEmpty)
  }
}

// MARK: - Window-to-Space Grouping Tests

@Suite("Window-to-Space Grouping")
struct WindowGroupingTests {

  @Test("Groups windows into correct spaces")
  func basicGrouping() {
    var ds = MockDataSource()
    ds.displaySpaces = [
      makeDisplayDict(
        displayUUID: "display-1",
        spaces: [makeSpaceDict(id: 1), makeSpaceDict(id: 2)],
        currentSpaceID: 1
      )
    ]
    ds.windowList = [
      makeWindowDict(id: 10, ownerName: "Safari"),
      makeWindowDict(id: 20, ownerName: "Terminal"),
    ]
    ds.windowSpaces = [10: [1], 20: [2]]

    let manager = SpaceManager(dataSource: ds)
    let (spaces, windowMap) = manager.windowsBySpace()

    #expect(spaces.count == 2)
    #expect(windowMap[1]?.count == 1)
    #expect(windowMap[1]?.first?.ownerName == "Safari")
    #expect(windowMap[2]?.count == 1)
    #expect(windowMap[2]?.first?.ownerName == "Terminal")
  }

  @Test("Sticky window appears in multiple spaces")
  func stickyWindow() {
    var ds = MockDataSource()
    ds.displaySpaces = [
      makeDisplayDict(
        displayUUID: "display-1",
        spaces: [makeSpaceDict(id: 1), makeSpaceDict(id: 2)],
        currentSpaceID: 1
      )
    ]
    ds.windowList = [
      makeWindowDict(id: 10, ownerName: "Finder")
    ]
    ds.windowSpaces = [10: [1, 2]]

    let manager = SpaceManager(dataSource: ds)
    let (_, windowMap) = manager.windowsBySpace()

    #expect(windowMap[1]?.count == 1)
    #expect(windowMap[2]?.count == 1)
    #expect(windowMap[1]?.first?.isSticky == true)
    #expect(windowMap[2]?.first?.isSticky == true)
  }

  @Test("Spaces with no windows get empty arrays")
  func emptySpaces() {
    var ds = MockDataSource()
    ds.displaySpaces = [
      makeDisplayDict(
        displayUUID: "display-1",
        spaces: [makeSpaceDict(id: 1), makeSpaceDict(id: 2)],
        currentSpaceID: 1
      )
    ]
    ds.windowList = []

    let manager = SpaceManager(dataSource: ds)
    let (_, windowMap) = manager.windowsBySpace()

    #expect(windowMap[1]?.isEmpty == true)
    #expect(windowMap[2]?.isEmpty == true)
  }

  @Test("Window on unknown space creates new map entry")
  func windowOnUnknownSpace() {
    var ds = MockDataSource()
    ds.displaySpaces = [
      makeDisplayDict(
        displayUUID: "display-1",
        spaces: [makeSpaceDict(id: 1)],
        currentSpaceID: 1
      )
    ]
    ds.windowList = [
      makeWindowDict(id: 10, ownerName: "App")
    ]
    // Window claims to be on space 999 which isn't in our space list
    ds.windowSpaces = [10: [999]]

    let manager = SpaceManager(dataSource: ds)
    let (_, windowMap) = manager.windowsBySpace()

    #expect(windowMap[1]?.isEmpty == true)
    #expect(windowMap[999]?.count == 1)
  }
}

// MARK: - Data Model Tests

@Suite("Data Models")
struct DataModelTests {

  @Test("WindowInfo.isSticky is true when on multiple spaces")
  func stickyDetection() {
    let sticky = WindowInfo(
      id: 1, ownerName: "App", name: nil,
      pid: 1, bounds: .zero, spaceIDs: [1, 2, 3]
    )
    let notSticky = WindowInfo(
      id: 2, ownerName: "App", name: nil,
      pid: 1, bounds: .zero, spaceIDs: [1]
    )
    let noSpaces = WindowInfo(
      id: 3, ownerName: "App", name: nil,
      pid: 1, bounds: .zero, spaceIDs: []
    )

    #expect(sticky.isSticky == true)
    #expect(notSticky.isSticky == false)
    #expect(noSpaces.isSticky == false)
  }

  @Test("CGSSpaceType descriptions")
  func spaceTypeDescriptions() {
    #expect(CGSSpaceType.desktop.description == "Desktop")
    #expect(CGSSpaceType.fullscreen.description == "Fullscreen")
  }
}

// MARK: - App Filtering Tests

@Suite("App Filtering")
struct AppFilteringTests {

  @Test("Include/exclude sets default to empty")
  func defaultSets() {
    let manager = SpaceManager(dataSource: MockDataSource())
    #expect(manager.excludedBundleIDs.isEmpty)
  }

  @Test("Empty include/exclude sets preserve normal window listing")
  func emptyFilterSets() {
    var ds = MockDataSource()
    ds.windowList = [
      makeWindowDict(id: 1, ownerName: "Safari", name: "Google"),
      makeWindowDict(id: 2, ownerName: "Terminal", name: "bash"),
    ]
    ds.windowSpaces = [1: [100], 2: [100]]

    let manager = SpaceManager(dataSource: ds)
    let windows = manager.getAllWindows()

    // With fake PIDs, NSRunningApplication returns nil → defaults to .regular → shown
    #expect(windows.count == 2)
  }

  @Test("Self-PID windows are always included")
  func selfPIDAlwaysIncluded() {
    let selfPID = Int(ProcessInfo.processInfo.processIdentifier)
    var ds = MockDataSource()
    ds.windowList = [
      makeWindowDict(id: 1, ownerName: "Spacebar", name: "Settings", pid: selfPID)
    ]
    ds.windowSpaces = [1: [100]]

    let manager = SpaceManager(dataSource: ds)
    // Even though Spacebar is an accessory app, self-PID is exempt
    let windows = manager.getAllWindows()
    #expect(windows.count == 1)
    #expect(windows[0].ownerName == "Spacebar")
  }

  @Test("Self-PID windows are included even with exclude set")
  func selfPIDIgnoresExclusion() {
    let selfPID = Int(ProcessInfo.processInfo.processIdentifier)
    var ds = MockDataSource()
    ds.windowList = [
      makeWindowDict(id: 1, ownerName: "Spacebar", name: "Settings", pid: selfPID)
    ]
    ds.windowSpaces = [1: [100]]

    let manager = SpaceManager(dataSource: ds)
    manager.excludedBundleIDs = ["com.moltenbits.spacebar"]
    let windows = manager.getAllWindows()
    #expect(windows.count == 1)
  }
}
