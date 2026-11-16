import Testing

@testable import SpaceballsCore

/// macOS 27 lists the apps granted the accessibility permission under
/// Privacy & Security → "Device Control and Data Access"; the pane was named
/// "Accessibility" through macOS 26. Errors that send the user there must use
/// the name the user will find.
@Suite("Accessibility settings pane")
struct AccessibilitySettingsPaneTests {
  static let pane = "System Settings > Privacy & Security > Device Control and Data Access"

  @Test("A Space creation refused for lack of the permission names the pane macOS 27 shows")
  func spaceCreateError() {
    let description = SpaceCreateError.accessibilityNotTrusted.errorDescription ?? ""

    #expect(description.contains(Self.pane))
    #expect(!description.contains("Privacy & Security > Accessibility"))
  }

  @Test("A Space close refused for lack of the permission names the pane macOS 27 shows")
  func spaceCloseError() {
    let description = SpaceCloseError.accessibilityNotTrusted.errorDescription ?? ""

    #expect(description.contains(Self.pane))
    #expect(!description.contains("Privacy & Security > Accessibility"))
  }
}
