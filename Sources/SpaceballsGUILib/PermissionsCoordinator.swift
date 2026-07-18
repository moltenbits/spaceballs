import Foundation

/// Checks the app's required permissions (Accessibility, Screen Recording) and
/// prompts for any that are missing. Intended to run at launch and on every app
/// activation/reopen, so a permission lost mid-lifecycle (e.g. a TCC reset after
/// the app is re-signed) is surfaced immediately instead of failing silently.
///
/// Prompts are debounced per permission: the system Accessibility dialog is shown
/// on every prompting call while untrusted, so unthrottled activation checks
/// would stack dialogs. Screen Recording's dialog is shown at most once by the OS,
/// but the same debounce keeps the behavior uniform.
///
/// System calls are injected so the scheduling/debounce logic is unit-testable.
public final class PermissionsCoordinator {
  private let promptInterval: TimeInterval
  private let isAccessibilityTrusted: () -> Bool
  private let promptAccessibility: () -> Void
  private let hasScreenRecording: () -> Bool
  private let promptScreenRecording: () -> Void
  private let now: () -> Date

  private var lastAccessibilityPrompt: Date?
  private var lastScreenRecordingPrompt: Date?

  public init(
    promptInterval: TimeInterval = 60,
    isAccessibilityTrusted: @escaping () -> Bool,
    promptAccessibility: @escaping () -> Void,
    hasScreenRecording: @escaping () -> Bool,
    promptScreenRecording: @escaping () -> Void,
    now: @escaping () -> Date = { Date() }
  ) {
    self.promptInterval = promptInterval
    self.isAccessibilityTrusted = isAccessibilityTrusted
    self.promptAccessibility = promptAccessibility
    self.hasScreenRecording = hasScreenRecording
    self.promptScreenRecording = promptScreenRecording
    self.now = now
  }

  /// Checks both permissions, prompting for each missing one (subject to the
  /// per-permission debounce). Each permission is evaluated independently —
  /// notably, Screen Recording is requested even while Accessibility is missing.
  public func checkAndPrompt() {
    if !isAccessibilityTrusted() {
      lastAccessibilityPrompt = promptIfDue(lastPrompt: lastAccessibilityPrompt) {
        promptAccessibility()
      }
    }
    if !hasScreenRecording() {
      lastScreenRecordingPrompt = promptIfDue(lastPrompt: lastScreenRecordingPrompt) {
        promptScreenRecording()
      }
    }
  }

  /// Runs `prompt` unless one already ran within `promptInterval`. Returns the
  /// timestamp to store as the last prompt time.
  private func promptIfDue(lastPrompt: Date?, prompt: () -> Void) -> Date? {
    let currentTime = now()
    if let lastPrompt, currentTime.timeIntervalSince(lastPrompt) < promptInterval {
      return lastPrompt
    }
    prompt()
    return currentTime
  }
}
