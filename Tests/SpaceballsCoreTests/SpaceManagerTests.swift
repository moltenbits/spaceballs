import CoreGraphics
import Foundation
import Testing

@testable import SpaceballsCore

// MARK: - Mock Data Source

struct MockDataSource: SystemDataSource {
  var displaySpaces: [[String: Any]] = []
  var windowList: [[String: Any]] = []
  var onScreenWindowList: [[String: Any]]?
  var windowSpaces: [Int: [UInt64]] = [:]
  /// Live AX window IDs per pid. A pid absent from this map returns `nil`
  /// (AX unavailable → conservative keep); map to an explicit set (possibly
  /// empty) to simulate a queryable app.
  var liveWindowIDsByPID: [Int: Set<CGWindowID>] = [:]

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

  func liveAXWindowIDs(pid: pid_t) -> Set<CGWindowID>? {
    liveWindowIDsByPID[Int(pid)]
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

@Suite("Activation Diagnostics")
struct ActivationDiagnosticsTests {

  @Test("Activation context includes current space and target window spaces")
  func activationContextIncludesCurrentAndTargetSpaces() {
    var ds = MockDataSource()
    ds.displaySpaces = [
      makeDisplayDict(
        displayUUID: "display-1",
        spaces: [
          makeSpaceDict(id: 10, uuid: "space-current"),
          makeSpaceDict(id: 11, uuid: "space-target"),
        ],
        currentSpaceID: 10)
    ]
    ds.windowSpaces = [42: [11, 99]]

    let manager = SpaceManager(dataSource: ds)

    #expect(
      manager.activationContextForDiagnostics(windowID: 42)
        == "currentSpaces=[id=10 uuid=space-current display=display-1 type=desktop current=true] targetSpaceIDs=[11,99] targetSpaces=[id=11 uuid=space-target display=display-1 type=desktop current=false; id=99 metadata=missing]"
    )
  }

  @Test("Activation context handles windows with no space mapping")
  func activationContextHandlesMissingWindowSpaces() {
    var ds = MockDataSource()
    ds.displaySpaces = [
      makeDisplayDict(
        displayUUID: "display-1",
        spaces: [makeSpaceDict(id: 10, uuid: "space-current")],
        currentSpaceID: 10)
    ]

    let manager = SpaceManager(dataSource: ds)

    #expect(
      manager.activationContextForDiagnostics(windowID: 42)
        == "currentSpaces=[id=10 uuid=space-current display=display-1 type=desktop current=true] targetSpaceIDs=[] targetSpaces=[]"
    )
  }

  @Test("Space wake fallback target is the single non-current desktop space")
  func spaceWakeFallbackTargetIsSingleNonCurrentDesktopSpace() {
    var ds = MockDataSource()
    ds.displaySpaces = [
      makeDisplayDict(
        displayUUID: "display-1",
        spaces: [
          makeSpaceDict(id: 10, uuid: "space-current"),
          makeSpaceDict(id: 11, uuid: "space-target"),
        ],
        currentSpaceID: 10)
    ]
    ds.windowSpaces = [42: [11]]

    let manager = SpaceManager(dataSource: ds)

    #expect(manager.spaceWakeFallbackTargetForActivation(windowID: 42)?.id == 11)
  }

  @Test("Space wake fallback is skipped for current, sticky, and fullscreen targets")
  func spaceWakeFallbackSkipsUnsafeTargets() {
    var ds = MockDataSource()
    ds.displaySpaces = [
      makeDisplayDict(
        displayUUID: "display-1",
        spaces: [
          makeSpaceDict(id: 10, uuid: "space-current"),
          makeSpaceDict(id: 11, uuid: "space-target"),
          makeSpaceDict(id: 12, uuid: "fullscreen-target", type: 4),
        ],
        currentSpaceID: 10)
    ]
    ds.windowSpaces = [
      1: [10],
      2: [10, 11],
      3: [12],
      4: [99],
    ]

    let manager = SpaceManager(dataSource: ds)

    #expect(manager.spaceWakeFallbackTargetForActivation(windowID: 1) == nil)
    #expect(manager.spaceWakeFallbackTargetForActivation(windowID: 2) == nil)
    #expect(manager.spaceWakeFallbackTargetForActivation(windowID: 3) == nil)
    #expect(manager.spaceWakeFallbackTargetForActivation(windowID: 4) == nil)
  }
}

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

  @Test("Filters out nil-title windows and empty-title windows when app has titled ones")
  func windowWithoutTitle() {
    var ds = MockDataSource()
    // Same app (pid 100) has nil-title, empty-title, and titled windows.
    // The nil and empty ones should be filtered since a titled window exists.
    ds.windowList = [
      makeWindowDict(id: 1, ownerName: "Safari", name: nil, pid: 100),
      makeWindowDict(id: 2, ownerName: "Safari", name: "", pid: 100),
      makeWindowDict(id: 3, ownerName: "Safari", name: "Google", pid: 100),
    ]
    ds.windowSpaces = [3: [100]]

    let manager = SpaceManager(dataSource: ds)
    let windows = manager.getAllWindows()

    #expect(windows.count == 1)
    #expect(windows[0].id == 3)
  }

  @Test("Allows empty-title windows when app has no titled windows")
  func emptyTitleOnlyApp() {
    var ds = MockDataSource()
    // App with only empty-title windows (e.g. Contacts) — keep them
    ds.windowList = [
      makeWindowDict(id: 1, ownerName: "Contacts", name: "", pid: 200),
      makeWindowDict(id: 2, ownerName: "Contacts", name: "", pid: 200),
    ]
    ds.windowSpaces = [1: [100], 2: [100]]

    let manager = SpaceManager(dataSource: ds)
    let windows = manager.getAllWindows()

    #expect(windows.count == 2)
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

// MARK: - Closed (Lingering) Window Filtering Tests

/// A window closed in a still-running app lingers in CGWindowListCopyWindowInfo(.optionAll),
/// still mapped to its Space (ordered out, not destroyed). It's indistinguishable from a
/// minimized window in the window-server list — both are off-screen with identical fields —
/// so the only reliable discriminator is Accessibility liveness (kAXWindowsAttribute lists
/// minimized windows, not closed ones). These tests pin down that filtering behavior.
@Suite("Closed Window Filtering")
struct ClosedWindowFilteringTests {

  /// One display whose current space is `currentSpaceID`, plus one other desktop space.
  private func singleDisplay(currentSpaceID: Int, otherSpaceID: Int) -> [[String: Any]] {
    [
      makeDisplayDict(
        displayUUID: "display-1",
        spaces: [
          makeSpaceDict(id: currentSpaceID, uuid: "space-current"),
          makeSpaceDict(id: otherSpaceID, uuid: "space-other"),
        ],
        currentSpaceID: currentSpaceID)
    ]
  }

  @Test("Drops an off-screen current-space window that AX no longer lists (closed)")
  func dropsClosedWindowOnCurrentSpace() {
    var ds = MockDataSource()
    ds.displaySpaces = singleDisplay(currentSpaceID: 10, otherSpaceID: 11)
    ds.windowList = [
      makeWindowDict(id: 1, ownerName: "App", name: "Alive", pid: 100, isOnscreen: true),
      makeWindowDict(id: 2, ownerName: "App", name: "Closed", pid: 100, isOnscreen: false),
    ]
    ds.windowSpaces = [1: [10], 2: [10]]
    ds.liveWindowIDsByPID = [100: [1]]  // window 2 was closed → absent from AX

    let windows = SpaceManager(dataSource: ds).getAllWindows()

    #expect(windows.map(\.id) == [1])
  }

  @Test("Keeps a minimized current-space window that AX still lists")
  func keepsMinimizedWindowOnCurrentSpace() {
    var ds = MockDataSource()
    ds.displaySpaces = singleDisplay(currentSpaceID: 10, otherSpaceID: 11)
    ds.windowList = [
      makeWindowDict(id: 1, ownerName: "App", name: "Alive", pid: 100, isOnscreen: true),
      makeWindowDict(id: 2, ownerName: "App", name: "Minimized", pid: 100, isOnscreen: false),
    ]
    ds.windowSpaces = [1: [10], 2: [10]]
    ds.liveWindowIDsByPID = [100: [1, 2]]  // minimized window is still a live AX window

    let windows = SpaceManager(dataSource: ds).getAllWindows()

    #expect(Set(windows.map(\.id)) == [1, 2])
  }

  @Test("Keeps an off-screen window on another (non-current) Space without consulting AX")
  func keepsOffScreenWindowOnOtherSpace() {
    var ds = MockDataSource()
    ds.displaySpaces = singleDisplay(currentSpaceID: 10, otherSpaceID: 11)
    ds.windowList = [
      makeWindowDict(id: 3, ownerName: "App", name: "OtherSpace", pid: 100, isOnscreen: false)
    ]
    ds.windowSpaces = [3: [11]]  // on the non-current space; AX can't see other Spaces
    ds.liveWindowIDsByPID = [100: []]  // even an empty AX set must not drop it

    let windows = SpaceManager(dataSource: ds).getAllWindows()

    #expect(windows.map(\.id) == [3])
  }

  @Test("Keeps an off-screen current-space window when AX liveness is unavailable")
  func keepsWindowWhenAXUnavailable() {
    var ds = MockDataSource()
    ds.displaySpaces = singleDisplay(currentSpaceID: 10, otherSpaceID: 11)
    ds.windowList = [
      makeWindowDict(id: 2, ownerName: "App", name: "Unknown", pid: 100, isOnscreen: false)
    ]
    ds.windowSpaces = [2: [10]]
    // pid 100 absent from liveWindowIDsByPID → liveAXWindowIDs returns nil (unknown)

    let windows = SpaceManager(dataSource: ds).getAllWindows()

    #expect(windows.map(\.id) == [2])
  }

  @Test("Keeps an on-screen window even when AX does not list it")
  func keepsOnScreenWindowRegardlessOfAX() {
    var ds = MockDataSource()
    ds.displaySpaces = singleDisplay(currentSpaceID: 10, otherSpaceID: 11)
    ds.windowList = [
      makeWindowDict(id: 1, ownerName: "App", name: "Front", pid: 100, isOnscreen: true)
    ]
    ds.windowSpaces = [1: [10]]
    ds.liveWindowIDsByPID = [100: []]  // on-screen fast path wins regardless

    let windows = SpaceManager(dataSource: ds).getAllWindows()

    #expect(windows.map(\.id) == [1])
  }
}

// MARK: - Closed Window Tombstone Tests

/// Reference-type mock so a test can mutate system state between calls on the
/// same SpaceManager (e.g. simulate a space switch between two refreshes).
final class MutableCoreMockDataSource: SystemDataSource {
  var displaySpaces: [[String: Any]] = []
  var windowList: [[String: Any]] = []
  var windowSpaces: [Int: [UInt64]] = [:]
  var liveWindowIDsByPID: [Int: Set<CGWindowID>] = [:]

  func fetchManagedDisplaySpaces() -> [[String: Any]] { displaySpaces }
  func fetchWindowList() -> [[String: Any]] { windowList }
  func fetchOnScreenWindowList() -> [[String: Any]] { windowList }
  func fetchSpacesForWindow(_ windowID: Int) -> [UInt64] { windowSpaces[windowID] ?? [] }
  func liveAXWindowIDs(pid: pid_t) -> Set<CGWindowID>? { liveWindowIDsByPID[Int(pid)] }
}

/// A window confirmed closed via AX must STAY hidden after its Space stops being
/// current. Without a remembered verdict, the ghost is only masked while its
/// Space is current and reappears on every Space switch.
@Suite("Closed Window Tombstones")
struct ClosedWindowTombstoneTests {

  private func makeDataSource(currentSpaceID: Int) -> MutableCoreMockDataSource {
    let ds = MutableCoreMockDataSource()
    ds.displaySpaces = [
      makeDisplayDict(
        displayUUID: "display-1",
        spaces: [makeSpaceDict(id: 10, uuid: "space-a"), makeSpaceDict(id: 11, uuid: "space-b")],
        currentSpaceID: currentSpaceID)
    ]
    return ds
  }

  @Test("Window confirmed closed stays hidden after switching away from its space")
  func closedWindowStaysHiddenAcrossSpaceSwitch() {
    let ds = makeDataSource(currentSpaceID: 10)
    ds.windowList = [
      makeWindowDict(id: 2, ownerName: "App", name: "Ghost", pid: 100, isOnscreen: false)
    ]
    ds.windowSpaces = [2: [10]]
    ds.liveWindowIDsByPID = [100: []]  // AX: window 2 is dead

    let manager = SpaceManager(dataSource: ds)
    #expect(manager.getAllWindows().isEmpty)  // confirmed closed while space 10 is current

    // Switch to space 11 — the ghost's space is no longer current, so AX can no
    // longer vouch. The remembered verdict must keep it hidden.
    ds.displaySpaces = makeDataSource(currentSpaceID: 11).displaySpaces
    #expect(manager.getAllWindows().isEmpty)
  }

  @Test("Tombstoned window is unhidden if AX later reports it alive")
  func tombstoneIsRevertedWhenAXReportsAlive() {
    let ds = makeDataSource(currentSpaceID: 10)
    ds.windowList = [
      makeWindowDict(id: 2, ownerName: "App", name: "Flaky", pid: 100, isOnscreen: false)
    ]
    ds.windowSpaces = [2: [10]]
    ds.liveWindowIDsByPID = [100: []]  // transient AX glitch: reported dead

    let manager = SpaceManager(dataSource: ds)
    #expect(manager.getAllWindows().isEmpty)

    // AX recovers and lists the window again (still on the current space).
    ds.liveWindowIDsByPID = [100: [2]]
    #expect(manager.getAllWindows().map(\.id) == [2])

    // And the tombstone is truly gone: switch away, window must remain visible.
    ds.displaySpaces = makeDataSource(currentSpaceID: 11).displaySpaces
    #expect(manager.getAllWindows().map(\.id) == [2])
  }

  @Test("Tombstone is pruned once the window leaves the window list")
  func tombstoneIsPrunedWhenWindowDisappears() {
    let ds = makeDataSource(currentSpaceID: 10)
    ds.windowList = [
      makeWindowDict(id: 2, ownerName: "App", name: "Ghost", pid: 100, isOnscreen: false)
    ]
    ds.windowSpaces = [2: [10]]
    ds.liveWindowIDsByPID = [100: []]

    let manager = SpaceManager(dataSource: ds)
    #expect(manager.getAllWindows().isEmpty)  // tombstoned

    // The window finally leaves CGWindowList (e.g. app quit) → tombstone pruned.
    ds.windowList = []
    #expect(manager.getAllWindows().isEmpty)

    // A NEW window later reuses the same ID on a non-current space. The stale
    // tombstone must not hide it.
    ds.windowList = [
      makeWindowDict(id: 2, ownerName: "Other", name: "Reused", pid: 200, isOnscreen: false)
    ]
    ds.windowSpaces = [2: [11]]
    #expect(manager.getAllWindows().map(\.id) == [2])
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
      makeWindowDict(id: 1, ownerName: "Spaceballs", name: "Settings", pid: selfPID)
    ]
    ds.windowSpaces = [1: [100]]

    let manager = SpaceManager(dataSource: ds)
    // Even though Spacebar is an accessory app, self-PID is exempt
    let windows = manager.getAllWindows()
    #expect(windows.count == 1)
    #expect(windows[0].ownerName == "Spaceballs")
  }

  @Test("Self-PID windows are included even with exclude set")
  func selfPIDIgnoresExclusion() {
    let selfPID = Int(ProcessInfo.processInfo.processIdentifier)
    var ds = MockDataSource()
    ds.windowList = [
      makeWindowDict(id: 1, ownerName: "Spaceballs", name: "Settings", pid: selfPID)
    ]
    ds.windowSpaces = [1: [100]]

    let manager = SpaceManager(dataSource: ds)
    manager.excludedBundleIDs = ["com.moltenbits.spaceballs"]
    let windows = manager.getAllWindows()
    #expect(windows.count == 1)
  }
}
