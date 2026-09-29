import AppKit
import CoreGraphics
import Testing

@testable import SpaceballsCore

@Suite("Workspace Display Focus")
struct WorkspaceDisplayFocusTests {
  @Test("Single-display restores and already-focused targets need no focus action")
  func skipsUnnecessaryFocus() {
    #expect(
      !SpaceManager.workspaceDisplayNeedsFocus(
        displayCount: 1, focusedWindowSpaceIDs: [], targetSpaceID: 1))
    #expect(
      !SpaceManager.workspaceDisplayNeedsFocus(
        displayCount: 2, focusedWindowSpaceIDs: [1], targetSpaceID: 1))
    #expect(
      SpaceManager.workspaceDisplayNeedsFocus(
        displayCount: 2, focusedWindowSpaceIDs: [2], targetSpaceID: 1))
    #expect(
      SpaceManager.workspaceDisplayNeedsFocus(
        displayCount: 2, focusedWindowSpaceIDs: [], targetSpaceID: 1))
    #expect(
      SpaceManager.workspaceDisplayNeedsFocus(
        displayCount: 2, focusedWindowSpaceIDs: [1, 2], targetSpaceID: 1))
  }

  @Test("Desktop focus takes the first exposed candidate and stays on the target display")
  func avoidsWindows() throws {
    let frame = CGRect(x: 1800, y: -500, width: 1200, height: 800)
    let window = CGRect(x: 1800, y: -500, width: 900, height: 800)
    var probed: [CGPoint] = []
    let point = try #require(
      SpaceManager.workspaceDesktopFocusPoint(in: frame) { candidate in
        probed.append(candidate)
        return !window.contains(candidate)
      })
    #expect(frame.contains(point))
    #expect(!window.contains(point))
    #expect(probed.last == point)
    #expect(probed.dropLast().allSatisfy { window.contains($0) })
  }

  @Test("A click may land only on nothing or a desktop-level window")
  func hitPolicy() {
    typealias Hit = SpaceManager.WorkspaceDesktopHit
    func window(pid: Int, layer: Int?) -> Hit {
      var entry: [String: Any] = [kCGWindowOwnerPID as String: pid]
      if let layer { entry[kCGWindowLayer as String] = layer }
      return .window(entry)
    }
    let own = Int(ProcessInfo.processInfo.processIdentifier)
    #expect(SpaceManager.workspaceDesktopHitAllows(.nothing))
    // Finder's desktop and the wallpaper sit far below zero.
    #expect(SpaceManager.workspaceDesktopHitAllows(window(pid: 694, layer: -2_147_483_603)))
    // Anything the click would really reach blocks the candidate, whatever its level
    // or owner: a normal window, a floating panel, visible Notification Center
    // content, a status-level panel, a popup menu, or our own settings window. The
    // click-through restore overlay never comes back from the hit test at all.
    for layer in [0, 3, 21, 25, 101] {
      #expect(!SpaceManager.workspaceDesktopHitAllows(window(pid: 1, layer: layer)))
      #expect(!SpaceManager.workspaceDesktopHitAllows(window(pid: own, layer: layer)))
    }
    // Hits that prove nothing are rejected: unknown level, unresolved number, no AppKit.
    #expect(!SpaceManager.workspaceDesktopHitAllows(window(pid: 1, layer: nil)))
    #expect(!SpaceManager.workspaceDesktopHitAllows(window(pid: own, layer: nil)))
    #expect(!SpaceManager.workspaceDesktopHitAllows(.window([:])))
    #expect(!SpaceManager.workspaceDesktopHitAllows(.unavailable))
  }

  @Test("Hit testing initializes AppKit for a process that has none, without clicking")
  func hitTestingInitialization() {
    #expect(SpaceManager.ensureHitTestingAvailable())
    #expect(NSApp != nil)
  }

  @Test("A covered desktop never falls back to clicking through a window")
  func coveredDesktop() {
    let frame = CGRect(x: 0, y: 25, width: 1200, height: 800)
    var probes = 0
    #expect(
      SpaceManager.workspaceDesktopFocusPoint(in: frame) { _ in
        probes += 1
        return false
      } == nil)
    #expect(probes == 9)
    #expect(SpaceManager.workspaceDesktopFocusPoint(in: .zero) { _ in true } == nil)
  }
}
