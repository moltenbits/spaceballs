import Foundation
import Testing

@testable import SpaceballsCore

/// Mission Control commits a window dropped on a Space tile some time after
/// the release, and closing Mission Control before then cancels the move. The
/// timings below are the ones measured on macOS 27.2: about 0.5 s for a tile
/// on the window's own display, about 0.7 s for a tile on another display,
/// where the window is first reported in that display's current Space.
@Suite("Mission Control Drop Verifier")
struct MissionControlDropVerifierTests {
  /// A clock that only advances when the verifier sleeps, and the Spaces the
  /// window server reports the window in from each moment after the release.
  final class Script {
    var elapsed: TimeInterval = 0
    let reports: [(from: TimeInterval, spaceIDs: [UInt64])]

    init(_ reports: [(from: TimeInterval, spaceIDs: [UInt64])]) { self.reports = reports }

    var dependencies: MissionControlDropVerifier.Dependencies {
      .init(
        windowSpaceIDs: { [self] in reports.last { $0.from <= elapsed }?.spaceIDs ?? [] },
        sleep: { [self] in elapsed += $0 },
        now: { [self] in Date(timeIntervalSinceReferenceDate: elapsed) })
    }
  }

  @Test("A drop on a tile of the window's own display is awaited until the window arrives")
  func sameDisplayDrop() {
    let script = Script([(0, [46]), (0.51, [8])])

    let outcome = MissionControlDropVerifier().awaitArrival(in: 8, script.dependencies)

    #expect(outcome == .arrived)
    #expect(script.elapsed >= 0.51)
    #expect(script.elapsed < 0.6)
  }

  @Test("The other display's current Space is not mistaken for the tile's Space")
  func crossDisplayDropPassesThroughCurrentSpace() {
    let script = Script([(0, [46]), (0.025, [31]), (0.69, [3])])

    let outcome = MissionControlDropVerifier().awaitArrival(in: 3, script.dependencies)

    #expect(outcome == .arrived)
    #expect(script.elapsed >= 0.69)
  }

  @Test("A window already in the tile's Space is reported at once")
  func alreadyArrived() {
    let script = Script([(0, [8])])

    let outcome = MissionControlDropVerifier().awaitArrival(in: 8, script.dependencies)

    #expect(outcome == .arrived)
    #expect(script.elapsed == 0)
  }

  @Test("A window shown on several Spaces has arrived once the tile's Space is among them")
  func stickyWindow() {
    let script = Script([(0, [46]), (0.2, [46, 8])])

    #expect(MissionControlDropVerifier().awaitArrival(in: 8, script.dependencies) == .arrived)
  }

  @Test("A refused drop times out, reporting where the window was left")
  func refusedDrop() {
    let script = Script([(0, [46]), (0.025, [31])])
    let verifier = MissionControlDropVerifier(timeout: 2.0)

    let outcome = verifier.awaitArrival(in: 3, script.dependencies)

    #expect(outcome == .timedOut(lastSpaceIDs: [31]))
    #expect(script.elapsed >= 2.0)
    #expect(script.elapsed < 2.1)
  }

  @Test("A window that arrives exactly at the deadline still counts as arrived")
  func arrivesAtDeadline() {
    let script = Script([(0, [46]), (1.0, [8])])
    let verifier = MissionControlDropVerifier(timeout: 1.0, pollInterval: 0.25)

    #expect(verifier.awaitArrival(in: 8, script.dependencies) == .arrived)
  }

  @Test("A window the window server no longer reports times out with no Spaces")
  func windowGone() {
    let script = Script([(0, [46]), (0.1, [])])
    let verifier = MissionControlDropVerifier(timeout: 0.5)

    #expect(verifier.awaitArrival(in: 8, script.dependencies) == .timedOut(lastSpaceIDs: []))
  }
}
