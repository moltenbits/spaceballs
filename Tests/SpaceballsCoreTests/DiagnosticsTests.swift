import Foundation
import Testing

@testable import SpaceballsCore

@Suite("Diagnostics", .serialized)
struct DiagnosticsTests {

  @Test("titleForLogging passes through when redaction is off")
  func titlePassThrough() {
    let defaults = UserDefaults.standard
    defaults.set(false, forKey: Diagnostics.SettingsKey.redactWindowTitles)
    #expect(Diagnostics.titleForLogging("Untitled.txt") == "Untitled.txt")
    #expect(Diagnostics.titleForLogging(nil) == "?")
  }

  @Test("titleForLogging redacts when enabled")
  func titleRedact() {
    let defaults = UserDefaults.standard
    defaults.set(true, forKey: Diagnostics.SettingsKey.redactWindowTitles)
    defer { defaults.set(false, forKey: Diagnostics.SettingsKey.redactWindowTitles) }
    #expect(Diagnostics.titleForLogging("My Secret Project") == "<redacted>")
    #expect(Diagnostics.titleForLogging(nil) == "?")
  }

  @Test("enabled flag round-trips through UserDefaults")
  func enabledRoundtrip() {
    let defaults = UserDefaults.standard
    let originalUD = defaults.bool(forKey: Diagnostics.SettingsKey.enabled)
    // Tests default to a false runtime override (set in Diagnostics.swift) so the user's
    // saved diagnostics state doesn't bleed into the test process. We need to clear that
    // override here so the getter actually reads from UserDefaults.
    let tmpPath = NSTemporaryDirectory() + "spaceballs-diag-test-\(UUID().uuidString).log"
    Diagnostics.setCustomLogPath(tmpPath)
    Diagnostics.setRuntimeOverride(nil)
    defer {
      defaults.set(originalUD, forKey: Diagnostics.SettingsKey.enabled)
      Diagnostics.setRuntimeOverride(false)
      Diagnostics.setCustomLogPath(nil)
      try? FileManager.default.removeItem(atPath: tmpPath)
    }

    Diagnostics.enabled = true
    #expect(defaults.bool(forKey: Diagnostics.SettingsKey.enabled) == true)
    #expect(Diagnostics.enabled == true)

    Diagnostics.enabled = false
    #expect(defaults.bool(forKey: Diagnostics.SettingsKey.enabled) == false)
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
