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

  /// True once Screen Recording has been observed missing by a check; armed for
  /// `didScreenRecordingJustBecomeGranted`.
  private var sawScreenRecordingMissing = false

  /// Checks both permissions and prompts for the FIRST missing one, in order
  /// (Accessibility, then Screen Recording), subject to the per-permission
  /// debounce.
  ///
  /// Sequencing is deliberate: macOS shows the Screen Recording consent dialog
  /// at most once per process, and a request made while another TCC dialog is
  /// up is silently dropped — so requesting SR while the Accessibility dialog
  /// is pending wastes the one prompt and forces an app relaunch to ever see
  /// it. SR is requested on the first check after Accessibility is granted
  /// (the tap-ready callback and app activations both re-check).
  public func checkAndPrompt() {
    if !hasScreenRecording() {
      sawScreenRecordingMissing = true
    }
    if !isAccessibilityTrusted() {
      lastAccessibilityPrompt = promptIfDue(lastPrompt: lastAccessibilityPrompt) {
        promptAccessibility()
      }
      return
    }
    if !hasScreenRecording() {
      lastScreenRecordingPrompt = promptIfDue(lastPrompt: lastScreenRecordingPrompt) {
        promptScreenRecording()
      }
    }
  }

  /// One-shot: returns `true` the first time Screen Recording is granted after
  /// a check observed it missing. Used to self-relaunch the app — the grant
  /// only takes effect on a fresh WindowServer connection, and the system's
  /// own "Quit & Reopen" reliably quits but often never reopens.
  public func didScreenRecordingJustBecomeGranted() -> Bool {
    guard sawScreenRecordingMissing, hasScreenRecording() else { return false }
    sawScreenRecordingMissing = false
    return true
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
