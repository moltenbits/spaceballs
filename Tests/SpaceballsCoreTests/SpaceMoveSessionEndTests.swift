import Testing

@testable import SpaceballsCore

/// How the Mission Control session ends after a Space-tile drag, and when
/// the Space is activated from outside instead.
@Suite("Space Move Session End")
struct SpaceMoveSessionEndTests {
  private final class Script {
    var dragCompleted = true
    var arrives = true
    var pressVerifies = true
    var missionControlPresentAfterPress = false
    var actions: [String] = []

    func deps() -> SpaceMoveSessionEnd.Dependencies {
      .init(
        dragCompleted: dragCompleted,
        awaitArrival: { [self] in
          actions.append("await-arrival")
          return arrives
        },
        pressTile: { [self] in
          actions.append("press")
          return pressVerifies
        },
        awaitMissionControlDismissed: { [self] in actions.append("await-dismissed") },
        dismissMissionControlIfPresent: { [self] in
          actions.append(missionControlPresentAfterPress ? "toggle" : "dismiss-if-present:absent")
        },
        log: { _ in })
    }
  }

  @Test("No activation requested: no press, no arrival wait, guarded dismissal only")
  func notRequested() {
    let script = Script()
    let outcome = SpaceMoveSessionEnd.run(activate: false, script.deps())
    #expect(outcome == .notRequested)
    #expect(script.actions == ["dismiss-if-present:absent"])
  }

  @Test("Arrived and press verified: press, wait for MC to close, no toggle")
  func activatedInSession() {
    let script = Script()
    let outcome = SpaceMoveSessionEnd.run(activate: true, script.deps())
    #expect(outcome == .activated)
    #expect(
      script.actions == ["await-arrival", "press", "await-dismissed", "dismiss-if-present:absent"])
  }

  @Test("Arrival never verifies: no press, session dismissed")
  func notArrived() {
    let script = Script()
    script.arrives = false
    let outcome = SpaceMoveSessionEnd.run(activate: true, script.deps())
    #expect(outcome == .notArrived)
    #expect(!script.actions.contains("press"))
    #expect(script.actions.last == "dismiss-if-present:absent")
  }

  @Test("Press fails or CGS never confirms: cleanup, then outside fallback allowed")
  func pressUnverified() {
    let script = Script()
    script.pressVerifies = false
    script.missionControlPresentAfterPress = true
    let outcome = SpaceMoveSessionEnd.run(activate: true, script.deps())
    #expect(outcome == .pressUnverified)
    #expect(script.actions == ["await-arrival", "press", "toggle"])
    #expect(
      SpaceMoveSessionEnd.outsideActivationNeeded(
        relocationVerified: true, activateAfterMove: true, sessionOutcome: outcome))
  }

  @Test("A failed drag never presses a tile")
  func dragFailed() {
    let script = Script()
    script.dragCompleted = false
    let outcome = SpaceMoveSessionEnd.run(activate: true, script.deps())
    #expect(outcome == .dragFailed)
    #expect(!script.actions.contains("press"))
    #expect(!script.actions.contains("await-arrival"))
  }

  @Test("Outside activation runs only for a verified relocation that wasn't activated in-session")
  func outsideActivationPolicy() {
    #expect(
      !SpaceMoveSessionEnd.outsideActivationNeeded(
        relocationVerified: true, activateAfterMove: true, sessionOutcome: .activated))
    #expect(
      !SpaceMoveSessionEnd.outsideActivationNeeded(
        relocationVerified: false, activateAfterMove: true, sessionOutcome: .notArrived))
    #expect(
      !SpaceMoveSessionEnd.outsideActivationNeeded(
        relocationVerified: true, activateAfterMove: false, sessionOutcome: .notRequested))
    #expect(
      SpaceMoveSessionEnd.outsideActivationNeeded(
        relocationVerified: true, activateAfterMove: true, sessionOutcome: .notArrived))
  }
}
