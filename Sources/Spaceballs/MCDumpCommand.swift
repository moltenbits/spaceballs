import ArgumentParser
import SpaceballsCore

struct MCDumpCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mc-dump",
    abstract: "Dump Mission Control's AX hierarchy (diagnostic tool)"
  )

  @Flag(help: "Hover the main display's spaces bar so it expands before dumping")
  var hover = false

  @Option(help: "Seconds to hold Mission Control open after dumping (for screenshots)")
  var hold: Double = 0.3

  func run() throws {
    let manager = SpaceManager()
    manager.dumpMissionControlAXTree(hoverSpacesBar: hover, hold: hold)
  }
}
