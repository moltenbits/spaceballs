import Foundation

/// How an open Mission Control session ends after a Space-tile drag:
/// ideally on the moved Space itself, by pressing its tile in the target
/// bar, so the Space becomes active with no dismissal animation and no
/// separate switch; otherwise by a guarded dismissal. Pure orchestration
/// over injected operations so the guarantees are unit-tested: no press
/// without a completed drag and a confirmed CGS arrival, no blind awake
/// TOGGLE once the press has dismissed Mission Control, and every failure
/// path still leaves Mission Control closed.
public enum SpaceMoveSessionEnd {
  struct Dependencies {
    /// Whether the drag the activation belongs to completed.
    var dragCompleted: Bool
    /// Blocks until CGS lists the Space on the target display, or times out.
    var awaitArrival: () -> Bool
    /// Presses the Space's tile in the target bar and verifies via CGS.
    var pressTile: () -> Bool
    /// Blocks until Mission Control's AX group is gone, or times out.
    var awaitMissionControlDismissed: () -> Void
    /// Sends the awake TOGGLE only if Mission Control is still present.
    var dismissMissionControlIfPresent: () -> Void
    var log: (String) -> Void
  }

  public enum Outcome: Equatable {
    /// No activation was requested; the session was dismissed.
    case notRequested
    /// The moved Space is current on the target display; the press ended the session.
    case activated
    case dragFailed
    /// CGS never listed the Space on the target display in time.
    case notArrived
    /// The tile press failed or CGS did not confirm the landing.
    case pressUnverified
  }

  static func run(activate: Bool, _ deps: Dependencies) -> Outcome {
    let outcome: Outcome = {
      guard activate else { return .notRequested }
      guard deps.dragCompleted else { return .dragFailed }
      guard deps.awaitArrival() else {
        deps.log("in-session press skipped: CGS hasn't listed the space on the target yet")
        return .notArrived
      }
      return deps.pressTile() ? .activated : .pressUnverified
    }()
    if outcome == .activated {
      // The press dismisses Mission Control itself; wait for that before the
      // guarded dismissal below, or the toggle would reopen it.
      deps.awaitMissionControlDismissed()
    }
    deps.dismissMissionControlIfPresent()
    return outcome
  }

  /// Whether the Space should be activated from outside the session after
  /// the move: only for a verified relocation with activation requested,
  /// and never when the in-session press already made it current.
  static func outsideActivationNeeded(
    relocationVerified: Bool, activateAfterMove: Bool, sessionOutcome: Outcome
  ) -> Bool {
    relocationVerified && activateAfterMove && sessionOutcome != .activated
  }
}
