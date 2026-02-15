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
        "Accessibility permission required. Grant access in System Settings → Privacy & Security → Accessibility."
    case .appActivationFailed(let appName, let pid):
      return "Failed to activate \(appName) (PID \(pid))."
    }
  }
}
