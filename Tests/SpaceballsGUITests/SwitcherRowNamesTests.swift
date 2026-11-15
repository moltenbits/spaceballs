import Testing

@testable import SpaceballsGUILib

@Suite("Switcher row names")
struct SwitcherRowNamesTests {

  @Test("A window title that is the start of the app name swaps places with it")
  func titleIsLeadingPartOfAppName() {
    let names = SwitcherRowNames(ownerName: "T3 Code (Spaceballs)", windowName: "T3 Code")

    #expect(names == SwitcherRowNames(appName: "T3 Code", windowTitle: "T3 Code (Spaceballs)"))
  }

  @Test(
    "The swap needs a word boundary after the window title",
    arguments: [
      ("Mail — Work", "Mail"),
      ("Notes-2", "Notes"),
      ("Slack (Client)", "Slack"),
    ])
  func swapsAtWordBoundary(ownerName: String, windowName: String) {
    let names = SwitcherRowNames(ownerName: ownerName, windowName: windowName)

    #expect(names == SwitcherRowNames(appName: windowName, windowTitle: ownerName))
  }

  @Test(
    "Every other window keeps its app name and window title",
    arguments: [
      // An ordinary document, page or project title.
      ("Terminal", "bash"),
      ("Xcode", "spaceballs — SwitcherRowView.swift"),
      // The title equals the app name.
      ("Messages", "Messages"),
      // The title ends in the middle of a word of the app name.
      ("Notes", "Note"),
      ("Code2", "Code"),
      // The app name is the leading part of the title, not the reverse.
      ("T3 Code", "T3 Code (Spaceballs)"),
      // The title appears in the app name, but not at its start.
      ("Google Chrome", "Chrome"),
      // Letter case differs.
      ("T3 Code (Spaceballs)", "t3 code"),
      // No title at all.
      ("Contacts", ""),
    ])
  func keepsNames(ownerName: String, windowName: String) {
    let names = SwitcherRowNames(ownerName: ownerName, windowName: windowName)

    #expect(names == SwitcherRowNames(appName: ownerName, windowTitle: windowName))
  }
}
