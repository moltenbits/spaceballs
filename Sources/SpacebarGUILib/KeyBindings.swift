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
  public var createDefaultSpaces: UInt16
  public var createSpace: UInt16
  public var closeWindow: UInt16
  public var quitApp: UInt16
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
    createDefaultSpaces: UInt16 = 2,
    createSpace: UInt16 = 45,
    closeWindow: UInt16 = 13,
    quitApp: UInt16 = 12,
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
    self.createDefaultSpaces = createDefaultSpaces
    self.createSpace = createSpace
    self.closeWindow = closeWindow
    self.quitApp = quitApp
    self.cancel = cancel
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
      case .createDefaultSpaces: createDefaultSpaces
      case .createSpace: createSpace
      case .closeWindow: closeWindow
      case .quitApp: quitApp
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
      case .createDefaultSpaces: createDefaultSpaces = newValue
      case .createSpace: createSpace = newValue
      case .closeWindow: closeWindow = newValue
      case .quitApp: quitApp = newValue
      case .cancel: cancel = newValue
      }
    }
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
  case createDefaultSpaces
  case createSpace
  case closeWindow
  case quitApp
  case cancel

  public var id: String { rawValue }

  public var isDisplayShortcut: Bool {
    self == .nextDisplay || self == .previousDisplay
  }

  public var label: String {
    switch self {
    case .activateAndNext: "Activate / Next item"
    case .previousItem: "Previous item"
    case .nextSpace: "Next space"
    case .previousSpace: "Previous space"
    case .nextDisplay: "Next display"
    case .previousDisplay: "Previous display"
    case .renameSpace: "Rename space"
    case .cycleSortOrder: "Cycle sort order"
    case .createDefaultSpaces: "Create default spaces"
    case .createSpace: "Create new space"
    case .closeWindow: "Close window"
    case .quitApp: "Quit app"
    case .cancel: "Cancel"
    }
  }

  public var description: String {
    switch self {
    case .activateAndNext: "Opens the panel and navigates to the next item"
    case .previousItem: "Navigates to the previous item"
    case .nextSpace: "Jumps to the next space header"
    case .previousSpace: "Jumps to the previous space header"
    case .nextDisplay: "Cycles to the next display"
    case .previousDisplay: "Cycles to the previous display"
    case .renameSpace: "Starts renaming the selected space"
    case .cycleSortOrder: "Cycles through space sort orders"
    case .createDefaultSpaces: "Creates any missing spaces from your default names list"
    case .createSpace: "Creates a new unnamed desktop space"
    case .closeWindow: "Closes the selected window (Shift closes the space)"
    case .quitApp: "Quits the app owning the selected window"
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
