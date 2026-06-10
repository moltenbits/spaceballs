import AppKit
import Cocoa
import Foundation

// MARK: - Public API

/// File-based diagnostic logger, gated by an opt-in setting (`diagnosticsEnabled`).
///
/// Logs land in `~/Library/Logs/Spaceballs/spaceballs.log` (the standard macOS location;
/// Console.app picks it up automatically and it's the obvious thing to attach to a bug
/// report). Falls back to `/tmp/spaceballs.log` if the Library path can't be created.
///
/// All writes happen on a dedicated serial queue so callers don't block. Rotation is
/// size-based: when the file exceeds `rotationThreshold`, it's renamed `.1` and a fresh
/// file is opened.
///
/// Concurrency: `enabled`, `redactWindowTitles`, and `customLogPath` are guarded by an
/// internal lock; all log writes happen on the serial queue, so the user-visible API is
/// thread-safe.
public enum Diagnostics {

  /// UserDefaults keys — shared between GUI (AppSettings) and CLI subcommands.
  public enum SettingsKey {
    public static let enabled = "diagnosticsEnabled"
    public static let redactWindowTitles = "diagnosticsRedactWindowTitles"
  }

  /// Default log directory: `~/Library/Logs/Spaceballs/`.
  public static var defaultLogDirectory: URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent("Library/Logs/Spaceballs", isDirectory: true)
  }

  /// Default log file path.
  public static var defaultLogPath: String {
    defaultLogDirectory.appendingPathComponent("spaceballs.log").path
  }

  /// Returns the resolved log path (uses `customLogPath` if set, otherwise the default).
  public static var logPath: String {
    stateLock.withLock { _customLogPath ?? defaultLogPath }
  }

  /// Shared preferences suite read by both the GUI app and the CLI. The two run with
  /// different preference domains (`com.moltenbits.spaceballs` for the bundled GUI, the
  /// bare process name for the unbundled CLI binary), so `UserDefaults.standard` is NOT
  /// shared between them. Same convention as `SpaceNameStore`.
  private static let sharedDefaults =
    UserDefaults(suiteName: "com.moltenbits.spaceballs.shared") ?? .standard

  /// True when diagnostics are turned on. Backed by the shared suite so GUI and CLI
  /// changes take effect in both processes without a restart (cfprefsd propagates
  /// cross-process writes). A non-nil `runtimeOverride` (set via `setRuntimeOverride(_:)`)
  /// takes precedence. Tests do not inherit the user's saved preference: when we detect
  /// the process is a test runner, the override defaults to `false`. Tests that
  /// explicitly want logging can set the override true (with a custom log path) for
  /// their scope.
  public static var enabled: Bool {
    get {
      if let override = stateLock.withLock({ _runtimeOverride }) { return override }
      return sharedDefaults.bool(forKey: SettingsKey.enabled)
    }
    set {
      sharedDefaults.set(newValue, forKey: SettingsKey.enabled)
    }
  }

  /// Bypasses the shared-suite-backed `enabled` flag. `nil` clears the override.
  public static func setRuntimeOverride(_ value: Bool?) {
    stateLock.withLock { _runtimeOverride = value }
  }

  /// When true, replace window titles in log entries with `<redacted>`. For users who want
  /// to share logs publicly. Off by default — titles are usually needed to diagnose.
  public static var redactWindowTitles: Bool {
    get { sharedDefaults.bool(forKey: SettingsKey.redactWindowTitles) }
    set { sharedDefaults.set(newValue, forKey: SettingsKey.redactWindowTitles) }
  }

  /// Override the log destination (tests, CLI `--log-path`, etc).
  public static func setCustomLogPath(_ path: String?) {
    stateLock.withLock { _customLogPath = path }
  }

  // MARK: - Logging

  /// Records a categorized log line. No-op when `enabled` is false. `app` is an optional
  /// tag (typically bundle ID or app name) included in the entry.
  public static func log(
    _ category: String, _ message: String, app: String? = nil
  ) {
    guard enabled else { return }
    let line = formatLine(category: category, app: app, message: message)
    write(line)
  }

  /// Writes a user-supplied marker — useful for "I just hit the bug, log this so we can
  /// find it" workflows.
  public static func mark(_ note: String) {
    guard enabled else { return }
    log("mark", note)
  }

  // MARK: - Timing

  /// Token returned by `beginTiming` and passed to `endTiming`. Carries the start time
  /// and identifying context.
  public struct TimingToken {
    let category: String
    let name: String
    let startTime: Date
    let app: String?
    let extras: [String: String]
  }

  /// Begin a timing measurement. The returned token must be passed to `endTiming`. If
  /// diagnostics are disabled, this still returns a token but produces no output.
  public static func beginTiming(
    _ category: String, _ name: String, app: String? = nil, extras: [String: String] = [:]
  ) -> TimingToken {
    let token = TimingToken(
      category: category, name: name, startTime: Date(), app: app, extras: extras)
    if enabled {
      var msg = "\(name) started"
      if !extras.isEmpty {
        msg += " " + extras.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
      }
      log(category, msg, app: app)
    }
    return token
  }

  /// End a timing measurement and emit a log line with the elapsed time.
  public static func endTiming(_ token: TimingToken, outcome: String? = nil) {
    guard enabled else { return }
    let durationMs = Int(Date().timeIntervalSince(token.startTime) * 1000)
    var msg = "\(token.name) finished duration=\(durationMs)ms"
    if let outcome = outcome {
      msg += " outcome=\(outcome)"
    }
    log(token.category, msg, app: token.app)
  }

  /// Convenience: time a synchronous closure. The closure result is returned to the caller.
  @discardableResult
  public static func time<T>(
    _ category: String, _ name: String, app: String? = nil,
    _ body: () throws -> T
  ) rethrows -> T {
    let token = beginTiming(category, name, app: app)
    do {
      let result = try body()
      endTiming(token, outcome: "ok")
      return result
    } catch {
      endTiming(token, outcome: "error:\(error)")
      throw error
    }
  }

  // MARK: - Header / context dump

  /// Writes a header block capturing the current system context: Spaceballs version,
  /// macOS version, displays, AX/Screen-Recording permission state, frontmost app, and
  /// optionally — if a `SpaceManager` is provided — the current Space layout.
  ///
  /// Called when diagnostics are enabled, and again on display reconfigurations so the
  /// log always contains a recent snapshot you can correlate against.
  public static func writeHeader(
    appVersion: String, spaceManager: SpaceManagerSnapshotProvider? = nil
  ) {
    guard enabled else { return }
    var lines: [String] = []
    lines.append("===== spaceballs diagnostics header =====")
    lines.append("timestamp=\(headerTimestampFormatter.string(from: Date()))")
    lines.append("spaceballs.version=\(appVersion)")

    let pi = ProcessInfo.processInfo
    let osv = pi.operatingSystemVersion
    lines.append(
      "macos=\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion) "
        + "build=\(pi.operatingSystemVersionString)"
    )
    lines.append("axTrusted=\(AXIsProcessTrusted())")
    lines.append("screenRecording=\(hasScreenRecordingPermission())")
    if let front = NSWorkspace.shared.frontmostApplication {
      lines.append(
        "frontmost=\(front.bundleIdentifier ?? "?") name=\(front.localizedName ?? "?") "
          + "pid=\(front.processIdentifier)"
      )
    }

    // Displays
    let screens = NSScreen.screens
    lines.append("displays.count=\(screens.count)")
    for (idx, s) in screens.enumerated() {
      let uuid = displayUUID(for: s) ?? "?"
      let name = s.localizedName
      let f = s.frame
      let v = s.visibleFrame
      let scale = s.backingScaleFactor
      let isPrimary = (idx == 0)
      lines.append(
        "display[\(idx)] uuid=\(uuid) name=\"\(name)\" primary=\(isPrimary) "
          + "frame=(\(Int(f.origin.x)),\(Int(f.origin.y)))/\(Int(f.width))x\(Int(f.height)) "
          + "visible=(\(Int(v.origin.x)),\(Int(v.origin.y)))/\(Int(v.width))x\(Int(v.height)) "
          + "scale=\(scale)"
      )
    }

    // Spaces
    if let snapshot = spaceManager?.spaceSnapshotForDiagnostics() {
      lines.append("spaces.count=\(snapshot.count)")
      for entry in snapshot {
        lines.append("space \(entry)")
      }
    } else {
      lines.append("spaces=unavailable (no SpaceManager)")
    }

    lines.append("===== end header =====")
    write(lines.joined(separator: "\n") + "\n")
  }

  // MARK: - Maintenance

  /// Truncates the log to zero bytes. The file is kept (so `tail -f` callers stay alive).
  public static func clear() {
    let path = logPath
    diagQueue.sync {
      // Remove rotated copy too.
      try? FileManager.default.removeItem(atPath: path + ".1")
      try? Data().write(to: URL(fileURLWithPath: path))
    }
  }

  /// Blocks until all queued writes have completed. Short-lived processes (the CLI)
  /// must call this before exiting or the async writes get lost when the process
  /// terminates. The GUI doesn't need to call it — writes drain naturally as the
  /// process lives on.
  public static func flush() {
    diagQueue.sync {}
  }

  /// Returns the current log size in bytes (or 0 if missing).
  public static func currentLogSize() -> Int {
    let path = logPath
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    return (attrs?[.size] as? Int) ?? 0
  }

  // MARK: - Helpers exposed for callers

  /// Returns a redacted-or-not window title based on `redactWindowTitles`.
  public static func titleForLogging(_ title: String?) -> String {
    guard let title = title else { return "?" }
    return redactWindowTitles ? "<redacted>" : title
  }

  // MARK: - Internals

  private static let diagQueue = DispatchQueue(
    label: "com.moltenbits.spaceballs.diagnostics", qos: .utility)
  private static let stateLock = NSLock()
  private static var _customLogPath: String? = nil
  /// Default `false` when we're running inside a test process so the user's saved
  /// `diagnosticsEnabled` doesn't bleed into test runs.
  private static var _runtimeOverride: Bool? = Diagnostics.isLikelyTestProcess ? false : nil
  private static let rotationThreshold: Int = 5 * 1024 * 1024  // 5 MB

  /// Heuristic: are we running inside `swift test` or an XCTest bundle? Used to default
  /// the runtime override to `false` so tests never write to the user's real log.
  /// `swift test` actually runs `swiftpm-testing-helper`; XCTest runs `xctest`; the
  /// PackageTests bundle (run directly) has `PackageTests` in its name. We match all
  /// three, plus check for the XCTest framework being loaded as a last resort.
  private static let isLikelyTestProcess: Bool = {
    let exe = CommandLine.arguments.first ?? ""
    if exe.contains("xctest")
      || exe.contains("PackageTests")
      || exe.contains("swift-testing")
      || exe.contains("swiftpm-testing-helper")
    {
      return true
    }
    if NSClassFromString("XCTest") != nil || NSClassFromString("XCTestCase") != nil {
      return true
    }
    return false
  }()

  private static let timestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
  }()

  private static let headerTimestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSZ"
    return f
  }()

  private static func formatLine(category: String, app: String?, message: String) -> String {
    var line = "\(timestampFormatter.string(from: Date())) [\(category)]"
    if let app = app {
      line += " app=\(app)"
    }
    line += " \(message)\n"
    return line
  }

  private static func write(_ line: String) {
    diagQueue.async {
      let path = resolvedPath()
      ensureContainingDirectory(for: path)
      rotateIfNeeded(at: path)
      guard let data = line.data(using: .utf8) else { return }
      if FileManager.default.fileExists(atPath: path),
        let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
      {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
      } else {
        try? data.write(to: URL(fileURLWithPath: path))
      }
    }
  }

  private static func resolvedPath() -> String {
    let preferred = logPath
    let dir = (preferred as NSString).deletingLastPathComponent
    if ensureDirectoryExists(dir) {
      return preferred
    }
    // Fall back to /tmp if the preferred directory can't be created.
    return "/tmp/spaceballs.log"
  }

  private static func ensureContainingDirectory(for path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    _ = ensureDirectoryExists(dir)
  }

  @discardableResult
  private static func ensureDirectoryExists(_ dir: String) -> Bool {
    if FileManager.default.fileExists(atPath: dir) { return true }
    do {
      try FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true)
      return true
    } catch {
      return false
    }
  }

  private static func rotateIfNeeded(at path: String) {
    guard FileManager.default.fileExists(atPath: path),
      let attrs = try? FileManager.default.attributesOfItem(atPath: path),
      let size = attrs[.size] as? Int,
      size > rotationThreshold
    else { return }
    let backup = path + ".1"
    try? FileManager.default.removeItem(atPath: backup)
    try? FileManager.default.moveItem(atPath: path, toPath: backup)
  }

  private static func displayUUID(for screen: NSScreen) -> String? {
    guard
      let screenNumber = screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
      let cfUUID = CGDisplayCreateUUIDFromDisplayID(screenNumber)?.takeUnretainedValue()
    else { return nil }
    return CFUUIDCreateString(nil, cfUUID) as String
  }

  /// `CGPreflightScreenCaptureAccess` exists from macOS 11+ — this matches the project's
  /// minimum target.
  private static func hasScreenRecordingPermission() -> Bool {
    if #available(macOS 11.0, *) {
      return CGPreflightScreenCaptureAccess()
    }
    return false
  }
}

// MARK: - Snapshot protocol

/// Adapter so `Diagnostics.writeHeader` can dump Space info without forcing a direct
/// import of `SpaceManager` (avoiding initialization-order dependencies).
public protocol SpaceManagerSnapshotProvider {
  /// Returns one human-readable string per Space — content is up to the implementation,
  /// the header just appends them verbatim.
  func spaceSnapshotForDiagnostics() -> [String]
}

// MARK: - NSLock helper

extension NSLock {
  @discardableResult
  fileprivate func withLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
