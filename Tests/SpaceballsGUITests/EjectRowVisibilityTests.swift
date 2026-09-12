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

/// Laptop alone: the built-in display with two spaces, one window each.
private func makeBuiltinOnlyViewModel() -> SwitcherViewModel {
  let ds = MutableMockDataSource()
  ds.displaySpaces = [
    display(
      uuid: "display-builtin",
      spaces: [space(id: 1, uuid: "uuid-1"), space(id: 2, uuid: "uuid-2")],
      current: 1)
  ]
  ds.windowList = [
    window(id: 10, owner: "Safari", name: "Google", pid: 100),
    window(id: 20, owner: "Terminal", name: "bash", pid: 200),
  ]
  ds.windowSpaces = [10: [1], 20: [2]]
  let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
  vm.builtinDisplayUUID = { "display-builtin" }
  vm.refresh()
  return vm
}

/// Built-in plus one external display, a space with a window on each.
private func makeExternalConnectedViewModel() -> SwitcherViewModel {
  let ds = MutableMockDataSource()
  ds.displaySpaces = [
    display(uuid: "display-builtin", spaces: [space(id: 1, uuid: "uuid-1")], current: 1),
    display(uuid: "display-ext", spaces: [space(id: 2, uuid: "uuid-2")], current: 2),
  ]
  ds.windowList = [
    window(id: 10, owner: "Safari", name: "Google", pid: 100),
    window(id: 20, owner: "Terminal", name: "bash", pid: 200),
  ]
  ds.windowSpaces = [10: [1], 20: [2]]
  let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
  vm.builtinDisplayUUID = { "display-builtin" }
  vm.refresh()
  return vm
}

@Suite("Eject Row Visibility")
struct EjectRowVisibilityTests {

  @Test("Eject is offered when a space sits on an external display")
  func ejectOfferedWithExternal() {
    let vm = makeExternalConnectedViewModel()
    #expect(vm.ejectAvailable)
    #expect(vm.flatSelectableItems.last == .eject)
  }

  @Test("Eject is hidden when only the built-in display is connected")
  func ejectHiddenOnBuiltinOnly() {
    let vm = makeBuiltinOnlyViewModel()
    #expect(!vm.ejectAvailable)
    #expect(!vm.flatSelectableItems.contains(.eject))
    #expect(vm.flatSelectableItems.last == .settings)
  }

  @Test("Eject stays offered when the built-in display cannot be identified")
  func ejectFailsOpenWithoutBuiltinUUID() {
    let vm = makeBuiltinOnlyViewModel()
    vm.builtinDisplayUUID = { nil }
    vm.refresh()
    #expect(vm.ejectAvailable)
    #expect(vm.flatSelectableItems.last == .eject)
  }

  @Test("Availability follows display changes across refreshes")
  func availabilityTracksDisplayChanges() {
    let ds = MutableMockDataSource()
    ds.displaySpaces = [
      display(uuid: "display-builtin", spaces: [space(id: 1, uuid: "uuid-1")], current: 1)
    ]
    ds.windowList = [window(id: 10, owner: "Safari", name: "Google", pid: 100)]
    ds.windowSpaces = [10: [1]]
    let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.builtinDisplayUUID = { "display-builtin" }
    vm.refresh()
    #expect(!vm.ejectAvailable)

    // Plug in an external display.
    ds.displaySpaces = [
      display(uuid: "display-builtin", spaces: [space(id: 1, uuid: "uuid-1")], current: 1),
      display(uuid: "display-ext", spaces: [space(id: 2, uuid: "uuid-2")], current: 2),
    ]
    vm.refresh()
    #expect(vm.ejectAvailable)

    // Unplug it again.
    ds.displaySpaces = [
      display(uuid: "display-builtin", spaces: [space(id: 1, uuid: "uuid-1")], current: 1)
    ]
    vm.refresh()
    #expect(!vm.ejectAvailable)
  }

  @Test("Flat navigation cycles Workspaces and Settings only when Eject is hidden")
  func flatCycleSkipsHiddenEject() {
    let vm = makeBuiltinOnlyViewModel()

    vm.selectedItem = .spaces
    vm.moveSelectionDown()
    #expect(vm.selectedItem == .settings)

    vm.moveSelectionDown()
    #expect(vm.selectedItem == .windowRow(10))  // wraps past the hidden Eject

    vm.moveSelectionUp()
    #expect(vm.selectedItem == .settings)  // wrap lands on Settings, not Eject
  }

  @Test("moveToNextSpace skips the hidden Eject stop")
  func nextSpaceSkipsHiddenEject() {
    let vm = makeBuiltinOnlyViewModel()

    vm.selectedItem = .settings
    vm.moveToNextSpace()
    #expect(vm.selectedItem == .windowRow(10))  // wraps, no Eject stop
  }

  @Test("moveToPreviousSpace wrap lands on Settings when Eject is hidden")
  func previousSpaceWrapLandsOnSettings() {
    let vm = makeBuiltinOnlyViewModel()

    vm.selectedItem = .windowRow(10)  // first section
    vm.moveToPreviousSpace()
    #expect(vm.selectedItem == .settings)
  }

  @Test("Mode 3 single display: vertical wrap visits Workspaces and Settings only")
  func mode3SingleDisplayWrapSkipsEject() {
    let vm = makeBuiltinOnlyViewModel()
    vm.displayArrangement = DisplayArrangement(displays: [
      .init(uuid: "display-builtin", frame: CGRect(x: 0, y: 0, width: 1800, height: 1169))
    ])
    vm.metaRowsDisplayUUID = "display-builtin"
    vm.displayOrder = ["display-builtin"]

    // Down from the last space wraps through Workspaces → Settings → first space.
    vm.selectedItem = .windowRow(20)
    vm.moveToNextSpace()
    #expect(vm.selectedItem == .spaces)
    vm.moveToNextSpace()
    #expect(vm.selectedItem == .settings)
    vm.moveToNextSpace()
    #expect(vm.selectedItem == .windowRow(10))

    // Up from the first space enters the bottom rows at Settings, not Eject.
    vm.selectedItem = .windowRow(10)
    vm.moveToPreviousSpace()
    #expect(vm.selectedItem == .settings)
  }

  @Test("Mode 3 single display: Tab cycle stops at Settings then continues")
  func mode3TabCycleSkipsEject() {
    let vm = makeBuiltinOnlyViewModel()
    vm.metaRowsDisplayUUID = "display-builtin"
    vm.displayOrder = ["display-builtin"]

    vm.selectedItem = .windowRow(20)  // last item of the only group
    vm.moveSelectionDown()
    #expect(vm.selectedItem == .spaces)
    vm.moveSelectionDown()
    #expect(vm.selectedItem == .settings)
    vm.moveSelectionDown()
    #expect(vm.selectedItem == .windowRow(10))  // next group wrap, no Eject

    vm.moveSelectionUp()
    #expect(vm.selectedItem == .settings)  // re-enters the meta rows at Settings
  }
}
