import Foundation

// MARK: - Key Bindings

public struct KeyBindings: Codable, Equatable {
  public var activateAndNext: UInt16
  public var previousItem: UInt16
  public var nextSpace: UInt16
  public var previousSpace: UInt16
  public var nextDisplay: UInt16
  public var previousDisplay: UInt16
  public var renameSpace: UInt16
  public var cycleSortOrder: UInt16
  public var createSpace: UInt16
  public var closeWindow: UInt16
  public var minimizeWindow: UInt16
  public var quitApp: UInt16
  public var moveWindow: UInt16
  public var ejectSpaces: UInt16
  public var showResize: UInt16
  public var cancel: UInt16

  public init(
    activateAndNext: UInt16 = 48,
    previousItem: UInt16 = 50,
    nextSpace: UInt16 = 125,
    previousSpace: UInt16 = 126,
    nextDisplay: UInt16 = 124,
    previousDisplay: UInt16 = 123,
    renameSpace: UInt16 = 15,
    cycleSortOrder: UInt16 = 1,
    createSpace: UInt16 = 45,
    closeWindow: UInt16 = 13,
    minimizeWindow: UInt16 = 46,
    quitApp: UInt16 = 12,
    moveWindow: UInt16 = 7,
    ejectSpaces: UInt16 = 14,
    showResize: UInt16 = 2,
    cancel: UInt16 = 53
  ) {
    self.activateAndNext = activateAndNext
    self.previousItem = previousItem
    self.nextSpace = nextSpace
    self.previousSpace = previousSpace
    self.nextDisplay = nextDisplay
    self.previousDisplay = previousDisplay
    self.renameSpace = renameSpace
    self.cycleSortOrder = cycleSortOrder
    self.createSpace = createSpace
    self.closeWindow = closeWindow
    self.minimizeWindow = minimizeWindow
    self.quitApp = quitApp
    self.moveWindow = moveWindow
    self.ejectSpaces = ejectSpaces
    self.showResize = showResize
    self.cancel = cancel
  }

  // Backward-compatible decoder — new fields default gracefully
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    activateAndNext = try c.decodeIfPresent(UInt16.self, forKey: .activateAndNext) ?? 48
    previousItem = try c.decodeIfPresent(UInt16.self, forKey: .previousItem) ?? 50
    nextSpace = try c.decodeIfPresent(UInt16.self, forKey: .nextSpace) ?? 125
    previousSpace = try c.decodeIfPresent(UInt16.self, forKey: .previousSpace) ?? 126
    nextDisplay = try c.decodeIfPresent(UInt16.self, forKey: .nextDisplay) ?? 124
    previousDisplay = try c.decodeIfPresent(UInt16.self, forKey: .previousDisplay) ?? 123
    renameSpace = try c.decodeIfPresent(UInt16.self, forKey: .renameSpace) ?? 15
    cycleSortOrder = try c.decodeIfPresent(UInt16.self, forKey: .cycleSortOrder) ?? 1
    createSpace = try c.decodeIfPresent(UInt16.self, forKey: .createSpace) ?? 45
    closeWindow = try c.decodeIfPresent(UInt16.self, forKey: .closeWindow) ?? 13
    minimizeWindow = try c.decodeIfPresent(UInt16.self, forKey: .minimizeWindow) ?? 46
    quitApp = try c.decodeIfPresent(UInt16.self, forKey: .quitApp) ?? 12
    let decodedMoveWindow = try c.decodeIfPresent(UInt16.self, forKey: .moveWindow)
    moveWindow =
      c.contains(.minimizeWindow)
      ? (decodedMoveWindow ?? 7)
      : Self.migrateMoveWindow(
        decodedMoveWindow)
    ejectSpaces = try c.decodeIfPresent(UInt16.self, forKey: .ejectSpaces) ?? 14
    showResize = try c.decodeIfPresent(UInt16.self, forKey: .showResize) ?? 2
    cancel = try c.decodeIfPresent(UInt16.self, forKey: .cancel) ?? 53
  }

  private enum CodingKeys: String, CodingKey {
    case activateAndNext, previousItem, nextSpace, previousSpace
    case nextDisplay, previousDisplay, renameSpace, cycleSortOrder
    case createSpace, closeWindow, minimizeWindow, quitApp, moveWindow, ejectSpaces, showResize,
      cancel
  }

  public subscript(action: ShortcutAction) -> UInt16 {
    get {
      switch action {
      case .activateAndNext: activateAndNext
      case .previousItem: previousItem
      case .nextSpace: nextSpace
      case .previousSpace: previousSpace
      case .nextDisplay: nextDisplay
      case .previousDisplay: previousDisplay
      case .renameSpace: renameSpace
      case .cycleSortOrder: cycleSortOrder
      case .createSpace: createSpace
      case .closeWindow: closeWindow
      case .minimizeWindow: minimizeWindow
      case .quitApp: quitApp
      case .moveWindow: moveWindow
      case .ejectSpaces: ejectSpaces
      case .showResize: showResize
      case .cancel: cancel
      }
    }
    set {
      switch action {
      case .activateAndNext: activateAndNext = newValue
      case .previousItem: previousItem = newValue
      case .nextSpace: nextSpace = newValue
      case .previousSpace: previousSpace = newValue
      case .nextDisplay: nextDisplay = newValue
      case .previousDisplay: previousDisplay = newValue
      case .renameSpace: renameSpace = newValue
      case .cycleSortOrder: cycleSortOrder = newValue
      case .createSpace: createSpace = newValue
      case .closeWindow: closeWindow = newValue
      case .minimizeWindow: minimizeWindow = newValue
      case .quitApp: quitApp = newValue
      case .moveWindow: moveWindow = newValue
      case .ejectSpaces: ejectSpaces = newValue
      case .showResize: showResize = newValue
      case .cancel: cancel = newValue
      }
    }
  }

  /// Resolves a navigation key press. The vertical keys (defaults ↓ ↑) step
  /// space by space — Shift jumps straight to the display below/above. The
  /// horizontal keys (defaults → ←) always target the display in their
  /// direction; Shift makes no difference there. Each binding slot carries
  /// the physical direction its default arrow points in.
  public func navigationCommand(keyCode: UInt16, shiftHeld: Bool) -> NavigationCommand? {
    switch keyCode {
    case nextSpace: return shiftHeld ? .display(.down) : .nextSpace
    case previousSpace: return shiftHeld ? .display(.up) : .previousSpace
    case nextDisplay: return .display(.right)
    case previousDisplay: return .display(.left)
    default: return nil
    }
  }

  /// Resolves the minimize key to its window- or Space-level action.
  public func minimizeCommand(keyCode: UInt16, shiftHeld: Bool) -> MinimizeCommand? {
    guard keyCode == minimizeWindow else { return nil }
    return shiftHeld ? .space : .window
  }

  /// Returns pairs of actions that share the same key code.
  public func conflicts() -> [(ShortcutAction, ShortcutAction)] {
    var seen: [UInt16: ShortcutAction] = [:]
    var result: [(ShortcutAction, ShortcutAction)] = []
    for action in ShortcutAction.allCases {
      let code = self[action]
      if let existing = seen[code] {
        result.append((existing, action))
      } else {
        seen[code] = action
      }
    }
    return result
  }

  private static func migrateMoveWindow(_ legacyKeyCode: UInt16?) -> UInt16 {
    guard let legacyKeyCode, legacyKeyCode != 46 else { return 7 }
    return legacyKeyCode
  }
}

// MARK: - Navigation Command

/// What a navigation key press should do, after modifiers are applied.
public enum NavigationCommand: Equatable {
  case nextSpace
  case previousSpace
  case display(ArrangementDirection)
}

public enum MinimizeCommand: Equatable {
  case window
  case space
}

// MARK: - Shortcut Action

public enum ShortcutAction: String, CaseIterable, Identifiable {
  case activateAndNext
  case previousItem
  case nextSpace
  case previousSpace
  case nextDisplay
  case previousDisplay
  case renameSpace
  case cycleSortOrder
  case createSpace
  case closeWindow
  case minimizeWindow
  case quitApp
  case moveWindow
  case ejectSpaces
  case showResize
  case cancel

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .activateAndNext: "Activate / Next item"
    case .previousItem: "Previous item"
    case .nextSpace: "Next space"
    case .previousSpace: "Previous space"
    case .nextDisplay: "Display to the right"
    case .previousDisplay: "Display to the left"
    case .renameSpace: "Rename space"
    case .cycleSortOrder: "Cycle sort order"
    case .createSpace: "Workspaces menu"
    case .closeWindow: "Close window"
    case .minimizeWindow: "Minimize window"
    case .quitApp: "Quit app"
    case .moveWindow: "Move window"
    case .ejectSpaces: "Eject Spaces"
    case .showResize: "Show resize grid"
    case .cancel: "Cancel"
    }
  }

  public var description: String {
    switch self {
    case .activateAndNext: "Opens the panel and navigates to the next item"
    case .previousItem: "Navigates to the previous item"
    case .nextSpace: "Next space, continuing onto the display below (Shift: display below)"
    case .previousSpace: "Previous space, continuing onto the display above (Shift: display above)"
    case .nextDisplay: "Moves to the display on the right (Shift optional)"
    case .previousDisplay: "Moves to the display on the left (Shift optional)"
    case .renameSpace: "Starts renaming the selected space"
    case .cycleSortOrder: "Cycles through space sort orders"
    case .createSpace: "Opens the Workspaces menu to launch a workspace or create an empty macOS Space"
    case .closeWindow: "Closes the selected window (Shift closes the space)"
    case .minimizeWindow:
      "Minimizes the selected window (Shift minimizes every window in its Space)"
    case .quitApp: "Quits the app owning the selected window"
    case .moveWindow: "Marks the selected window for moving to another space"
    case .ejectSpaces:
      "Moves all external displays' Spaces to the built-in display for safe disconnect "
        + "(Shift restores them)"
    case .showResize: "Opens the resize grid panel (Cmd+Shift)"
    case .cancel: "Dismisses the panel"
    }
  }
}

// MARK: - Key Code Display Names

public enum KeyCodeNames {
  public static func displayName(for keyCode: UInt16) -> String {
    names[keyCode] ?? "Key \(keyCode)"
  }

  private static let names: [UInt16: String] = [
    // Modifiers (not used as shortcut keys, but included for completeness)
    // Navigation
    48: "Tab",
    49: "Space",
    36: "Return",
    76: "Enter",
    51: "Delete",
    117: "Forward Delete",
    53: "Escape",

    // Arrows
    123: "←",
    124: "→",
    125: "↓",
    126: "↑",

    // Letters
    0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
    34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
    35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
    13: "W", 7: "X", 16: "Y", 6: "Z",

    // Numbers
    29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
    22: "6", 26: "7", 28: "8", 25: "9",

    // Punctuation
    50: "`", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\",
    41: ";", 39: "'", 43: ",", 47: ".", 44: "/",

    // F-keys
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
    98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
  ]
}
