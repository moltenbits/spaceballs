import Foundation

/// Waits for a window released on a Mission Control Space tile to arrive in
/// that tile's Space.
///
/// Mission Control commits a tile drop some time after the release: on macOS
/// 27.2 the window server reports the window in the tile's Space about 0.5 s
/// later for a tile on the window's own display and about 0.7 s later for a
/// tile on another display, where the window is first reported in that
/// display's current Space. Closing Mission Control or pressing a tile before
/// then cancels the move — the window stays where it was, or in that current
/// Space — so the session must stay open until the window has arrived, and a
/// window that never arrives is a failed move.
struct MissionControlDropVerifier {
  struct Dependencies {
    /// The Spaces the window server reports the window in.
    var windowSpaceIDs: () -> [UInt64]
    var sleep: (TimeInterval) -> Void
    var now: () -> Date
  }

  enum Outcome: Equatable {
    /// The window is in the tile's Space.
    case arrived
    /// The window was not in the tile's Space by the deadline;
    /// `lastSpaceIDs` is where it was last reported.
    case timedOut(lastSpaceIDs: [UInt64])
  }

  var timeout: TimeInterval = 2.0
  var pollInterval: TimeInterval = 0.02

  func awaitArrival(in targetSpaceID: UInt64, _ deps: Dependencies) -> Outcome {
    let deadline = deps.now().addingTimeInterval(timeout)
    while true {
      let spaceIDs = deps.windowSpaceIDs()
      if spaceIDs.contains(targetSpaceID) { return .arrived }
      let remaining = deadline.timeIntervalSince(deps.now())
      // The tolerance keeps accumulated floating-point error in the caller's
      // clock from adding one more poll past the deadline.
      guard remaining > 1e-9 else { return .timedOut(lastSpaceIDs: spaceIDs) }
      deps.sleep(min(pollInterval, remaining))
    }
  }
}
