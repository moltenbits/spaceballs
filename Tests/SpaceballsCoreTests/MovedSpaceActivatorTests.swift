import Foundation
import Testing

@testable import SpaceballsCore

/// A scripted world for `MovedSpaceActivator`: a fake clock advanced by
/// `sleep`, and Mission Control presence / currentness that change at
/// scripted times, so a pending asynchronous MC leg can be modelled.
private final class World {
  var time: TimeInterval = 0
  var current = false
  /// Time ranges during which Mission Control is present.
  var missionControl: [ClosedRange<TimeInterval>] = []
  /// Time at which the Space becomes current (nil: never).
  var becomesCurrentAt: TimeInterval?
  var activateCalls = 0
  var switchCalls = 0
  var activateThrows = false
  var log: [String] = []

  func deps() -> MovedSpaceActivator.Dependencies {
    .init(
      activate: { [self] in
        activateCalls += 1
        if activateThrows { throw NSError(domain: "test", code: 1) }
      },
      switchSpace: { [self] in switchCalls += 1 },
      isCurrent: { [self] in
        if let at = becomesCurrentAt, time >= at { current = true }
        return current
      },
      missionControlPresent: { [self] in missionControl.contains { $0.contains(time) } },
      sleep: { [self] in time += $0 },
      now: { [self] in Date(timeIntervalSinceReferenceDate: time) },
      log: { [self] in log.append($0) })
  }
}

@Suite("Moved Space Activator")
struct MovedSpaceActivatorTests {

  @Test("A first attempt that lands within the verify window needs no retry")
  func firstAttemptSucceeds() {
    let world = World()
    world.becomesCurrentAt = 0.2
    let ok = MovedSpaceActivator().run(world.deps())
    #expect(ok)
    #expect(world.activateCalls == 1)
    #expect(world.switchCalls == 0)
  }

  @Test("An already-current Space verifies immediately")
  func alreadyCurrent() {
    let world = World()
    world.current = true
    #expect(MovedSpaceActivator().run(world.deps()))
    #expect(world.switchCalls == 0)
  }

  @Test("A first attempt still running its Mission Control leg at the deadline is not toggled off")
  func pendingMissionControlLegIsNotInterrupted() {
    // MC opens at 0.1s (the fallback's awake), the tile press lands at 1.4s,
    // after the 1s verify window; MC closes and the Space is current at 1.5s.
    let world = World()
    world.missionControl = [0.1...1.5]
    world.becomesCurrentAt = 1.5
    let ok = MovedSpaceActivator().run(world.deps())
    #expect(ok)
    #expect(
      world.switchCalls == 0, "a retry would have sent the awake toggle under the pending press")
    #expect(world.log.contains { $0.contains("Mission Control leg finished") })
  }

  @Test("A completed first attempt that fails is retried through the Space switch")
  func retryAfterCompletedFailure() {
    let world = World()
    world.activateThrows = true
    var retried = false
    var deps = world.deps()
    deps.switchSpace = {
      retried = true
      world.becomesCurrentAt = world.time + 0.1
    }
    let ok = MovedSpaceActivator().run(deps)
    #expect(ok)
    #expect(retried)
    #expect(world.log.contains { $0.contains("verified attempt=2") })
  }

  @Test("Both attempts failing reports unverified without a third attempt")
  func bothAttemptsFail() {
    let world = World()
    let ok = MovedSpaceActivator().run(world.deps())
    #expect(!ok)
    #expect(world.activateCalls == 1)
    #expect(world.switchCalls == 1)
  }

  @Test("Mission Control that never goes away stops the retry and reports unverified")
  func missionControlStuckStopsRetry() {
    let world = World()
    world.missionControl = [0.1...100]
    let ok = MovedSpaceActivator().run(world.deps())
    #expect(!ok)
    #expect(world.switchCalls == 0)
    #expect(world.log.contains { $0.contains("not retrying while Mission Control is present") })
  }
}
