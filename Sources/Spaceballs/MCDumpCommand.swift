import ArgumentParser
import SpaceballsCore

struct MCDumpCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mc-dump",
    abstract: "Dump Mission Control's AX hierarchy (diagnostic tool)"
  )

  func run() throws {
    let manager = SpaceManager()
    manager.dumpMissionControlAXTree()
  }
}
