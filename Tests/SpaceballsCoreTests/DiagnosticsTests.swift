import Foundation
import Testing

@testable import SpaceballsCore

@Suite("Diagnostics", .serialized)
struct DiagnosticsTests {

  /// Saves the shared-suite value of a key, runs `body`, restores value-or-absence.
  private func withRestoredSharedKey(_ key: String, _ body: () throws -> Void) throws {
    let shared = try #require(UserDefaults(suiteName: "com.moltenbits.spaceballs.shared"))
    let original = shared.object(forKey: key)
    defer {
      if let original {
        shared.set(original, forKey: key)
      } else {
        shared.removeObject(forKey: key)
      }
    }
    try body()
  }

  @Test("titleForLogging passes through when redaction is off")
  func titlePassThrough() throws {
    try withRestoredSharedKey(Diagnostics.SettingsKey.redactWindowTitles) {
      Diagnostics.redactWindowTitles = false
      #expect(Diagnostics.titleForLogging("Untitled.txt") == "Untitled.txt")
      #expect(Diagnostics.titleForLogging(nil) == "?")
    }
  }

  @Test("titleForLogging redacts when enabled")
  func titleRedact() throws {
    try withRestoredSharedKey(Diagnostics.SettingsKey.redactWindowTitles) {
      Diagnostics.redactWindowTitles = true
      #expect(Diagnostics.titleForLogging("My Secret Project") == "<redacted>")
      #expect(Diagnostics.titleForLogging(nil) == "?")
    }
  }

  @Test("enabled flag round-trips through the shared CLI/GUI suite")
  func enabledRoundtrip() throws {
    // The flag must live in the shared suite (same one SpaceNameStore uses) — NOT
    // UserDefaults.standard. The GUI (bundled, com.moltenbits.spaceballs domain) and the
    // CLI (unbundled, process-name domain) have different standard domains, so a flag
    // written to .standard by one is invisible to the other.
    let shared = try #require(UserDefaults(suiteName: "com.moltenbits.spaceballs.shared"))
    let key = Diagnostics.SettingsKey.enabled
    let original = shared.object(forKey: key)
    // Tests default to a false runtime override (set in Diagnostics.swift) so the user's
    // saved diagnostics state doesn't bleed into the test process. Clear it here so the
    // getter actually reads from the suite.
    let tmpPath = NSTemporaryDirectory() + "spaceballs-diag-test-\(UUID().uuidString).log"
    Diagnostics.setCustomLogPath(tmpPath)
    Diagnostics.setRuntimeOverride(nil)
    defer {
      // Restore the user's pre-existing value, or remove the key if it wasn't set.
      if let original {
        shared.set(original, forKey: key)
      } else {
        shared.removeObject(forKey: key)
      }
      Diagnostics.setRuntimeOverride(false)
      Diagnostics.setCustomLogPath(nil)
      try? FileManager.default.removeItem(atPath: tmpPath)
    }

    Diagnostics.enabled = true
    #expect(shared.bool(forKey: key) == true)
    #expect(Diagnostics.enabled == true)

    Diagnostics.enabled = false
    #expect(shared.bool(forKey: key) == false)
    #expect(Diagnostics.enabled == false)
  }

  @Test("log() is a no-op when disabled")
  func logNoOpWhenDisabled() throws {
    let tmpPath = NSTemporaryDirectory() + "spaceballs-diag-test-\(UUID().uuidString).log"
    Diagnostics.setCustomLogPath(tmpPath)
    Diagnostics.setRuntimeOverride(false)
    defer {
      // Leave override at false — that's the test-process default and the safe state.
      Diagnostics.setCustomLogPath(nil)
      try? FileManager.default.removeItem(atPath: tmpPath)
    }

    Diagnostics.log("test", "should-not-appear")
    // Give the (no-op) call a moment in case it accidentally queued anything.
    Thread.sleep(forTimeInterval: 0.05)
    #expect(!FileManager.default.fileExists(atPath: tmpPath))
  }

  @Test("log() writes when enabled and respects custom path")
  func logWritesWhenEnabled() throws {
    let tmpPath = NSTemporaryDirectory() + "spaceballs-diag-test-\(UUID().uuidString).log"
    Diagnostics.setCustomLogPath(tmpPath)
    Diagnostics.setRuntimeOverride(true)
    defer {
      Diagnostics.setRuntimeOverride(false)
      Diagnostics.setCustomLogPath(nil)
      try? FileManager.default.removeItem(atPath: tmpPath)
    }

    Diagnostics.log("test", "hello-world", app: "com.example.app")

    // Diagnostics writes are async on a serial queue; poll briefly for the file.
    var contents: String?
    for _ in 0..<30 {
      if FileManager.default.fileExists(atPath: tmpPath) {
        contents = try? String(contentsOfFile: tmpPath, encoding: .utf8)
        if contents?.contains("hello-world") == true { break }
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    let found = contents ?? ""
    #expect(found.contains("[test]"))
    #expect(found.contains("app=com.example.app"))
    #expect(found.contains("hello-world"))
  }

  @Test("beginTiming/endTiming emits both events with duration")
  func timingEmitsBothEvents() throws {
    let tmpPath = NSTemporaryDirectory() + "spaceballs-diag-test-\(UUID().uuidString).log"
    Diagnostics.setCustomLogPath(tmpPath)
    Diagnostics.setRuntimeOverride(true)
    defer {
      Diagnostics.setRuntimeOverride(false)
      Diagnostics.setCustomLogPath(nil)
      try? FileManager.default.removeItem(atPath: tmpPath)
    }

    let token = Diagnostics.beginTiming("test", "my-op", app: "demo")
    Thread.sleep(forTimeInterval: 0.030)
    Diagnostics.endTiming(token, outcome: "ok")

    var contents: String?
    for _ in 0..<30 {
      if FileManager.default.fileExists(atPath: tmpPath) {
        contents = try? String(contentsOfFile: tmpPath, encoding: .utf8)
        if contents?.contains("finished") == true { break }
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    let found = contents ?? ""
    #expect(found.contains("my-op started"))
    #expect(found.contains("my-op finished"))
    #expect(found.contains("duration="))
    #expect(found.contains("outcome=ok"))
  }
}
