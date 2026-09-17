import AppKit
import CoreGraphics
import Foundation

/// Activation policy and bundle identifier of the application owning a pid.
public struct AppInfo {
  public let policy: NSApplication.ActivationPolicy
  public let bundleID: String?

  public init(policy: NSApplication.ActivationPolicy, bundleID: String?) {
    self.policy = policy
    self.bundleID = bundleID
  }
}

/// Abstracts the system calls that SpaceManager depends on,
/// enabling tests to inject mock data.
public protocol SystemDataSource {
  /// Returns raw display/space dictionaries from CGSCopyManagedDisplaySpaces.
  func fetchManagedDisplaySpaces() -> [[String: Any]]

  /// Returns raw window info dictionaries from CGWindowListCopyWindowInfo(.optionAll).
  func fetchWindowList() -> [[String: Any]]

  /// Returns on-screen window info dictionaries in front-to-back Z-order.
  /// Uses CGWindowListCopyWindowInfo(.optionOnScreenOnly) which guarantees ordering.
  func fetchOnScreenWindowList() -> [[String: Any]]

  /// Returns the space IDs that the given window belongs to.
  func fetchSpacesForWindow(_ windowID: Int) -> [UInt64]

  /// Returns the CGWindowIDs the given process currently exposes as live windows
  /// via the Accessibility API (`kAXWindowsAttribute`) — i.e. the app's windows on
  /// the *current* Space, including minimized ones but excluding windows that have
  /// been closed. The window server keeps closed windows in `CGWindowListCopyWindowInfo`
  /// (ordered out, still mapped to a Space) until the owning process exits, so this
  /// is the only reliable way to tell a closed window from a minimized one.
  ///
  /// Returns `nil` when the information is unavailable (AX not trusted, the app has
  /// no AX support, or the query fails). Callers MUST treat `nil` as "unknown" and
  /// keep the window rather than dropping it.
  func liveAXWindowIDs(pid: pid_t) -> Set<CGWindowID>?

  /// Returns the CGWindowIDs that Accessibility currently reports as minimized
  /// for the given process. `nil` means the state could not be determined.
  func minimizedAXWindowIDs(pid: pid_t) -> Set<CGWindowID>?

  /// Whether the app's live AX window list contains `windowID`. Unlike
  /// `liveAXWindowIDs`, this stays `.unknown` when the list was readable but
  /// some element could not be mapped to a CGWindowID, so an incomplete read
  /// is never taken for absence.
  func axWindowPresence(pid: pid_t, windowID: CGWindowID) -> AXWindowPresence

  /// Returns the activation policy and bundle identifier of the application
  /// owning `pid`, or `nil` when the pid maps to no LaunchServices-registered
  /// application. Callers MUST treat `nil` as "keep the window": most pids
  /// belong to plain daemons, and a lookup that instead consulted the live
  /// system would make fabricated test pids resolve to whatever real process
  /// happens to occupy them on the host.
  func appInfo(pid: pid_t) -> AppInfo?
}

extension SystemDataSource {
  /// Default: liveness unknown. Conforming types that can answer (the real CGS
  /// data source, and tests) override this; everyone else keeps every window.
  public func liveAXWindowIDs(pid: pid_t) -> Set<CGWindowID>? { nil }

  /// Default: minimization state unknown.
  public func minimizedAXWindowIDs(pid: pid_t) -> Set<CGWindowID>? { nil }

  /// Default: derived from `liveAXWindowIDs`, whose set is treated as complete.
  public func axWindowPresence(pid: pid_t, windowID: CGWindowID) -> AXWindowPresence {
    guard let liveIDs = liveAXWindowIDs(pid: pid) else { return .unknown }
    return liveIDs.contains(windowID) ? .present : .absent
  }

  /// Default: no LaunchServices registration known, so windows are kept.
  public func appInfo(pid: pid_t) -> AppInfo? { nil }
}

/// Answer to "does this app's AX window list contain this window?".
public enum AXWindowPresence: Equatable {
  case present
  case absent
  /// The list could not be read, or was read but not fully mapped to window
  /// IDs — the window may well be there. Never a ground for a closed verdict.
  case unknown

  /// Folds one enumeration into a verdict: a match is `.present`; no match is
  /// `.absent` only when every element mapped to a window ID.
  static func resolve(targetFound: Bool, unmappedElements: Int) -> AXWindowPresence {
    if targetFound { return .present }
    return unmappedElements == 0 ? .absent : .unknown
  }
}
