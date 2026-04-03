import Foundation

public enum WindowActivationError: Error, Equatable, LocalizedError {
  case windowNotFound(windowID: Int)
  case accessibilityNotTrusted
  case appActivationFailed(appName: String, pid: Int)

  public var errorDescription: String? {
    switch self {
    case .windowNotFound(let windowID):
      return "No window found with ID \(windowID). Use 'spacebar list' to see available windows."
    case .accessibilityNotTrusted:
      return
        "Accessibility permission required. A system prompt should have appeared — grant access in System Settings and re-run the command."
    case .appActivationFailed(let appName, let pid):
      return "Failed to activate \(appName) (PID \(pid))."
    }
  }
}

public enum SpaceCreateError: Error, Equatable, LocalizedError {
  case accessibilityNotTrusted
  case dockNotRunning
  case missionControlNotFound
  case addButtonNotFound

  public var errorDescription: String? {
    switch self {
    case .accessibilityNotTrusted:
      return
        "Accessibility permission required. Grant access in System Settings > Privacy & Security > Accessibility."
    case .dockNotRunning:
      return "The Dock process is not running."
    case .missionControlNotFound:
      return "Mission Control did not appear. Ensure it is not disabled."
    case .addButtonNotFound:
      return
        "Could not find the 'Add Desktop' button in Mission Control."
    }
  }
}

public enum SpaceSwitchError: Error, Equatable, LocalizedError {
  case spaceNotFound(spaceID: UInt64)
  case displayNotFound(displayUUID: String)
  case accessibilityNotTrusted
  case notDesktopSpace(spaceID: UInt64)

  public var errorDescription: String? {
    switch self {
    case .spaceNotFound(let spaceID):
      return "No space found with ID \(spaceID). Use 'spacebar list' to see available spaces."
    case .displayNotFound(let displayUUID):
      return "Could not resolve display for UUID \(displayUUID)."
    case .accessibilityNotTrusted:
      return
        "Accessibility permission required. A system prompt should have appeared — grant access in System Settings and re-run the command."
    case .notDesktopSpace(let spaceID):
      return
        "Space \(spaceID) is a fullscreen space. Only desktop spaces can be switched to directly."
    }
  }
}
