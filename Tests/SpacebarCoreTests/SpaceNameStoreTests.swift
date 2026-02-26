import Foundation
import Testing

@testable import SpacebarCore

@Suite("SpaceNameStore")
struct SpaceNameStoreTests {

  private func makeStore() -> SpaceNameStore {
    let suiteName = "com.moltenbits.spacebar.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    return SpaceNameStore(defaults: defaults)
  }

  @Test("Store and retrieve a custom name")
  func storeAndRetrieve() {
    let store = makeStore()
    store.setCustomName("Work", forSpaceUUID: "uuid-1")
    #expect(store.customName(forSpaceUUID: "uuid-1") == "Work")
  }

  @Test("Returns nil for unknown UUID")
  func unknownUUID() {
    let store = makeStore()
    #expect(store.customName(forSpaceUUID: "nonexistent") == nil)
  }

  @Test("Setting nil removes the entry")
  func setNilRemoves() {
    let store = makeStore()
    store.setCustomName("Work", forSpaceUUID: "uuid-1")
    store.setCustomName(nil, forSpaceUUID: "uuid-1")
    #expect(store.customName(forSpaceUUID: "uuid-1") == nil)
  }

  @Test("Setting empty string removes the entry")
  func setEmptyRemoves() {
    let store = makeStore()
    store.setCustomName("Work", forSpaceUUID: "uuid-1")
    store.setCustomName("", forSpaceUUID: "uuid-1")
    #expect(store.customName(forSpaceUUID: "uuid-1") == nil)
  }

  @Test("Setting whitespace-only string removes the entry")
  func setWhitespaceRemoves() {
    let store = makeStore()
    store.setCustomName("Work", forSpaceUUID: "uuid-1")
    store.setCustomName("   \n\t  ", forSpaceUUID: "uuid-1")
    #expect(store.customName(forSpaceUUID: "uuid-1") == nil)
  }

  @Test("allCustomNames returns all entries")
  func allNames() {
    let store = makeStore()
    store.setCustomName("Work", forSpaceUUID: "uuid-1")
    store.setCustomName("Personal", forSpaceUUID: "uuid-2")
    let all = store.allCustomNames()
    #expect(all == ["uuid-1": "Work", "uuid-2": "Personal"])
  }

  @Test("allCustomNames returns empty dict when no names set")
  func allNamesEmpty() {
    let store = makeStore()
    #expect(store.allCustomNames().isEmpty)
  }
}
