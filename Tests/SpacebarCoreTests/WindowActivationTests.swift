import ApplicationServices
import Testing

@testable import SpacebarCore

// MARK: - Window Activation Tests

@Suite("Window Activation")
struct WindowActivationTests {

  @Test("Throws windowNotFound when window ID does not exist")
  func windowNotFound() {
    let ds = MockDataSource()
    let manager = SpaceManager(dataSource: ds)

    #expect(throws: WindowActivationError.windowNotFound(windowID: 99999)) {
      try manager.activateWindow(id: 99999)
    }
  }

  @Test(
    "Throws accessibilityNotTrusted when AX permission is missing",
    .enabled(if: !AXIsProcessTrusted(), "Requires AX trust to be absent (e.g. CI)")
  )
  func accessibilityNotTrusted() throws {
    var ds = MockDataSource()
    ds.windowList = [
      makeWindowDict(id: 1, ownerName: "TestApp")
    ]
    ds.windowSpaces = [1: [100]]

    let manager = SpaceManager(dataSource: ds)

    #expect(throws: WindowActivationError.accessibilityNotTrusted) {
      try manager.activateWindow(id: 1)
    }
  }

  @Test("Error descriptions are human-readable")
  func errorDescriptions() {
    let cases: [(WindowActivationError, String)] = [
      (
        .windowNotFound(windowID: 42),
        "No window found with ID 42. Use 'spacebar list' to see available windows."
      ),
      (
        .accessibilityNotTrusted,
        "Accessibility permission required. A system prompt should have appeared — grant access in System Settings and re-run the command."
      ),
      (
        .appActivationFailed(appName: "Finder", pid: 123),
        "Failed to activate Finder (PID 123)."
      ),
    ]

    for (error, expected) in cases {
      #expect(error.localizedDescription == expected)
    }
  }
}
