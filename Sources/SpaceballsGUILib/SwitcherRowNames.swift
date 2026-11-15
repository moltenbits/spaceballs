/// The app name and window title a switcher row shows for one window.
public struct SwitcherRowNames: Equatable {
  public let appName: String
  public let windowTitle: String

  public init(appName: String, windowTitle: String) {
    self.appName = appName
    self.windowTitle = windowTitle
  }

  /// Names for a window owned by the app `ownerName` and titled `windowName`.
  ///
  /// Normally the row shows them as they are. A renamed copy of an app is the
  /// exception: a web app installed as "T3 Code (Spaceballs)" titles its window
  /// just "T3 Code", so the name that tells the copies apart is the app name.
  /// When the window title is the app name with its ending removed, the two
  /// swap places and the full name reads as the window title.
  public init(ownerName: String, windowName: String) {
    if Self.isLeadingPart(windowName, of: ownerName) {
      self.init(appName: windowName, windowTitle: ownerName)
    } else {
      self.init(appName: ownerName, windowTitle: windowName)
    }
  }

  /// Whether `name` starts with `part` and continues past it at a word
  /// boundary — "T3 Code" in "T3 Code (Spaceballs)", but not "Note" in "Notes".
  private static func isLeadingPart(_ part: String, of name: String) -> Bool {
    guard !part.isEmpty, name.hasPrefix(part) else { return false }
    guard let next = name.dropFirst(part.count).first else { return false }
    return !next.isLetter && !next.isNumber
  }
}
