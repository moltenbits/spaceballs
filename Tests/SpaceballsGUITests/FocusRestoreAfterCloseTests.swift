import CoreGraphics
import Foundation
import Testing

@testable import SpaceballsCore
@testable import SpaceballsGUILib

private func makeBounds(x: Double, y: Double, width: Double, height: Double) -> CFDictionary {
  CGRectCreateDictionaryRepresentation(CGRect(x: x, y: y, width: width, height: height))
}

private func space(id: Int, uuid: String) -> [String: Any] {
  ["ManagedSpaceID": id, "uuid": uuid, "type": 0]
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

/// One display: space 1 is current with the terminal (10) frontmost and a
/// browser (11) behind it; spaces 2 and 3 are empty.
private func makeScenario(frontWindows: Bool = true) -> MutableMockDataSource {
  let ds = MutableMockDataSource()
  ds.displaySpaces = [
    display(
      uuid: "display-1",
      spaces: [space(id: 1, uuid: "u1"), space(id: 2, uuid: "u2"), space(id: 3, uuid: "u3")],
      current: 1)
  ]
  if frontWindows {
    ds.windowList = [
      window(id: 10, owner: "iTerm", name: "Spaceballs", pid: 100),
      window(id: 11, owner: "Safari", name: "Docs", pid: 200),
    ]
    ds.windowSpaces = [10: [1], 11: [1]]
  }
  return ds
}

/// Where focus returns after Cmd+Shift+W closes a Space from the panel.
@Suite("Focus Restore After Closing a Space")
struct FocusRestoreAfterCloseTests {

  @Test("Closing another Space returns to the window that was frontmost")
  func closingOtherSpaceRestoresFrontWindow() {
    let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: makeScenario()))
    vm.overrideDisplayUUID = "display-1"
    vm.refresh()
    #expect(vm.focusRestoreTarget(afterClosing: 2) == .window(10))
  }

  @Test("With nothing frontmost, closing another Space switches back to the focused Space")
  func closingOtherSpaceWithoutFrontWindow() {
    let vm = makeTestSwitcherViewModel(
      spaceManager: SpaceManager(dataSource: makeScenario(frontWindows: false)))
    vm.overrideDisplayUUID = "display-1"
    vm.refresh()
    #expect(vm.focusRestoreTarget(afterClosing: 3) == .space(1))
  }

  @Test("Closing the focused Space itself falls through to the next most recent Space")
  func closingFocusedSpaceUsesNextSection() {
    let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: makeScenario()))
    vm.overrideDisplayUUID = "display-1"
    vm.refresh()
    let target = vm.focusRestoreTarget(afterClosing: 1)
    guard case .space(let next)? = target else {
      Issue.record("expected a Space target, got \(String(describing: target))")
      return
    }
    #expect(next != 1)
    #expect(vm.sections.map(\.id).contains(next))
  }

  @Test("Before any refresh there is nothing to restore")
  func noRefreshNoTarget() {
    let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: makeScenario()))
    #expect(vm.focusRestoreTarget(afterClosing: 2) == nil)
  }
}
