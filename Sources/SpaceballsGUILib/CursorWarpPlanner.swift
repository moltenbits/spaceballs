import Foundation

/// Decides whether activating something should warp the cursor to the target
/// display (issue #17). Pure — callers supply the current cursor display, the
/// activation target's display, and the live display count.
public enum CursorWarpPlanner {
  /// The cursor is only "lost" when focus lands on a display it isn't on:
  /// same-display activations (including cross-Space ones) never warp, nor do
  /// single-display setups or unknown displays.
  public static func shouldWarp(
    enabled: Bool, displayCount: Int,
    cursorDisplayUUID: String?, targetDisplayUUID: String?
  ) -> Bool {
    guard enabled, displayCount > 1,
      let cursorDisplayUUID, let targetDisplayUUID
    else { return false }
    return cursorDisplayUUID != targetDisplayUUID
  }
}
