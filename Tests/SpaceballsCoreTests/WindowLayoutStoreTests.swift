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
