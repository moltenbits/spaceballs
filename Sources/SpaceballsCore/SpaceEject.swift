import CoreGraphics
import Foundation

/// User-tunable pauses used while driving Mission Control (space moves,
/// eject, restore). The defaults sit near the practical floor — lower is
/// faster, too low and drags start to misfire.
public struct SpaceMoveTiming: Equatable {
  /// Pause after a verified display switch (Mission Control fully
  /// dismissed) before the next Mission Control round.
  public var preSwitchSettle: TimeInterval
  /// Pause after dropping a tile, before the next grab or dismissal.
  public var dropSettle: TimeInterval
  /// Pause between consecutive tile drags in one batch session.
  public var interDragPause: TimeInterval

  public init(
    preSwitchSettle: TimeInterval = 0.25,
    dropSettle: TimeInterval = 0.2,
    interDragPause: TimeInterval = 0.15
  ) {
    self.preSwitchSettle = preSwitchSettle
    self.dropSettle = dropSettle
    self.interDragPause = interDragPause
  }
}

/// One tile drag within a Mission Control batch session.
public struct SpaceTileDrag {
  public let sourceSpaceIndex: Int
  public let sourceScreenNumber: CGDirectDisplayID
  public let targetScreenNumber: CGDirectDisplayID

  public init(
    sourceSpaceIndex: Int, sourceScreenNumber: CGDirectDisplayID,
    targetScreenNumber: CGDirectDisplayID
  ) {
    self.sourceSpaceIndex = sourceSpaceIndex
    self.sourceScreenNumber = sourceScreenNumber
    self.targetScreenNumber = targetScreenNumber
  }
}

public struct EjectSummary {
  /// UUIDs of spaces verified to have landed on the built-in display.
  public let ejected: [String]
  /// Space IDs whose planned move did not verifiably complete.
  public let failed: [UInt64]
}

public struct SpaceRestoreSummary {
  /// UUIDs of spaces moved back to their recorded display just now.
  public let restored: [String]
  /// UUIDs still pending because their display remains disconnected.
  public let waiting: [String]
}

// MARK: - Eject / Restore

extension SpaceManager {

  /// Moves every non-Default desktop space off every external display onto
  /// the built-in display in one Mission Control session, recording each
  /// space's origin in `ejectStore` for later restore. A display whose
  /// spaces would all leave gets a Default Space created and named first.
  /// No space is activated afterwards — the built-in display's active space
  /// stays wherever it was.
  public func ejectSpaces(
    spaceNameStore: SpaceNameStoring, ejectStore: EjectRecordStoring
  ) throws -> EjectSummary {
    guard let builtinUUID = Self.builtinDisplayUUID() else {
      throw SpaceMoveError.displayNotResolvable(displayUUID: "built-in")
    }
    guard Self.ensureAccessibilityTrusted() else {
      throw SpaceMoveError.accessibilityNotTrusted
    }
    let token = Diagnostics.beginTiming("eject", "ejectSpaces")

    var plan = EjectPlanner.plan(
      spaces: getAllSpaces(), targetDisplayUUID: builtinUUID,
      names: spaceNameStore.allCustomNames())

    // Create + name a Default Space where one is missing, then re-plan
    // against the fresh space list (creation appends, so existing tile
    // indices survive — but re-planning keeps one source of truth).
    if !plan.displaysNeedingDefault.isEmpty {
      for displayUUID in plan.displaysNeedingDefault {
        try createDefaultSpace(on: displayUUID, spaceNameStore: spaceNameStore)
      }
      plan = EjectPlanner.plan(
        spaces: getAllSpaces(), targetDisplayUUID: builtinUUID,
        names: spaceNameStore.allCustomNames())
      guard plan.displaysNeedingDefault.isEmpty else {
        Diagnostics.endTiming(token, outcome: "default-creation-failed")
        throw SpaceMoveError.spaceCreationFailed(
          displayUUID: plan.displaysNeedingDefault[0])
      }
    }

    // Capture each ejecting display's active space BEFORE the pre-switches
    // park it on its Default Space — restore reactivates it at the end.
    for (displayUUID, spaceUUID) in plan.activeSpaceByDisplay {
      ejectStore.recordActiveSpace(displayUUID: displayUUID, spaceUUID: spaceUUID)
    }

    let verified = executePlannedMoves(preSwitches: plan.preSwitches, moves: plan.moves)
    for move in verified {
      ejectStore.recordEjection(
        spaceUUID: move.spaceUUID, originalDisplayUUID: move.sourceDisplayUUID)
    }
    let verifiedIDs = Set(verified.map(\.spaceID))
    let summary = EjectSummary(
      ejected: verified.map(\.spaceUUID),
      failed: plan.moves.map(\.spaceID).filter { !verifiedIDs.contains($0) })
    Diagnostics.endTiming(
      token, outcome: "ejected=\(summary.ejected.count) failed=\(summary.failed.count)")
    return summary
  }

  /// Moves previously ejected spaces back to their recorded displays (those
  /// currently connected) in one Mission Control session, clearing records
  /// as they complete. Records whose display is still disconnected are kept;
  /// records whose space no longer exists are dropped. No space is activated.
  ///
  /// `onlyArmed` restricts the run to records whose display has actually been
  /// observed absent since the eject — the auto-restore gate. Manual restores
  /// (CLI, Cmd+Shift+E) pass false and move everything movable.
  public func restoreEjectedSpaces(
    ejectStore: EjectRecordStoring, onlyArmed: Bool = false
  ) throws -> SpaceRestoreSummary {
    var pending = ejectStore.pendingEjections()
    if onlyArmed {
      let armed = ejectStore.armedEjections()
      pending = pending.filter { armed.contains($0.key) }
    }
    guard !pending.isEmpty else { return SpaceRestoreSummary(restored: [], waiting: []) }
    guard Self.ensureAccessibilityTrusted() else {
      throw SpaceMoveError.accessibilityNotTrusted
    }
    let token = Diagnostics.beginTiming("eject", "restoreEjectedSpaces")

    let plan = RestorePlanner.plan(spaces: getAllSpaces(), pending: pending)
    for spaceUUID in plan.stale + plan.completed {
      ejectStore.clearEjection(spaceUUID: spaceUUID)
    }

    let restored = executePlannedMoves(preSwitches: plan.preSwitches, moves: plan.moves)
    for move in restored {
      ejectStore.clearEjection(spaceUUID: move.spaceUUID)
    }

    reactivateRecordedActiveSpaces(ejectStore: ejectStore)

    let summary = SpaceRestoreSummary(restored: restored.map(\.spaceUUID), waiting: plan.waiting)
    Diagnostics.endTiming(
      token, outcome: "restored=\(summary.restored.count) waiting=\(summary.waiting.count)")
    return summary
  }

  /// Pre-switches displays off the spaces about to move, runs the batch of
  /// tile drags in one Mission Control session, and CGS-verifies each drop.
  /// Returns the moves whose spaces verifiably landed on their targets.
  private func executePlannedMoves(
    preSwitches: [EjectPlanner.PreSwitch], moves: [EjectPlanner.Move]
  ) -> [EjectPlanner.Move] {
    guard !moves.isEmpty else { return [] }

    // MC refuses to drag a display's current space, so FIRST park each
    // affected display on a staying space. The instant path avoids Mission
    // Control; its fallback presses a tile after sending an awake notification
    // that behaves as a TOGGLE. Run switches strictly one at a time, verify
    // each via CGS, and wait out any fallback Mission Control appearance
    // before the next switch or drag session.
    for preSwitch in preSwitches {
      // Use the same activation path as the switcher panel. It prefers a
      // verified DockSwipe and retains the existing native/MC fallbacks.
      do {
        try activateSpace(id: preSwitch.toSpaceID)
      } catch {
        Diagnostics.log(
          "eject", "pre-switch activation of \(preSwitch.toSpaceID) failed: \(error)")
      }
      let switched = poll(interval: 0.05, timeout: 3.0) {
        self.getAllSpaces().first(where: {
          $0.displayUUID == preSwitch.displayUUID && $0.isCurrent
        })?.id == preSwitch.toSpaceID
      }
      if !switched {
        Diagnostics.log(
          "eject", "pre-switch of \(preSwitch.displayUUID) not confirmed — continuing")
      }
      // The dismissal wait is the hard signal that the next awake will OPEN
      // rather than toggle-close; the short tail only bridges any lag
      // between the AX group vanishing and the Dock's internal state flip.
      Self.awaitMissionControlDismissed(timeout: 2.0)
      Thread.sleep(forTimeInterval: moveTiming.preSwitchSettle)
    }

    var drags: [SpaceTileDrag] = []
    var dragMoves: [EjectPlanner.Move] = []
    for move in moves {
      guard let sourceScreen = Self.displayIDForUUID(move.sourceDisplayUUID),
        let targetScreen = Self.displayIDForUUID(move.targetDisplayUUID)
      else { continue }
      drags.append(
        SpaceTileDrag(
          sourceSpaceIndex: move.sourceIndex,
          sourceScreenNumber: sourceScreen, targetScreenNumber: targetScreen))
      dragMoves.append(move)
    }

    // Each completed drop shifts the tiles remaining in its source bar, so
    // every drag re-derives its tile index from a fresh CGS read. When CGS
    // reflects drops live, that's the true post-shift position; when it
    // lags, the read returns the planned index — which the DESCENDING
    // per-display order keeps correct regardless.
    let attemptedIndices = moveSpacesInMCBatch(drags) { dragIndex in
      let move = dragMoves[dragIndex]
      let spaces = self.getAllSpaces()
      guard
        let space = spaces.first(where: { $0.id == move.spaceID }),
        space.displayUUID == move.sourceDisplayUUID
      else { return nil }  // already landed elsewhere, or gone — skip
      return
        spaces
        .filter { $0.type == .desktop && $0.displayUUID == move.sourceDisplayUUID }
        .firstIndex(where: { $0.id == move.spaceID })
    }
    let attempted = attemptedIndices.map { dragMoves[$0] }

    // The drops animate before CGS reflects the new topology — poll until
    // every attempted move is visible (or the scaled timeout elapses), then
    // report everything that actually landed, attempted or not.
    _ = poll(timeout: 2.0 + 0.5 * Double(attempted.count)) {
      let spaces = self.getAllSpaces()
      return attempted.allSatisfy { move in
        spaces.first(where: { $0.id == move.spaceID })?.displayUUID == move.targetDisplayUUID
      }
    }
    let finalSpaces = getAllSpaces()
    return moves.filter { move in
      finalSpaces.first(where: { $0.id == move.spaceID })?.displayUUID
        == move.targetDisplayUUID
    }
  }

  /// Reactivates the space that was active on each display at eject time,
  /// once that space is back home. Reactivations run strictly one at a time;
  /// instant switches have nothing to dismiss, while the fallback's Mission
  /// Control appearance is fully waited out before continuing.
  /// Records for spaces that no longer exist are dropped; records whose
  /// space or display isn't back yet are kept for a later restore.
  private func reactivateRecordedActiveSpaces(ejectStore: EjectRecordStoring) {
    let records = ejectStore.activeSpaceRecords()
    guard !records.isEmpty else { return }
    let spaces = getAllSpaces()
    let connectedDisplays = Set(spaces.map(\.displayUUID))

    for (displayUUID, spaceUUID) in records {
      guard let space = spaces.first(where: { $0.uuid == spaceUUID }) else {
        ejectStore.clearActiveSpace(displayUUID: displayUUID)
        continue
      }
      guard connectedDisplays.contains(displayUUID),
        space.displayUUID == displayUUID
      else { continue }

      if !space.isCurrent {
        do {
          try activateSpace(id: space.id)
        } catch {
          Diagnostics.log("eject", "reactivating \(spaceUUID) on \(displayUUID) failed: \(error)")
        }
        Self.awaitMissionControlDismissed(timeout: 2.0)
        Thread.sleep(forTimeInterval: moveTiming.preSwitchSettle)
      }
      ejectStore.clearActiveSpace(displayUUID: displayUUID)
    }
  }

  /// Synchronously creates one space on `displayUUID` and names it
  /// "Default Space" (identified by UUID diff, matching the sibling-creation
  /// flow in moveSpaceToDisplay).
  private func createDefaultSpace(
    on displayUUID: String, spaceNameStore: SpaceNameStoring
  ) throws {
    guard let screen = Self.displayIDForUUID(displayUUID) else {
      throw SpaceMoveError.displayNotResolvable(displayUUID: displayUUID)
    }
    let before = Set(getAllSpaces().map(\.uuid))

    let semaphore = DispatchSemaphore(value: 0)
    var createResult: Result<Int, SpaceCreateError> = .failure(.missionControlNotFound)
    createSpace(count: 1, screenNumber: screen) { result in
      createResult = result
      semaphore.signal()
    }
    semaphore.wait()

    let created =
      (try? createResult.get()) == 1
      && poll(timeout: 3.0) {
        !Self.newlyCreatedSpaces(before: before, after: self.getAllSpaces()).isEmpty
      }
    guard created else {
      throw SpaceMoveError.spaceCreationFailed(displayUUID: displayUUID)
    }
    for space in Self.newlyCreatedSpaces(before: before, after: getAllSpaces()) {
      spaceNameStore.setCustomName(SpaceNameStore.defaultSpaceName, forSpaceUUID: space.uuid)
    }
  }
}
