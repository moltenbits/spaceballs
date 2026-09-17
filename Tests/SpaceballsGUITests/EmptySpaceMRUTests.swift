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

/// Two displays; display-1 (focused) has space 1 (current, window 10) and
/// space 2 (window 20); display-2 has space 3 (current, window 30) and
/// space 4 — EMPTY, like a freshly connected display's default space.
private func makeEmptySpaceScenario() -> MutableMockDataSource {
  let ds = MutableMockDataSource()
  ds.displaySpaces = [
    display(
      uuid: "display-1",
      spaces: [space(id: 1, uuid: "uuid-1"), space(id: 2, uuid: "uuid-2")],
      current: 1),
    display(
      uuid: "display-2",
      spaces: [space(id: 3, uuid: "uuid-3"), space(id: 4, uuid: "uuid-4")],
      current: 3),
  ]
  ds.windowList = [
    window(id: 10, owner: "Safari", name: "Google", pid: 100),
    window(id: 30, owner: "Code", name: "main.swift", pid: 300),
    window(id: 20, owner: "Terminal", name: "bash", pid: 200),
  ]
  ds.windowSpaces = [10: [1], 20: [2], 30: [3]]
  return ds
}

@Suite("Empty Space MRU Promotion")
struct EmptySpaceMRUTests {

  @Test("Activating an empty space header promotes it to the top")
  func emptySpacePromotedOnActivation() {
    let ds = makeEmptySpaceScenario()
    let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.overrideDisplayUUID = "display-1"
    vm.refresh()

    // Empty space 4 starts in the last bucket.
    #expect(vm.sections.last?.id == 4)

    // Activate the empty space via its header (keyboard focus cannot follow —
    // the space has no windows — so display-1 stays the focused display).
    vm.selectedItem = .spaceHeader(4)
    vm.activateSelected()

    // The switch lands: display-2's current space becomes 4.
    ds.displaySpaces = [
      display(
        uuid: "display-1",
        spaces: [space(id: 1, uuid: "uuid-1"), space(id: 2, uuid: "uuid-2")],
        current: 1),
      display(
        uuid: "display-2",
        spaces: [space(id: 3, uuid: "uuid-3"), space(id: 4, uuid: "uuid-4")],
        current: 4),
    ]

    vm.refresh()
    #expect(vm.sections.first?.id == 4)
  }

  @Test("Idle refreshes don't demote an explicitly activated empty space")
  func idleRefreshKeepsEmptySpaceOnTop() {
    let ds = makeEmptySpaceScenario()
    let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.overrideDisplayUUID = "display-1"
    vm.refresh()

    vm.selectedItem = .spaceHeader(4)
    vm.activateSelected()

    // Repeated refreshes with no focus or frontmost-window change (the user
    // just keeps reopening the panel) must not push the focused display's
    // space back above the explicit activation.
    vm.refresh()
    vm.refresh()
    vm.refresh()
    #expect(vm.sections.first?.id == 4)
  }

  @Test("Re-engaging a window re-promotes its space above the empty one")
  func windowReengagementRepromotesItsSpace() {
    let ds = makeEmptySpaceScenario()
    let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.overrideDisplayUUID = "display-1"
    vm.refresh()

    vm.selectedItem = .spaceHeader(4)
    vm.activateSelected()
    vm.refresh()
    #expect(vm.sections.first?.id == 4)

    // The user clicks into a different window on the focused display's space
    // (window 11 becomes frontmost) — that space deserves the top spot again.
    ds.windowList = [
      window(id: 11, owner: "Safari", name: "GitHub", pid: 100),
      window(id: 10, owner: "Safari", name: "Google", pid: 100),
      window(id: 30, owner: "Code", name: "main.swift", pid: 300),
      window(id: 20, owner: "Terminal", name: "bash", pid: 200),
    ]
    ds.windowSpaces = [10: [1], 11: [1], 20: [2], 30: [3]]

    vm.refresh()
    #expect(vm.sections.first?.id == 1)
    #expect(vm.sections[1].id == 4)
  }

  @Test("Programmatic activation (create-space flow) promotes the new space")
  func programmaticActivationPromotesNewSpace() {
    let ds = makeEmptySpaceScenario()
    let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.overrideDisplayUUID = "display-1"
    vm.refresh()
    #expect(vm.sections.last?.id == 4)

    // The create-space completion switches to the fresh empty space with no
    // selection involved. Focus inference can't see the switch (no window to
    // take keyboard focus), and the stamp must not depend on the manager
    // call succeeding (it can't in this environment).
    vm.activateSpace(id: 4)

    // CGS reflects the switch: display-2's current space becomes 4.
    ds.displaySpaces = [
      display(
        uuid: "display-1",
        spaces: [space(id: 1, uuid: "uuid-1"), space(id: 2, uuid: "uuid-2")],
        current: 1),
      display(
        uuid: "display-2",
        spaces: [space(id: 3, uuid: "uuid-3"), space(id: 4, uuid: "uuid-4")],
        current: 4),
    ]
    vm.refresh()
    #expect(vm.sections.first?.id == 4)
  }
}

@Suite("Space Move MRU Promotion")
struct SpaceMoveMRUTests {

  /// Marks space 3 (display-2's current space) and visually retargets it to
  /// display-1, mirroring the Cmd+Shift+X flow.
  private func markAndRetarget(_ vm: SwitcherViewModel) {
    vm.selectedItem = .spaceHeader(3)
    vm.toggleSpaceMoveMode()
    vm.moveMarkedSpaceToNextDisplay()
  }

  @Test("A retargeted space previews at the top of the target display's panel")
  func retargetedSpaceShowsFirstOnTargetDisplay() {
    // Space 2 (display-1) sits behind display-1's current space and behind
    // display-2's current space in MRU order; retargeting it to display-2
    // must show it FIRST among display-2's sections, not mid-list.
    let ds = makeEmptySpaceScenario()
    let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.showEmptySpaces = true
    vm.refresh()
    #expect(vm.sections.firstIndex(where: { $0.id == 2 }).map { $0 > 0 } == true)

    vm.selectedItem = .spaceHeader(2)
    vm.toggleSpaceMoveMode()
    vm.moveMarkedSpaceToNextDisplay()

    let onTarget = vm.sections.filter { $0.displayUUID == "display-2" }
    #expect(onTarget.first?.id == 2)
    #expect(vm.sections.first?.id == 2)
    #expect(vm.selectedItem == .spaceHeader(2))

    // Cycling on keeps it on top of whichever display it lands on.
    vm.moveMarkedSpaceToNextDisplay()
    #expect(vm.sections.first?.id == 2)
  }

  @Test("Executing a space move with activation promotes the moved space")
  func movedSpacePromotedWhenActivating() {
    let ds = makeEmptySpaceScenario()
    let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.showEmptySpaces = true
    vm.refresh()

    markAndRetarget(vm)
    #expect(vm.executeMoveSpace())

    // The switcher's own activation-after-move switches to the moved space
    // deep inside SpaceManager — focus inference can't see it, so the view
    // model must have stamped it directly.
    vm.refresh()
    #expect(vm.sections.first?.id == 3)

    // Once CGS reflects the move (space 3 now lives on display-1), the
    // MRU-top display must follow it — the panel uses this to decide which
    // display's panel starts with the selection.
    ds.displaySpaces = [
      display(
        uuid: "display-1",
        spaces: [
          space(id: 1, uuid: "uuid-1"), space(id: 2, uuid: "uuid-2"),
          space(id: 3, uuid: "uuid-3"),
        ],
        current: 3),
      display(
        uuid: "display-2",
        spaces: [space(id: 4, uuid: "uuid-4")],
        current: 4),
    ]
    vm.refresh()
    #expect(vm.mruTopDisplayUUID == "display-1")
  }

  @Test("mruTopDisplayUUID follows an explicit empty-space activation")
  func mruTopDisplayFollowsEmptySpaceActivation() {
    let ds = makeEmptySpaceScenario()
    let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.overrideDisplayUUID = "display-1"
    vm.refresh()
    #expect(vm.mruTopDisplayUUID == "display-1")

    vm.selectedItem = .spaceHeader(4)
    vm.activateSelected()
    vm.refresh()
    #expect(vm.mruTopDisplayUUID == "display-2")
  }

  @Test(
    "Moving the focused display's current space keeps it above the replacement's inferred stamp")
  func movedCurrentSpaceOutranksReplacementStamp() {
    let ds = makeEmptySpaceScenario()
    let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.showEmptySpaces = true
    vm.overrideDisplayUUID = "display-1"
    vm.refresh()

    // Move space 1 — the focused display's own current space — to display-2.
    vm.selectedItem = .spaceHeader(1)
    vm.toggleSpaceMoveMode()
    vm.moveMarkedSpaceToNextDisplay()
    #expect(vm.executeMoveSpace())

    // CGS reflects the move: display-1 slides replacement space 2 in beneath
    // the user; display-2 now hosts space 1 as its current (activated) space.
    ds.displaySpaces = [
      display(
        uuid: "display-1",
        spaces: [space(id: 2, uuid: "uuid-2")],
        current: 2),
      display(
        uuid: "display-2",
        spaces: [
          space(id: 3, uuid: "uuid-3"), space(id: 4, uuid: "uuid-4"),
          space(id: 1, uuid: "uuid-1"),
        ],
        current: 1),
    ]

    // The replacement's arrival reads as a focus transition on display-1, but
    // it is a side effect of the move — the explicitly activated space must
    // stay MRU-top and lead the panel with its display; the replacement still
    // earns the next rank as that display's most recent space.
    vm.refresh()
    #expect(vm.sections.first?.id == 1)
    #expect(vm.sections[1].id == 2)
    #expect(vm.mruTopDisplayUUID == "display-2")
  }

  @Test("Executing a space move without activation does not promote it")
  func movedSpaceNotPromotedWhenNotActivating() {
    let ds = makeEmptySpaceScenario()
    let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    vm.showEmptySpaces = true
    vm.activateMovedItem = false
    vm.refresh()

    markAndRetarget(vm)
    #expect(vm.executeMoveSpace())

    vm.refresh()
    #expect(vm.sections.first?.id != 3)
  }
}
