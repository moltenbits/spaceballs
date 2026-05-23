import ArgumentParser
import Foundation
import SpaceballsCore

// MARK: - Parent command

struct DiagnosticsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "diagnostics",
    abstract: "Inspect and control Spaceballs diagnostic logging",
    subcommands: [
      EnableDiagnosticsCommand.self,
      DisableDiagnosticsCommand.self,
      DiagnosticsStatusCommand.self,
      DiagnosticsPathCommand.self,
      TailDiagnosticsCommand.self,
      MarkDiagnosticsCommand.self,
      ClearDiagnosticsCommand.self,
    ],
    defaultSubcommand: DiagnosticsStatusCommand.self
  )
}

// MARK: - Enable / disable

struct EnableDiagnosticsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "enable",
    abstract: "Turn diagnostic logging on"
  )

  func run() throws {
    Diagnostics.enabled = true
    // Write a header right now so anyone reading the log immediately has the system
    // context. We don't have a SpaceManager here from the CLI (cheap to construct);
    // create one so the header includes the Space layout too.
    let spaceManager = SpaceManager(dataSource: CGSDataSource())
    Diagnostics.writeHeader(appVersion: SpaceballsVersion.version, spaceManager: spaceManager)
    print("Diagnostics enabled. Log: \(Diagnostics.logPath)")
  }
}

struct DisableDiagnosticsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "disable",
    abstract: "Turn diagnostic logging off"
  )

  func run() throws {
    Diagnostics.enabled = false
    print("Diagnostics disabled.")
  }
}

// MARK: - Status / path

struct DiagnosticsStatusCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Show whether diagnostics are enabled and where the log lives"
  )

  func run() throws {
    let enabled = Diagnostics.enabled
    let size = Diagnostics.currentLogSize()
    let redact = Diagnostics.redactWindowTitles
    print("enabled: \(enabled)")
    print("redact window titles: \(redact)")
    print("log path: \(Diagnostics.logPath)")
    print("log size: \(formatBytes(size))")
  }
}

struct DiagnosticsPathCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "path",
    abstract: "Print the diagnostics log path (one line, scripting-friendly)"
  )

  func run() throws {
    print(Diagnostics.logPath)
  }
}

// MARK: - Tail / mark / clear

struct TailDiagnosticsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tail",
    abstract: "Stream the log to stdout (like `tail -f`)"
  )

  @Flag(name: .shortAndLong, help: "Print the entire log first, then stream new lines.")
  var all = false

  func run() throws {
    // Delegate to the system `tail` so we don't reinvent the wheel (and we get
    // Ctrl-C handling and rotation tolerance for free with `-F`).
    let path = Diagnostics.logPath
    if !FileManager.default.fileExists(atPath: path) {
      print("Log file not found at \(path).")
      print("Enable diagnostics with `spaceballs diagnostics enable` and reproduce the issue.")
      return
    }
    let args: [String]
    if all {
      args = ["-n", "+1", "-F", path]
    } else {
      args = ["-F", path]
    }
    let proc = Process()
    proc.launchPath = "/usr/bin/tail"
    proc.arguments = args
    do {
      try proc.run()
      proc.waitUntilExit()
    } catch {
      throw error
    }
  }
}

struct MarkDiagnosticsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mark",
    abstract: "Write a labeled marker to the log",
    discussion:
      "Useful before reproducing a bug — gives you a unique needle to grep for "
      + "when reading the log afterwards."
  )

  @Argument(help: "Free-form note. Multiple words are joined with spaces.")
  var note: [String] = []

  func run() throws {
    if !Diagnostics.enabled {
      print(
        "warning: diagnostics are currently disabled — the mark won't be written. "
          + "Run `spaceballs diagnostics enable` first.",
        to: &stderr
      )
      return
    }
    let text = note.isEmpty ? "(no note)" : note.joined(separator: " ")
    Diagnostics.mark(text)
    print("Marker written: \(text)")
  }
}

struct ClearDiagnosticsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "clear",
    abstract: "Truncate the diagnostics log to zero bytes"
  )

  func run() throws {
    Diagnostics.clear()
    print("Log cleared.")
  }
}

// MARK: - Helpers

private func formatBytes(_ bytes: Int) -> String {
  if bytes == 0 { return "0 B" }
  let kb = Double(bytes) / 1024.0
  if kb < 1024 { return String(format: "%.1f KB", kb) }
  return String(format: "%.2f MB", kb / 1024.0)
}

/// Stderr handle wrapped as a TextOutputStream for warning messages.
private struct StderrStream: TextOutputStream {
  mutating func write(_ string: String) {
    FileHandle.standardError.write(Data(string.utf8))
  }
}
private var stderr = StderrStream()
