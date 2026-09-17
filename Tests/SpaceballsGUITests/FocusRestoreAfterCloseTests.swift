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

/// Display A: space 1 current with the terminal (10) frontmost and a browser
/// (11) behind it; space 2 empty. Display B: space 4 current with window 20;
/// space 5 empty.
private func makeScenario(frontWindows: Bool = true) -> MutableMockDataSource {
  let ds = MutableMockDataSource()
  ds.displaySpaces = [
    display(
      uuid: "display-A",
      spaces: [space(id: 1, uuid: "u1"), space(id: 2, uuid: "u2"), space(id: 3, uuid: "u3")],
      current: 1),
    display(
      uuid: "display-B",
      spaces: [space(id: 4, uuid: "u4"), space(id: 5, uuid: "u5")],
      current: 4),
  ]
  if frontWindows {
    ds.windowList = [
      window(id: 10, owner: "iTerm", name: "Spaceballs", pid: 100),
      window(id: 11, owner: "Safari", name: "Docs", pid: 200),
      window(id: 20, owner: "Code", name: "main.swift", pid: 300),
    ]
    ds.windowSpaces = [10: [1], 11: [1], 20: [4]]
  }
  return ds
}

/// Opens the panel the way the host does: refresh with the focused display's
/// context, then snapshot.
private func openPanel(_ vm: SwitcherViewModel, focusedDisplay: String) {
  vm.overrideDisplayUUID = focusedDisplay
  vm.refresh()
  vm.captureFocusSnapshot()
}

/// Where focus returns after Cmd+Shift+W closes a Space from the panel.
@Suite("Focus Restore After Closing a Space")
struct FocusRestoreAfterCloseTests {

  @Test("Closing another Space returns to the window that was frontmost")
  func closingOtherSpaceRestoresFrontWindow() {
    let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: makeScenario()))
    openPanel(vm, focusedDisplay: "display-A")
    #expect(vm.focusRestoreTarget(afterClosing: 2) == .window(10, fallbackSpace: 1))
  }

  @Test("With nothing frontmost, closing another Space switches back to the focused Space")
  func closingOtherSpaceWithoutFrontWindow() {
    let vm = makeTestSwitcherViewModel(
      spaceManager: SpaceManager(dataSource: makeScenario(frontWindows: false)))
    openPanel(vm, focusedDisplay: "display-A")
    #expect(vm.focusRestoreTarget(afterClosing: 3) == .space(1))
  }

  @Test("Closing the focused Space itself falls through to the next most recent Space")
  func closingFocusedSpaceUsesNextSection() {
    let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: makeScenario()))
    openPanel(vm, focusedDisplay: "display-A")
    let target = vm.focusRestoreTarget(afterClosing: 1)
    guard case .space(let next)? = target else {
      Issue.record("expected a Space target, got \(String(describing: target))")
      return
    }
    #expect(next != 1)
    #expect(vm.sections.map(\.id).contains(next))
  }

  @Test("Navigating the panel to another display before closing keeps the original window")
  func navigationRefreshDoesNotReplaceSnapshot() {
    // Single-panel display focus re-refreshes with display B's context
    // (AppDelegate.focusDisplay) without the user activating anything there.
    let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: makeScenario()))
    openPanel(vm, focusedDisplay: "display-A")
    vm.overrideDisplayUUID = "display-B"
    vm.refresh()
    // A hidden Space on B, and B's own current Space: both restore A's window.
    #expect(vm.focusRestoreTarget(afterClosing: 5) == .window(10, fallbackSpace: 1))
    #expect(vm.focusRestoreTarget(afterClosing: 4) == .window(10, fallbackSpace: 1))
    // Only closing A's original Space falls through to the next section.
    guard case .space(let next)? = vm.focusRestoreTarget(afterClosing: 1) else {
      Issue.record("expected a Space target when closing the original Space")
      return
    }
    #expect(next != 1)
  }

  @Test("Reopening the panel takes a fresh snapshot")
  func reopeningRefreshesSnapshot() {
    let ds = makeScenario()
    let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: ds))
    openPanel(vm, focusedDisplay: "display-A")
    #expect(vm.panelOpenFocus == .init(spaceID: 1, windowID: 10))
    openPanel(vm, focusedDisplay: "display-B")
    #expect(vm.panelOpenFocus == .init(spaceID: 4, windowID: 20))
  }

  @Test("Before any refresh there is nothing to restore")
  func noRefreshNoTarget() {
    let vm = makeTestSwitcherViewModel(spaceManager: SpaceManager(dataSource: makeScenario()))
    #expect(vm.focusRestoreTarget(afterClosing: 2) == nil)
  }
}
