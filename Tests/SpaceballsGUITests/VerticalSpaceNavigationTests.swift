import CoreGraphics
import Foundation
import Testing

@testable import SpaceballsCore
@testable import SpaceballsGUILib

// MARK: - Helpers (local to this suite)

private func makeBounds(x: Double, y: Double, width: Double, height: Double) -> CFDictionary {
  CGRectCreateDictionaryRepresentation(CGRect(x: x, y: y, width: width, height: height))
}

private func space(id: Int, uuid: String, type: Int = 0) -> [String: Any] {
  ["ManagedSpaceID": id, "uuid": uuid, "type": type]
}

private func display(uuid: String, spaces: [[String: Any]], current: Int) -> [String: Any] {
  [
    "Display Identifier": uuid,
    "Spaces": spaces,
    "Current Space": ["ManagedSpaceID": current],
  ]
}

private func window(id: Int, owner: String, name: String, pid: Int) -> [String: Any] {
  [
    "kCGWindowNumber": id,
    "kCGWindowOwnerName": owner,
    "kCGWindowName": name,
    "kCGWindowOwnerPID": pid,
    "kCGWindowLayer": 0,
    "kCGWindowBounds": makeBounds(x: 0, y: 0, width: 800, height: 600),
    "kCGWindowIsOnscreen": true,
  ]
}

/// display-upper (spaces 1, 2) stacked above display-lower (spaces 3, 4),
/// every space holding one window (10/20/30/40).
private func makeStackedScenario() -> MutableMockDataSource {
  let ds = MutableMockDataSource()
  ds.displaySpaces = [
    display(
      uuid: "display-upper",
      spaces: [space(id: 1, uuid: "uuid-1"), space(id: 2, uuid: "uuid-2")],
      current: 1),
    display(
      uuid: "display-lower",
      spaces: [space(id: 3, uuid: "uuid-3"), space(id: 4, uuid: "uuid-4")],
      current: 3),
  ]
  ds.windowList = [
    window(id: 10, owner: "Safari", name: "Google", pid: 100),
    window(id: 20, owner: "Terminal", name: "bash", pid: 200),
    window(id: 30, owner: "Code", name: "main.swift", pid: 300),
    window(id: 40, owner: "Mail", name: "Inbox", pid: 400),
  ]
  ds.windowSpaces = [10: [1], 20: [2], 30: [3], 40: [4]]
  return ds
}

private func stackedArrangement() -> DisplayArrangement {
  DisplayArrangement(displays: [
    .init(uuid: "display-upper", frame: CGRect(x: 0, y: 1080, width: 1920, height: 1080)),
    .init(uuid: "display-lower", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
  ])
}

/// Mode 3 view model. `displayOrder` deliberately leads with the LOWER
/// display (MRU order), which differs from the spatial top-to-bottom order —
/// vertical crossing must follow the arrangement, not displayOrder.
private func makeViewModel(arranged: Bool) -> SwitcherViewModel {
  let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: makeStackedScenario()))
  if arranged { vm.displayArrangement = stackedArrangement() }
  vm.refresh()
  vm.displayOrder = ["display-lower", "display-upper"]
  return vm
}

/// Mode 3 on a lone display (MacBook only): two spaces, one window each,
/// the display hosting the meta rows.
private func makeSingleDisplayViewModel() -> SwitcherViewModel {
  let ds = MutableMockDataSource()
  ds.displaySpaces = [
    display(
      uuid: "display-solo",
      spaces: [space(id: 1, uuid: "uuid-1"), space(id: 2, uuid: "uuid-2")],
      current: 1)
  ]
  ds.windowList = [
    window(id: 10, owner: "Safari", name: "Google", pid: 100),
    window(id: 20, owner: "Terminal", name: "bash", pid: 200),
  ]
  ds.windowSpaces = [10: [1], 20: [2]]
  let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
  vm.displayArrangement = DisplayArrangement(displays: [
    .init(uuid: "display-solo", frame: CGRect(x: 0, y: 0, width: 1800, height: 1169))
  ])
  vm.metaRowsDisplayUUID = "display-solo"
  vm.refresh()
  vm.displayOrder = ["display-solo"]
  return vm
}

private func sections(_ vm: SwitcherViewModel, on uuid: String) -> [SwitcherSection] {
  vm.filteredSections.filter { $0.displayUUID == uuid }
}

private func firstItem(of section: SwitcherSection) -> SelectedItem {
  section.windows.first.map { .windowRow($0.id) } ?? .spaceHeader(section.id)
}

@Suite("Vertical Space Navigation")
struct VerticalSpaceNavigationTests {

  @Test("Stepping within a display is unchanged")
  func withinDisplayStepping() {
    let vm = makeViewModel(arranged: true)
    let lower = sections(vm, on: "display-lower")
    vm.selectedItem = firstItem(of: lower[0])
    vm.moveToNextSpace()
    #expect(vm.selectedItem == firstItem(of: lower[1]))
  }

  @Test("Down from a display's last space enters the display below at its first space")
  func downCrossesToDisplayBelow() {
    let vm = makeViewModel(arranged: true)
    let upper = sections(vm, on: "display-upper")
    let lower = sections(vm, on: "display-lower")
    vm.selectedItem = firstItem(of: upper[upper.count - 1])
    vm.moveToNextSpace()
    #expect(vm.selectedItem == firstItem(of: lower[0]))
  }

  @Test("Up from a display's first space enters the display above at its last space")
  func upCrossesToDisplayAbove() {
    let vm = makeViewModel(arranged: true)
    let upper = sections(vm, on: "display-upper")
    let lower = sections(vm, on: "display-lower")
    vm.selectedItem = firstItem(of: lower[0])
    vm.moveToPreviousSpace()
    #expect(vm.selectedItem == firstItem(of: upper[upper.count - 1]))
  }

  @Test("Down from the bottom display's last space wraps to the top display's first")
  func downAtBottomWrapsToTop() {
    let vm = makeViewModel(arranged: true)
    let upper = sections(vm, on: "display-upper")
    let lower = sections(vm, on: "display-lower")
    vm.selectedItem = firstItem(of: lower[lower.count - 1])
    vm.moveToNextSpace()
    #expect(vm.selectedItem == firstItem(of: upper[0]))
  }

  @Test("Up from the top display's first space wraps to the bottom display's last")
  func upAtTopWrapsToBottom() {
    let vm = makeViewModel(arranged: true)
    let upper = sections(vm, on: "display-upper")
    let lower = sections(vm, on: "display-lower")
    vm.selectedItem = firstItem(of: upper[0])
    vm.moveToPreviousSpace()
    #expect(vm.selectedItem == firstItem(of: lower[lower.count - 1]))
  }

  @Test("Down from the meta display's last space visits Workspaces, Settings, Eject, then crosses on")
  func downThroughMetaRows() {
    let vm = makeViewModel(arranged: true)
    vm.metaRowsDisplayUUID = "display-lower"
    let upper = sections(vm, on: "display-upper")
    let lower = sections(vm, on: "display-lower")

    vm.selectedItem = firstItem(of: lower[lower.count - 1])
    vm.moveToNextSpace()
    #expect(vm.selectedItem == .spaces)
    vm.moveToNextSpace()
    #expect(vm.selectedItem == .settings)
    vm.moveToNextSpace()
    #expect(vm.selectedItem == .eject)
    vm.moveToNextSpace()
    #expect(vm.selectedItem == firstItem(of: upper[0]))
  }

  @Test("Up arriving at the meta display lands on Eject, Settings, Workspaces, then its last space")
  func upThroughMetaRows() {
    let vm = makeViewModel(arranged: true)
    vm.metaRowsDisplayUUID = "display-lower"
    let upper = sections(vm, on: "display-upper")
    let lower = sections(vm, on: "display-lower")

    // Upper display's first space; ↑ wraps down to the meta display, whose
    // bottom-most rows are Eject then Settings then Workspaces then its last space.
    vm.selectedItem = firstItem(of: upper[0])
    vm.moveToPreviousSpace()
    #expect(vm.selectedItem == .eject)
    vm.moveToPreviousSpace()
    #expect(vm.selectedItem == .settings)
    vm.moveToPreviousSpace()
    #expect(vm.selectedItem == .spaces)
    vm.moveToPreviousSpace()
    #expect(vm.selectedItem == firstItem(of: lower[lower.count - 1]))
  }

  @Test("Crossing into the meta display from above skips the meta rows")
  func downIntoMetaDisplaySkipsMetaRows() {
    let vm = makeViewModel(arranged: true)
    vm.metaRowsDisplayUUID = "display-lower"
    let upper = sections(vm, on: "display-upper")
    let lower = sections(vm, on: "display-lower")

    // The meta rows sit at the BOTTOM of the meta display's panel — entering
    // it from the top goes straight to its first space.
    vm.selectedItem = firstItem(of: upper[upper.count - 1])
    vm.moveToNextSpace()
    #expect(vm.selectedItem == firstItem(of: lower[0]))
  }

  @Test("A non-meta display's boundary keeps the plain vertical crossing")
  func nonMetaDisplayCrossesWithoutMetaRows() {
    let vm = makeViewModel(arranged: true)
    vm.metaRowsDisplayUUID = "display-lower"
    let upper = sections(vm, on: "display-upper")
    let lower = sections(vm, on: "display-lower")

    // ↑ off the top of the upper (non-meta) display's... first space wraps
    // to the meta display (covered above); ↑ from the LOWER display's first
    // space crosses to the upper display's last space with no meta detour.
    vm.selectedItem = firstItem(of: lower[0])
    vm.moveToPreviousSpace()
    #expect(vm.selectedItem == firstItem(of: upper[upper.count - 1]))
  }

  @Test("Tab past a non-meta group's end flows into the next group, skipping the meta rows")
  func tabSkipsMetaRowsAtNonMetaBoundary() {
    let vm = makeViewModel(arranged: true)
    vm.metaRowsDisplayUUID = "display-upper"
    let upper = sections(vm, on: "display-upper")
    let lower = sections(vm, on: "display-lower")

    // displayOrder leads with display-lower (non-meta): Tab off its last
    // window must land on the next group's first item, not .spaces.
    vm.selectedItem = firstItem(of: lower[lower.count - 1])
    vm.moveSelectionDown()
    #expect(vm.selectedItem == firstItem(of: upper[0]))
  }

  @Test("Tab visits Workspaces, Settings, and Eject at the meta group's end, then continues")
  func tabVisitsMetaRowsAtMetaBoundary() {
    let vm = makeViewModel(arranged: true)
    vm.metaRowsDisplayUUID = "display-lower"
    let upper = sections(vm, on: "display-upper")
    let lower = sections(vm, on: "display-lower")

    vm.selectedItem = firstItem(of: lower[lower.count - 1])
    vm.moveSelectionDown()
    #expect(vm.selectedItem == .spaces)
    vm.moveSelectionDown()
    #expect(vm.selectedItem == .settings)
    vm.moveSelectionDown()
    #expect(vm.selectedItem == .eject)
    vm.moveSelectionDown()
    #expect(vm.selectedItem == firstItem(of: upper[0]))
  }

  @Test("Shift-Tab into a preceding meta group enters through Eject")
  func shiftTabEntersMetaGroupThroughSettings() {
    let vm = makeViewModel(arranged: true)
    vm.metaRowsDisplayUUID = "display-lower"
    let upper = sections(vm, on: "display-upper")
    let lower = sections(vm, on: "display-lower")

    // Upper group follows the lower (meta) group: ↑ from its first item
    // backs into Eject → Settings → Workspaces → the meta group's last item.
    vm.selectedItem = firstItem(of: upper[0])
    vm.moveSelectionUp()
    #expect(vm.selectedItem == .eject)
    vm.moveSelectionUp()
    #expect(vm.selectedItem == .settings)
    vm.moveSelectionUp()
    #expect(vm.selectedItem == .spaces)
    vm.moveSelectionUp()
    #expect(vm.selectedItem == firstItem(of: lower[lower.count - 1]))
  }

  @Test("Shift-Tab into a preceding non-meta group lands on its last item")
  func shiftTabSkipsMetaRowsAtNonMetaBoundary() {
    let vm = makeViewModel(arranged: true)
    vm.metaRowsDisplayUUID = "display-upper"
    let upper = sections(vm, on: "display-upper")
    let lower = sections(vm, on: "display-lower")

    vm.selectedItem = firstItem(of: upper[0])
    vm.moveSelectionUp()
    #expect(vm.selectedItem == firstItem(of: lower[lower.count - 1]))
  }

  @Test("Without a meta display, Tab keeps its stop at every group boundary")
  func tabWithoutMetaDisplayKeepsAllStops() {
    let vm = makeViewModel(arranged: true)
    let lower = sections(vm, on: "display-lower")
    vm.selectedItem = firstItem(of: lower[lower.count - 1])
    vm.moveSelectionDown()
    #expect(vm.selectedItem == .spaces)
  }

  @Test("Single display: Up from the first space wraps through Eject, Settings, and Workspaces")
  func singleDisplayUpWrapsThroughMetaRows() {
    let vm = makeSingleDisplayViewModel()
    let solo = sections(vm, on: "display-solo")

    vm.selectedItem = firstItem(of: solo[0])
    vm.moveToPreviousSpace()
    #expect(vm.selectedItem == .eject)
    vm.moveToPreviousSpace()
    #expect(vm.selectedItem == .settings)
    vm.moveToPreviousSpace()
    #expect(vm.selectedItem == .spaces)
    vm.moveToPreviousSpace()
    #expect(vm.selectedItem == firstItem(of: solo[solo.count - 1]))
  }

  @Test("Single display: Down from the last space wraps through Workspaces, Settings, and Eject")
  func singleDisplayDownWrapsThroughMetaRows() {
    let vm = makeSingleDisplayViewModel()
    let solo = sections(vm, on: "display-solo")

    vm.selectedItem = firstItem(of: solo[solo.count - 1])
    vm.moveToNextSpace()
    #expect(vm.selectedItem == .spaces)
    vm.moveToNextSpace()
    #expect(vm.selectedItem == .settings)
    vm.moveToNextSpace()
    #expect(vm.selectedItem == .eject)
    vm.moveToNextSpace()
    #expect(vm.selectedItem == firstItem(of: solo[0]))
  }

  @Test("Up at a non-meta display's first space with nothing above stays put")
  func upWithoutAxisOnNonMetaDisplayIsNoOp() {
    // Side-by-side layout: the non-meta display has no vertical axis and
    // does not host the meta rows — ↑ at its first space stays a no-op.
    let vm = makeViewModel(arranged: false)
    vm.displayArrangement = DisplayArrangement(displays: [
      .init(uuid: "display-upper", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
      .init(uuid: "display-lower", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080)),
    ])
    vm.metaRowsDisplayUUID = "display-lower"
    let upper = sections(vm, on: "display-upper")
    let start = firstItem(of: upper[0])
    vm.selectedItem = start
    vm.moveToPreviousSpace()
    #expect(vm.selectedItem == start)
  }

  @Test("Without an arrangement, group-boundary stops behave as before")
  func withoutArrangementKeepsGroupStops() {
    let vm = makeViewModel(arranged: false)
    let lower = sections(vm, on: "display-lower")
    // display-lower leads displayOrder, so its last space is a group end —
    // the legacy behavior stops at the .spaces row there.
    vm.selectedItem = firstItem(of: lower[lower.count - 1])
    vm.moveToNextSpace()
    #expect(vm.selectedItem == .spaces)
  }
}
