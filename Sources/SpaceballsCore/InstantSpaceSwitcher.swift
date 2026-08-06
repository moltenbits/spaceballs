import ApplicationServices
import CoreGraphics
import Foundation

// Synthetic DockSwipe switching is based on the independently published MIT
// implementation in jurplel/InstantSpaceSwitcher and the macOS 27 IOHID
// augmentation from the 0BSD joshuarli/iss project. All values below are
// undocumented WindowServer/Dock implementation details and must fail closed.

enum DockSwipeDirection: Equatable {
  case left
  case right
}

struct DockSwipePlan: Equatable {
  let direction: DockSwipeDirection
  let steps: Int
}

enum DockSwipeNavigationDecision: Equatable {
  case navigate(DockSwipePlan)
  case alreadyThere
  case invalid
}

enum DockSwipePlanner {
  static func plan(
    currentIndex: Int, targetIndex: Int, spaceCount: Int
  ) -> DockSwipeNavigationDecision {
    guard spaceCount > 0,
      currentIndex >= 0, currentIndex < spaceCount,
      targetIndex >= 0, targetIndex < spaceCount
    else { return .invalid }
    guard currentIndex != targetIndex else { return .alreadyThere }
    return .navigate(
      DockSwipePlan(
        direction: targetIndex > currentIndex ? .right : .left,
        steps: abs(targetIndex - currentIndex)))
  }
}

enum InstantSpaceSwitchResult: Equatable {
  case switched
  case alreadyThere
  case declined
}

protocol InstantSpaceSwitching: AnyObject {
  func switchToSpace(_ target: SpaceInfo, among spaces: [SpaceInfo])
    -> InstantSpaceSwitchResult
}

enum DockSwipeEventField {
  static let eventType = CGEventField(rawValue: 55)!
  static let hidType = CGEventField(rawValue: 110)!
  static let swipeMask = CGEventField(rawValue: 115)!
  static let scrollY = CGEventField(rawValue: 119)!
  static let motion = CGEventField(rawValue: 123)!
  static let progress = CGEventField(rawValue: 124)!
  static let positionX = CGEventField(rawValue: 125)!
  static let positionY = CGEventField(rawValue: 126)!
  static let velocityX = CGEventField(rawValue: 129)!
  static let velocityY = CGEventField(rawValue: 130)!
  static let phase = CGEventField(rawValue: 132)!
  static let phaseMirror = CGEventField(rawValue: 134)!
  static let direction = CGEventField(rawValue: 135)!
  static let flavor = CGEventField(rawValue: 138)!
  static let nonzeroGuard = CGEventField(rawValue: 139)!
  static let privateTimestamp = CGEventField(rawValue: 169)!
}

enum DockSwipeEventFactory {
  private static let dockControlType: Int64 = 30
  private static let gestureEnvelopeType: Int64 = 29
  private static let dockSwipeHIDType: Int64 = 23
  private static let horizontalMotion: Int64 = 1
  private static let beganPhase: Int64 = 1
  private static let changedPhase: Int64 = 2
  private static let endedPhase: Int64 = 4
  private static let instantProgress = 2.0
  private static let augmentedInstantVelocity = 9_999.0
  private static let iohidPayloadField: UInt16 = 4_205
  private static let fluidGestureDataSize: UInt32 = 40
  private static let velocityDataSize: UInt32 = 28
  private static let fluidGestureType: UInt32 = 23
  private static let velocityType: UInt32 = 9
  private static let dockPrimaryFlavor: UInt16 = 3

  static func makeLegacyEvents(
    direction: DockSwipeDirection, velocity: Double
  ) -> [CGEvent]? {
    var events: [CGEvent] = []
    for phase in [beganPhase, endedPhase] {
      guard let pair = makeLegacyPair(direction: direction, phase: phase, velocity: velocity)
      else { return nil }
      events.append(contentsOf: pair)
    }
    return events
  }

  static func legacyFlagDirection(for direction: DockSwipeDirection) -> Int64 {
    direction == .right ? 1 : 0
  }

  static func makeAugmentedEvents(
    direction: DockSwipeDirection,
    velocity: Double,
    privateTimestamp: Double = Double(mach_absolute_time())
  ) -> [CGEvent]? {
    let magnitude = velocity >= 400 ? augmentedInstantVelocity : velocity
    var events: [CGEvent] = []

    for phase in [beganPhase, changedPhase, endedPhase] {
      guard
        let dockEvent = makeAugmentedDockEvent(
          direction: direction,
          phase: phase,
          velocity: magnitude,
          privateTimestamp: privateTimestamp),
        let augmentedDockEvent = augmentDockEvent(dockEvent),
        let gestureEvent = CGEvent(source: nil)
      else { return nil }

      gestureEvent.setIntegerValueField(
        DockSwipeEventField.eventType, value: gestureEnvelopeType)
      events.append(augmentedDockEvent)
      events.append(gestureEvent)
    }
    return events
  }

  private static func makeLegacyPair(
    direction: DockSwipeDirection, phase: Int64, velocity: Double
  ) -> [CGEvent]? {
    guard let dockEvent = CGEvent(source: nil), let gestureEvent = CGEvent(source: nil)
    else { return nil }

    gestureEvent.setIntegerValueField(
      DockSwipeEventField.eventType, value: gestureEnvelopeType)

    dockEvent.setIntegerValueField(DockSwipeEventField.eventType, value: dockControlType)
    dockEvent.setIntegerValueField(DockSwipeEventField.hidType, value: dockSwipeHIDType)
    dockEvent.setIntegerValueField(DockSwipeEventField.phase, value: phase)
    dockEvent.setIntegerValueField(
      DockSwipeEventField.direction, value: legacyFlagDirection(for: direction))
    dockEvent.setIntegerValueField(DockSwipeEventField.motion, value: horizontalMotion)
    dockEvent.setDoubleValueField(DockSwipeEventField.scrollY, value: 0)
    dockEvent.setDoubleValueField(
      DockSwipeEventField.nonzeroGuard,
      value: Double(Float.leastNonzeroMagnitude))

    if phase == endedPhase {
      let sign = direction == .right ? 1.0 : -1.0
      dockEvent.setDoubleValueField(
        DockSwipeEventField.progress, value: sign * instantProgress)
      dockEvent.setDoubleValueField(DockSwipeEventField.velocityX, value: sign * velocity)
      dockEvent.setDoubleValueField(DockSwipeEventField.velocityY, value: 0)
    }
    return [dockEvent, gestureEvent]
  }

  private static func makeAugmentedDockEvent(
    direction: DockSwipeDirection,
    phase: Int64,
    velocity: Double,
    privateTimestamp: Double
  ) -> CGEvent? {
    guard let event = CGEvent(source: nil) else { return nil }
    // Synthetic macOS 27 events use the same posting-side sign convention as
    // the legacy path: positive moves right and negative moves left. This is
    // distinct from the sign reported by real trackpad gestures.
    let sign = direction == .right ? 1.0 : -1.0

    event.setIntegerValueField(DockSwipeEventField.eventType, value: dockControlType)
    event.setIntegerValueField(DockSwipeEventField.hidType, value: dockSwipeHIDType)
    event.setIntegerValueField(DockSwipeEventField.phase, value: phase)
    event.setIntegerValueField(DockSwipeEventField.phaseMirror, value: phase)
    event.setIntegerValueField(DockSwipeEventField.motion, value: horizontalMotion)
    event.setDoubleValueField(DockSwipeEventField.progress, value: sign)
    event.setDoubleValueField(
      DockSwipeEventField.flavor, value: Double(dockPrimaryFlavor))
    event.setDoubleValueField(
      DockSwipeEventField.privateTimestamp, value: privateTimestamp)
    event.setDoubleValueField(DockSwipeEventField.positionX, value: 0.1)
    if phase == endedPhase {
      event.setDoubleValueField(DockSwipeEventField.velocityX, value: sign * velocity)
    }
    return event
  }

  private static func augmentDockEvent(_ event: CGEvent) -> CGEvent? {
    guard let eventData = event.data else { return nil }
    let serialized = eventData as Data
    let payload = makeIOHIDPayload(from: event)
    guard let augmented = appendingIOHIDPayload(payload, toSerializedEvent: serialized)
    else { return nil }
    return CGEvent(withDataAllocator: kCFAllocatorDefault, data: augmented as CFData)
  }

  static func makeIOHIDPayload(from event: CGEvent) -> Data {
    let phase = event.getIntegerValueField(DockSwipeEventField.phase)
    let motion = event.getIntegerValueField(DockSwipeEventField.motion)
    let progress = event.getDoubleValueField(DockSwipeEventField.progress)
    let positionX = event.getDoubleValueField(DockSwipeEventField.positionX)
    let positionY = event.getDoubleValueField(DockSwipeEventField.positionY)
    let velocityX = event.getDoubleValueField(DockSwipeEventField.velocityX)
    let velocityY = event.getDoubleValueField(DockSwipeEventField.velocityY)
    let swipeMask = event.getIntegerValueField(DockSwipeEventField.swipeMask)
    let includesVelocity = velocityX != 0 || velocityY != 0 || phase == endedPhase

    var payload = Data()
    payload.appendLittleEndian(event.timestamp != 0 ? event.timestamp : mach_absolute_time())
    payload.appendLittleEndian(UInt64(0))
    payload.appendLittleEndian(UInt32(0))
    payload.appendLittleEndian(UInt32(0))
    payload.appendLittleEndian(UInt32(includesVelocity ? 2 : 1))

    payload.appendLittleEndian(fluidGestureDataSize)
    payload.appendLittleEndian(fluidGestureType)
    payload.appendLittleEndian(UInt32((phase & 0xFF) << 24))
    payload.appendLittleEndian(UInt8(0))
    payload.append(contentsOf: [0, 0, 0])
    payload.appendLittleEndian(fixed1616(positionX))
    payload.appendLittleEndian(fixed1616(positionY))
    payload.appendLittleEndian(Int32(0))
    payload.appendLittleEndian(UInt32(truncatingIfNeeded: swipeMask))
    payload.appendLittleEndian(UInt16(truncatingIfNeeded: motion))
    payload.appendLittleEndian(dockPrimaryFlavor)
    payload.appendLittleEndian(fixed1616(progress))

    if includesVelocity {
      payload.appendLittleEndian(velocityDataSize)
      payload.appendLittleEndian(velocityType)
      payload.appendLittleEndian(UInt32(0))
      payload.appendLittleEndian(UInt8(1))
      payload.append(contentsOf: [0, 0, 0])
      payload.appendLittleEndian(fixed1616(velocityX))
      payload.appendLittleEndian(fixed1616(velocityY))
      payload.appendLittleEndian(Int32(0))
    }
    return payload
  }

  static func appendingIOHIDPayload(
    _ payload: Data, toSerializedEvent serialized: Data
  ) -> Data? {
    guard serialized.count >= 4,
      serialized[0] == 0, serialized[1] == 0,
      serialized[2] == 0, serialized[3] == 2,
      payload.count <= Int(UInt16.max)
    else { return nil }

    var result = serialized
    result.append(UInt8(payload.count >> 8))
    result.append(UInt8(payload.count & 0xFF))
    result.append(UInt8(iohidPayloadField >> 8))
    result.append(UInt8(iohidPayloadField & 0xFF))
    result.append(payload)
    return result
  }

  private static func fixed1616(_ value: Double) -> Int32 {
    let fixed = Int32(truncatingIfNeeded: Int64(value * 65_536))
    if fixed == 0, value != 0 { return value > 0 ? 1 : -1 }
    return fixed
  }
}

struct DockSwipeSystemDependencies {
  let operatingSystemMajorVersion: () -> Int
  let accessibilityTrusted: () -> Bool
  let missionControlActive: () -> Bool
  let cursorDisplayUUID: () -> String?
  let displayIDForUUID: (String) -> CGDirectDisplayID?
  let displayBounds: (CGDirectDisplayID) -> CGRect
  let cursorPosition: () -> CGPoint?
  let warpCursor: (CGPoint) -> Void
  let schedule: (TimeInterval, @escaping () -> Void) -> Void
  let postEvents: ([CGEvent]) -> Void

  static let live = DockSwipeSystemDependencies(
    operatingSystemMajorVersion: {
      ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    },
    accessibilityTrusted: { AXIsProcessTrusted() },
    missionControlActive: { DockSwipeMissionControlDetector.isActive() },
    cursorDisplayUUID: { SpaceManager.cursorDisplayUUID() },
    displayIDForUUID: { SpaceManager.displayIDForUUID($0) },
    displayBounds: { CGDisplayBounds($0) },
    cursorPosition: { CGEvent(source: nil)?.location },
    warpCursor: { SpaceManager.warpCursor(to: $0) },
    schedule: { delay, work in
      DockSwipeCursorRestoreScheduler.schedule(after: delay, work)
    },
    postEvents: { events in
      for event in events {
        event.post(tap: .cgSessionEventTap)
      }
    })
}

enum DockSwipeCursorRestoreScheduler {
  static func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
    DispatchQueue.global(qos: .userInteractive).asyncAfter(
      deadline: .now() + delay, execute: work)
  }
}

final class DockSwipeSpaceSwitcher: InstantSpaceSwitching {
  private static let instantVelocity = 400.0
  private static let cursorRestoreDelay: TimeInterval = 0.15
  private static let cursorRestoreTolerance: CGFloat = 2

  private let dependencies: DockSwipeSystemDependencies

  init(dependencies: DockSwipeSystemDependencies = .live) {
    self.dependencies = dependencies
  }

  func switchToSpace(_ target: SpaceInfo, among spaces: [SpaceInfo])
    -> InstantSpaceSwitchResult
  {
    guard target.type == .desktop else { return .declined }

    let displaySpaces = spaces.filter { $0.displayUUID == target.displayUUID }
    let currentIndex = displaySpaces.firstIndex(where: \.isCurrent) ?? -1
    let targetIndex = displaySpaces.firstIndex(where: { $0.id == target.id }) ?? -1

    let plan: DockSwipePlan
    switch DockSwipePlanner.plan(
      currentIndex: currentIndex,
      targetIndex: targetIndex,
      spaceCount: displaySpaces.count)
    {
    case .alreadyThere:
      return .alreadyThere
    case .invalid:
      return .declined
    case .navigate(let navigationPlan):
      plan = navigationPlan
    }

    guard dependencies.accessibilityTrusted(), !dependencies.missionControlActive()
    else { return .declined }

    guard let cursorDisplayUUID = dependencies.cursorDisplayUUID() else {
      return .declined
    }
    if cursorDisplayUUID == target.displayUUID {
      return post(plan) ? .switched : .declined
    }

    guard let displayID = dependencies.displayIDForUUID(target.displayUUID),
      let originalCursorPosition = dependencies.cursorPosition()
    else { return .declined }

    let bounds = dependencies.displayBounds(displayID)
    let routingPoint = CGPoint(x: bounds.midX, y: bounds.midY)
    dependencies.warpCursor(routingPoint)

    guard post(plan) else {
      dependencies.warpCursor(originalCursorPosition)
      return .declined
    }

    let dependencies = dependencies
    dependencies.schedule(Self.cursorRestoreDelay) {
      guard let currentPosition = dependencies.cursorPosition(),
        abs(currentPosition.x - routingPoint.x) <= Self.cursorRestoreTolerance,
        abs(currentPosition.y - routingPoint.y) <= Self.cursorRestoreTolerance
      else { return }
      dependencies.warpCursor(originalCursorPosition)
    }
    return .switched
  }

  private func post(_ plan: DockSwipePlan) -> Bool {
    let velocity = Self.instantVelocity * Double(plan.steps)
    let augmented = dependencies.operatingSystemMajorVersion() >= 27
    var events: [CGEvent] = []

    for _ in 0..<plan.steps {
      let stepEvents =
        augmented
        ? DockSwipeEventFactory.makeAugmentedEvents(
          direction: plan.direction, velocity: velocity)
        : DockSwipeEventFactory.makeLegacyEvents(
          direction: plan.direction, velocity: velocity)
      guard let stepEvents else { return false }
      events.append(contentsOf: stepEvents)
    }

    dependencies.postEvents(events)
    return true
  }
}

enum DockSwipeMissionControlDetector {
  static func isActive() -> Bool {
    guard
      let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
        as? [[String: Any]]
    else { return false }
    return isActive(in: windows)
  }

  static func isActive(in windows: [[String: Any]]) -> Bool {
    windows.contains { window in
      (window[kCGWindowOwnerName as String] as? String) == "Dock"
        && (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 18
    }
  }
}

extension Data {
  fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }
}
