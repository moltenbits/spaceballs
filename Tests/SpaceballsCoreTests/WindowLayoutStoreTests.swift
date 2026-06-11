import Foundation
import Testing

@testable import SpaceballsCore

@Suite("WindowLayoutStore Persistence")
struct WindowLayoutStorePersistenceTests {

  private func makeStore(suite: String = UUID().uuidString) -> (WindowLayoutStore, UserDefaults) {
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let manager = SpaceManager(dataSource: MockDataSource())
    return (WindowLayoutStore(defaults: defaults, spaceManager: manager), defaults)
  }

  @Test("setFrame + layout round-trip preserves data")
  func roundTrip() {
    let (store, _) = makeStore()
    let frame = WindowFrame(x: 100, y: 50, width: 800, height: 600)
    store.setFrame(
      bundleID: "com.example.app", frame: frame,
      spaceUUID: "space-1", displayUUID: "display-A")

    let layout = store.layout(spaceUUID: "space-1", displayUUID: "display-A")
    #expect(layout != nil)
    #expect(layout?.apps["com.example.app"] == frame)
    #expect(layout?.spaceUUID == "space-1")
    #expect(layout?.displayUUID == "display-A")
  }

  @Test("Different (space, display) keys are isolated")
  func keyIsolation() {
    let (store, _) = makeStore()
    let frameA = WindowFrame(x: 0, y: 0, width: 100, height: 100)
    let frameB = WindowFrame(x: 200, y: 200, width: 400, height: 400)

    store.setFrame(
      bundleID: "com.app", frame: frameA, spaceUUID: "space-1", displayUUID: "display-A")
    store.setFrame(
      bundleID: "com.app", frame: frameB, spaceUUID: "space-1", displayUUID: "display-B")

    #expect(store.layout(spaceUUID: "space-1", displayUUID: "display-A")?.apps["com.app"] == frameA)
    #expect(store.layout(spaceUUID: "space-1", displayUUID: "display-B")?.apps["com.app"] == frameB)
  }

  @Test("Multiple bundleIDs accumulate in the same (space, display)")
  func multipleBundleIDs() {
    let (store, _) = makeStore()
    store.setFrame(
      bundleID: "com.a", frame: WindowFrame(x: 0, y: 0, width: 100, height: 100),
      spaceUUID: "s", displayUUID: "d")
    store.setFrame(
      bundleID: "com.b", frame: WindowFrame(x: 0, y: 0, width: 200, height: 200),
      spaceUUID: "s", displayUUID: "d")

    let layout = store.layout(spaceUUID: "s", displayUUID: "d")
    #expect(layout?.apps.count == 2)
    #expect(layout?.apps["com.a"] != nil)
    #expect(layout?.apps["com.b"] != nil)
  }

  @Test("clearAll empties the store")
  func clearAll() {
    let (store, _) = makeStore()
    store.setFrame(
      bundleID: "com.a", frame: WindowFrame(x: 0, y: 0, width: 100, height: 100),
      spaceUUID: "s", displayUUID: "d")
    store.setLastSeenDisplay(spaceUUID: "s", displayUUID: "d")

    store.clearAll()

    #expect(store.layout(spaceUUID: "s", displayUUID: "d") == nil)
    #expect(store.lastSeenDisplayUUID(forSpace: "s") == nil)
  }

  @Test("lastSeenDisplayUUID round-trip")
  func lastSeenRoundTrip() {
    let (store, _) = makeStore()
    #expect(store.lastSeenDisplayUUID(forSpace: "s") == nil)
    store.setLastSeenDisplay(spaceUUID: "s", displayUUID: "display-A")
    #expect(store.lastSeenDisplayUUID(forSpace: "s") == "display-A")
    store.setLastSeenDisplay(spaceUUID: "s", displayUUID: "display-B")
    #expect(store.lastSeenDisplayUUID(forSpace: "s") == "display-B")
  }

  @Test("restore with no saved layout returns 0")
  func restoreEmpty() {
    let (store, _) = makeStore()
    #expect(store.restore(spaceUUID: "missing", displayUUID: "missing") == 0)
  }

  @Test("Layouts persist across store instances on same defaults")
  func persistenceAcrossInstances() {
    let suite = "WindowLayoutStoreTests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let manager = SpaceManager(dataSource: MockDataSource())
    let frame = WindowFrame(x: 10, y: 20, width: 300, height: 400)
    do {
      let store = WindowLayoutStore(defaults: defaults, spaceManager: manager)
      store.setFrame(
        bundleID: "com.persisted", frame: frame, spaceUUID: "s-p", displayUUID: "d-p")
      store.setLastSeenDisplay(spaceUUID: "s-p", displayUUID: "d-p")
    }

    let store2 = WindowLayoutStore(defaults: defaults, spaceManager: manager)
    #expect(store2.layout(spaceUUID: "s-p", displayUUID: "d-p")?.apps["com.persisted"] == frame)
    #expect(store2.lastSeenDisplayUUID(forSpace: "s-p") == "d-p")
  }
}

@Suite("WindowLayoutStore Space Filtering")
struct WindowLayoutStoreSpaceFilteringTests {

  // Regression coverage for issue #3: restore() applied saved frames to every window
  // `kAXWindowsAttribute` returned for an app — including windows living on OTHER
  // spaces — physically yanking them across displays and into whichever space was
  // active there. These tests pin the per-window eligibility logic that restore now
  // consults before touching a window.

  /// Two displays, two spaces: space 100 ("uuid-A") current on display-1,
  /// space 200 ("uuid-B") current on display-2.
  private func makeStore() -> WindowLayoutStore {
    var ds = MockDataSource()
    ds.displaySpaces = [
      [
        "Display Identifier": "display-1",
        "Spaces": [
          ["ManagedSpaceID": 100, "uuid": "uuid-A", "type": 0]
        ],
        "Current Space": ["ManagedSpaceID": 100],
      ],
      [
        "Display Identifier": "display-2",
        "Spaces": [
          ["ManagedSpaceID": 200, "uuid": "uuid-B", "type": 0]
        ],
        "Current Space": ["ManagedSpaceID": 200],
      ],
    ]
    // Window 1 lives on space 100; window 2 on space 200; window 3 is sticky
    // (both spaces); window 4 has no space info at all.
    ds.windowSpaces = [
      1: [100],
      2: [200],
      3: [100, 200],
      4: [],
    ]
    let suite = UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return WindowLayoutStore(
      defaults: defaults, spaceManager: SpaceManager(dataSource: ds))
  }

  @Test("spaceID(forUUID:) resolves a known space UUID to its ManagedSpaceID")
  func resolvesKnownUUID() {
    let store = makeStore()
    #expect(store.spaceID(forUUID: "uuid-A") == 100)
    #expect(store.spaceID(forUUID: "uuid-B") == 200)
  }

  @Test("spaceID(forUUID:) returns nil for an unknown space UUID")
  func unknownUUIDIsNil() {
    let store = makeStore()
    #expect(store.spaceID(forUUID: "uuid-nope") == nil)
  }

  @Test("Window on the target space is eligible for restore")
  func windowOnTargetSpaceEligible() {
    let store = makeStore()
    #expect(store.windowIsOnSpace(windowID: 1, spaceID: 100))
  }

  @Test("Window on a different space is NOT eligible — the issue #3 regression")
  func windowOnOtherSpaceExcluded() {
    let store = makeStore()
    // Window 2 lives on space 200. Restoring space 100's layout must not touch it.
    // (Pre-fix, restore had no per-window space check and moved it anyway.)
    #expect(!store.windowIsOnSpace(windowID: 2, spaceID: 100))
  }

  @Test("Sticky window spanning multiple spaces is eligible on any of them")
  func stickyWindowEligible() {
    let store = makeStore()
    #expect(store.windowIsOnSpace(windowID: 3, spaceID: 100))
    #expect(store.windowIsOnSpace(windowID: 3, spaceID: 200))
  }

  @Test("Window with no space info is NOT eligible — skip is the safe default")
  func unknownWindowExcluded() {
    let store = makeStore()
    #expect(!store.windowIsOnSpace(windowID: 4, spaceID: 100))
  }

  @Test("Window absent from the space map entirely is NOT eligible")
  func unmappedWindowExcluded() {
    let store = makeStore()
    #expect(!store.windowIsOnSpace(windowID: 999, spaceID: 100))
  }
}

@Suite("WindowFrame")
struct WindowFrameTests {
  @Test("Codable round-trip preserves values")
  func codableRoundTrip() throws {
    let frame = WindowFrame(x: 12.5, y: 34.0, width: 800.5, height: 600.25)
    let data = try JSONEncoder().encode(frame)
    let decoded = try JSONDecoder().decode(WindowFrame.self, from: data)
    #expect(decoded == frame)
  }

  @Test("Equatable")
  func equatable() {
    let a = WindowFrame(x: 0, y: 0, width: 100, height: 100)
    let b = WindowFrame(x: 0, y: 0, width: 100, height: 100)
    let c = WindowFrame(x: 1, y: 0, width: 100, height: 100)
    #expect(a == b)
    #expect(a != c)
  }
}
