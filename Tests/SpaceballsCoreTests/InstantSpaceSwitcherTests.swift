import CoreGraphics
import Foundation
import Testing

@testable import SpaceballsCore

@Suite("DockSwipe Planning")
struct DockSwipePlanningTests {
  @Test("Plans direction and adjacent step count")
  func directionsAndSteps() {
    #expect(
      DockSwipePlanner.plan(currentIndex: 1, targetIndex: 4, spaceCount: 5)
        == .navigate(DockSwipePlan(direction: .right, steps: 3)))
    #expect(
      DockSwipePlanner.plan(currentIndex: 4, targetIndex: 1, spaceCount: 5)
        == .navigate(DockSwipePlan(direction: .left, steps: 3)))
    #expect(
      DockSwipePlanner.plan(currentIndex: 2, targetIndex: 2, spaceCount: 5)
        == .alreadyThere)
  }

  @Test("Rejects invalid indices and empty layouts")
  func invalidIndices() {
    #expect(DockSwipePlanner.plan(currentIndex: -1, targetIndex: 0, spaceCount: 3) == .invalid)
    #expect(DockSwipePlanner.plan(currentIndex: 0, targetIndex: 3, spaceCount: 3) == .invalid)
    #expect(DockSwipePlanner.plan(currentIndex: 0, targetIndex: 0, spaceCount: 0) == .invalid)
  }
}

@Suite("DockSwipe Event Construction")
struct DockSwipeEventConstructionTests {
  @Test("Legacy sequence posts Dock-control then envelope for Began and Ended")
  func legacySequence() throws {
    let events = try #require(
      DockSwipeEventFactory.makeLegacyEvents(direction: .right, velocity: 400))

    #expect(events.count == 4)
    #expect(eventTypes(events) == [30, 29, 30, 29])
    #expect(events[0].getIntegerValueField(DockSwipeEventField.phase) == 1)
    #expect(events[2].getIntegerValueField(DockSwipeEventField.phase) == 4)
    #expect(DockSwipeEventFactory.legacyFlagDirection(for: .right) == 1)
    #expect(events[2].getDoubleValueField(DockSwipeEventField.progress) == 2)
    #expect(events[2].getDoubleValueField(DockSwipeEventField.velocityX) == 400)
    #expect(events[2].getDoubleValueField(DockSwipeEventField.velocityY) == 0)
    #expect(events[2].getDoubleValueField(DockSwipeEventField.nonzeroGuard) != 0)
  }

  @Test("Legacy left switch reverses direction, progress, and velocity")
  func legacyLeftDirection() throws {
    let events = try #require(
      DockSwipeEventFactory.makeLegacyEvents(direction: .left, velocity: 800))
    let ended = events[2]

    #expect(DockSwipeEventFactory.legacyFlagDirection(for: .left) == 0)
    #expect(ended.getDoubleValueField(DockSwipeEventField.progress) == -2)
    #expect(ended.getDoubleValueField(DockSwipeEventField.velocityX) == -800)
  }

  @Test("Augmented sequence has all three phases and required validation fields")
  func augmentedSequence() throws {
    let events = try #require(
      DockSwipeEventFactory.makeAugmentedEvents(
        direction: .right, velocity: 400, privateTimestamp: 123_456))

    #expect(events.count == 6)
    #expect(eventTypes(events) == [30, 29, 30, 29, 30, 29])
    #expect(
      [events[0], events[2], events[4]].map {
        $0.getIntegerValueField(DockSwipeEventField.phase)
      } == [1, 2, 4])

    for dockEvent in [events[0], events[2], events[4]] {
      let phase = dockEvent.getIntegerValueField(DockSwipeEventField.phase)
      #expect(dockEvent.getIntegerValueField(DockSwipeEventField.phaseMirror) == phase)
      #expect(dockEvent.getDoubleValueField(DockSwipeEventField.flavor) == 3)
      #expect(dockEvent.getDoubleValueField(DockSwipeEventField.privateTimestamp) == 123_456)
      #expect(dockEvent.getDoubleValueField(DockSwipeEventField.positionX) != 0)
    }
    #expect(events[4].getDoubleValueField(DockSwipeEventField.velocityX) == 9_999)
  }

  @Test("IOHID payload has packed little-endian gesture and velocity records")
  func iohidPayloadLayout() throws {
    let event = try #require(CGEvent(source: nil))
    event.timestamp = 42
    event.setIntegerValueField(DockSwipeEventField.eventType, value: 30)
    event.setIntegerValueField(DockSwipeEventField.hidType, value: 23)
    event.setIntegerValueField(DockSwipeEventField.phase, value: 4)
    event.setIntegerValueField(DockSwipeEventField.motion, value: 1)
    event.setDoubleValueField(DockSwipeEventField.progress, value: -1)
    event.setDoubleValueField(DockSwipeEventField.positionX, value: 0.5)
    event.setDoubleValueField(DockSwipeEventField.velocityX, value: -9_999)

    let payload = DockSwipeEventFactory.makeIOHIDPayload(from: event)

    #expect(payload.count == 96)
    #expect(payload.readLittleEndian(at: 0, as: UInt64.self) == 42)
    #expect(payload.readLittleEndian(at: 24, as: UInt32.self) == 2)
    #expect(payload.readLittleEndian(at: 28, as: UInt32.self) == 40)
    #expect(payload.readLittleEndian(at: 32, as: UInt32.self) == 23)
    #expect(payload.readLittleEndian(at: 36, as: UInt32.self) == UInt32(4 << 24))
    #expect(payload.readLittleEndian(at: 44, as: Int32.self) == 32_768)
    #expect(payload.readLittleEndian(at: 60, as: UInt16.self) == 1)
    #expect(payload.readLittleEndian(at: 62, as: UInt16.self) == 3)
    #expect(payload.readLittleEndian(at: 64, as: Int32.self) == -65_536)
    #expect(payload.readLittleEndian(at: 68, as: UInt32.self) == 28)
    #expect(payload.readLittleEndian(at: 72, as: UInt32.self) == 9)
    #expect(payload.readLittleEndian(at: 84, as: Int32.self) == -655_294_464)
  }

  @Test("Serialized augmentation validates its header and appends field 4205")
  func serializedAugmentation() throws {
    let payload = Data([1, 2, 3])
    #expect(
      DockSwipeEventFactory.appendingIOHIDPayload(
        payload, toSerializedEvent: Data([0, 0, 0, 3])) == nil)

    let augmented = try #require(
      DockSwipeEventFactory.appendingIOHIDPayload(
        payload, toSerializedEvent: Data([0, 0, 0, 2, 99])))
    #expect(Array(augmented.suffix(7)) == [0, 3, 0x10, 0x6D, 1, 2, 3])
  }

  private func eventTypes(_ events: [CGEvent]) -> [Int64] {
    events.map { $0.getIntegerValueField(DockSwipeEventField.eventType) }
  }
}

@Suite("DockSwipe Routing")
struct DockSwipeRoutingTests {
  @Test("Cursor already on the target display posts without warping")
  func directRouting() {
    let recorder = DockSwipeSystemRecorder(cursorDisplayUUID: "display-b")
    let switcher = DockSwipeSpaceSwitcher(dependencies: recorder.dependencies)

    #expect(switcher.switchToSpace(target(), among: spaces()) == .switched)
    #expect(recorder.postedEventCounts == [4])
    #expect(recorder.warpedPoints.isEmpty)
    #expect(recorder.scheduledDelays.isEmpty)
  }

  @Test("macOS 27 routing posts the augmented sequence")
  func augmentedRouting() {
    let recorder = DockSwipeSystemRecorder(cursorDisplayUUID: "display-b")
    recorder.operatingSystemMajorVersion = 27
    let switcher = DockSwipeSpaceSwitcher(dependencies: recorder.dependencies)

    #expect(switcher.switchToSpace(target(), among: spaces()) == .switched)
    #expect(recorder.postedEventCounts == [6])
  }

  @Test("Cross-display routing temporarily warps and restores an untouched cursor")
  func temporaryWarpAndRestore() throws {
    let recorder = DockSwipeSystemRecorder(cursorDisplayUUID: "display-a")
    let switcher = DockSwipeSpaceSwitcher(dependencies: recorder.dependencies)

    #expect(switcher.switchToSpace(target(), among: spaces()) == .switched)
    #expect(recorder.warpedPoints == [CGPoint(x: 150, y: 250)])
    #expect(recorder.scheduledDelays == [0.15])

    let scheduledWork = try #require(recorder.scheduledWork)
    scheduledWork()
    #expect(recorder.warpedPoints == [CGPoint(x: 150, y: 250), CGPoint(x: 10, y: 20)])
  }

  @Test("Cross-display routing does not restore after the user moves")
  func userMovementCancelsRestore() throws {
    let recorder = DockSwipeSystemRecorder(cursorDisplayUUID: "display-a")
    let switcher = DockSwipeSpaceSwitcher(dependencies: recorder.dependencies)

    #expect(switcher.switchToSpace(target(), among: spaces()) == .switched)
    recorder.cursorPosition = CGPoint(x: 500, y: 500)
    let scheduledWork = try #require(recorder.scheduledWork)
    scheduledWork()

    #expect(recorder.warpedPoints == [CGPoint(x: 150, y: 250)])
  }

  @Test("Untrusted, Mission Control, and unresolved displays fail closed")
  func failClosed() {
    let untrusted = DockSwipeSystemRecorder(cursorDisplayUUID: "display-b")
    untrusted.accessibilityTrusted = false
    #expect(
      DockSwipeSpaceSwitcher(dependencies: untrusted.dependencies)
        .switchToSpace(target(), among: spaces()) == .declined)

    let missionControl = DockSwipeSystemRecorder(cursorDisplayUUID: "display-b")
    missionControl.missionControlActive = true
    #expect(
      DockSwipeSpaceSwitcher(dependencies: missionControl.dependencies)
        .switchToSpace(target(), among: spaces()) == .declined)

    let unresolved = DockSwipeSystemRecorder(cursorDisplayUUID: nil)
    #expect(
      DockSwipeSpaceSwitcher(dependencies: unresolved.dependencies)
        .switchToSpace(target(), among: spaces()) == .declined)
  }

  @Test("Already-current requests are a no-op without system access")
  func alreadyCurrent() {
    let recorder = DockSwipeSystemRecorder(cursorDisplayUUID: nil)
    recorder.accessibilityTrusted = false
    recorder.missionControlActive = true
    let currentTarget = SpaceInfo(
      id: 11, uuid: "space-b-2", type: .desktop,
      displayUUID: "display-b", isCurrent: true)

    #expect(
      DockSwipeSpaceSwitcher(dependencies: recorder.dependencies)
        .switchToSpace(currentTarget, among: [currentTarget]) == .alreadyThere)
    #expect(recorder.postedEventCounts.isEmpty)
    #expect(recorder.warpedPoints.isEmpty)
  }

  @Test("Mission Control detector recognizes Dock layer-18 overlays")
  func missionControlDetection() {
    #expect(
      DockSwipeMissionControlDetector.isActive(in: [
        [kCGWindowOwnerName as String: "Dock", kCGWindowLayer as String: 18]
      ]))
    #expect(
      !DockSwipeMissionControlDetector.isActive(in: [
        [kCGWindowOwnerName as String: "Dock", kCGWindowLayer as String: 20],
        [kCGWindowOwnerName as String: "Other", kCGWindowLayer as String: 18],
      ]))
  }

  @Test("Cursor restoration runs while the CLI main queue is blocked")
  func cursorRestorationDoesNotDependOnMainQueue() async {
    let restoredWhileBlocked: Bool = await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        let restored = DispatchSemaphore(value: 0)
        DockSwipeCursorRestoreScheduler.schedule(after: 0.01) {
          restored.signal()
        }
        continuation.resume(
          returning: restored.wait(timeout: .now() + 0.25) == .success)
      }
    }

    #expect(restoredWhileBlocked)
  }

  private func target() -> SpaceInfo {
    SpaceInfo(
      id: 11, uuid: "space-b-2", type: .desktop,
      displayUUID: "display-b", isCurrent: false)
  }

  private func spaces() -> [SpaceInfo] {
    [
      SpaceInfo(
        id: 1, uuid: "space-a-1", type: .desktop,
        displayUUID: "display-a", isCurrent: true),
      SpaceInfo(
        id: 10, uuid: "space-b-1", type: .desktop,
        displayUUID: "display-b", isCurrent: true),
      target(),
    ]
  }
}

private final class DockSwipeSystemRecorder {
  var operatingSystemMajorVersion = 26
  var accessibilityTrusted = true
  var missionControlActive = false
  var cursorDisplayUUID: String?
  var cursorPosition = CGPoint(x: 10, y: 20)
  var warpedPoints: [CGPoint] = []
  var postedEventCounts: [Int] = []
  var scheduledDelays: [TimeInterval] = []
  var scheduledWork: (() -> Void)?

  init(cursorDisplayUUID: String?) {
    self.cursorDisplayUUID = cursorDisplayUUID
  }

  var dependencies: DockSwipeSystemDependencies {
    DockSwipeSystemDependencies(
      operatingSystemMajorVersion: { self.operatingSystemMajorVersion },
      accessibilityTrusted: { self.accessibilityTrusted },
      missionControlActive: { self.missionControlActive },
      cursorDisplayUUID: { self.cursorDisplayUUID },
      displayIDForUUID: { $0 == "display-b" ? 7 : nil },
      displayBounds: { _ in CGRect(x: 100, y: 200, width: 100, height: 100) },
      cursorPosition: { self.cursorPosition },
      warpCursor: {
        self.warpedPoints.append($0)
        self.cursorPosition = $0
      },
      schedule: { delay, work in
        self.scheduledDelays.append(delay)
        self.scheduledWork = work
      },
      postEvents: { self.postedEventCounts.append($0.count) })
  }
}

extension Data {
  fileprivate func readLittleEndian<T: FixedWidthInteger>(at offset: Int, as type: T.Type) -> T {
    var value: T = 0
    _ = Swift.withUnsafeMutableBytes(of: &value) { buffer in
      copyBytes(to: buffer, from: offset..<(offset + MemoryLayout<T>.size))
    }
    return T(littleEndian: value)
  }
}
