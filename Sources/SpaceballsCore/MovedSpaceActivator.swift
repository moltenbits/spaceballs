import Foundation

/// Makes a just-moved Space current on its new display and verifies it.
///
/// The first attempt activates the Space the way the switcher panel does; if
/// CGS does not report it current, one retry goes through the plain Space
/// switch. Both can end in an asynchronous Mission Control leg (a tile
/// press scheduled after MC opens), so a retry must never be issued while
/// Mission Control is still present: its DockSwipe would decline and the
/// fallback would send the awake TOGGLE, dismissing the session beneath the
/// pending press. Attempts are therefore serialized on MC's absence, with a
/// cap, and an unverified activation is reported, never turned into a
/// failure of the completed relocation.
struct MovedSpaceActivator {
  struct Dependencies {
    /// First attempt: activate the Space (a window on it when it has one).
    var activate: () throws -> Void
    /// Retry: the plain Space switch.
    var switchSpace: () throws -> Void
    /// Whether the Space is current on its display (CGS).
    var isCurrent: () -> Bool
    /// Whether Mission Control's AX group is present — an attempt's async
    /// leg is in flight while it is.
    var missionControlPresent: () -> Bool
    var sleep: (TimeInterval) -> Void
    var now: () -> Date
    var log: (String) -> Void
  }

  var verifyTimeout: TimeInterval = 1.0
  /// Longest to wait for an attempt's Mission Control leg to finish before
  /// giving up on serializing behind it.
  var missionControlTimeout: TimeInterval = 4.0
  var pollInterval: TimeInterval = 0.05

  /// Returns whether the Space verified as current.
  func run(_ deps: Dependencies) -> Bool {
    for attempt in 1...2 {
      do {
        if attempt == 1 { try deps.activate() } else { try deps.switchSpace() }
      } catch {
        deps.log("post-move activation attempt \(attempt) failed: \(error)")
      }
      if awaitCurrent(deps) {
        deps.log("post-move activation verified attempt=\(attempt)")
        return true
      }
      // The attempt may still be running its Mission Control leg; let it
      // finish (or time out) before deciding, and never toggle MC under it.
      if deps.missionControlPresent() {
        let settled = awaitMissionControlAbsent(deps)
        deps.log(
          "post-move activation attempt \(attempt): Mission Control leg "
            + (settled ? "finished" : "still present after \(missionControlTimeout)s"))
        if deps.isCurrent() {
          deps.log("post-move activation verified attempt=\(attempt)")
          return true
        }
        if !settled {
          deps.log("post-move activation: not retrying while Mission Control is present")
          return false
        }
      }
      deps.log("post-move activation attempt \(attempt): space not current")
    }
    return deps.isCurrent()
  }

  private func awaitCurrent(_ deps: Dependencies) -> Bool {
    let deadline = deps.now().addingTimeInterval(verifyTimeout)
    while true {
      if deps.isCurrent() { return true }
      if deps.now() >= deadline { return false }
      deps.sleep(pollInterval)
    }
  }

  private func awaitMissionControlAbsent(_ deps: Dependencies) -> Bool {
    let deadline = deps.now().addingTimeInterval(missionControlTimeout)
    while deps.missionControlPresent() {
      if deps.now() >= deadline { return false }
      deps.sleep(pollInterval)
    }
    return true
  }
}
