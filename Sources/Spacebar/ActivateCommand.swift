import ArgumentParser
import Cocoa
import SpacebarCore

struct ActivateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "activate",
    abstract: "Activate (bring to front) a window by its ID"
  )

  @Argument(help: "The window ID to activate (from 'spacebar list')")
  var windowID: Int

  func run() throws {
    // Run as a GUI process so WindowServer honors SkyLight calls.
    // The .app bundle's Info.plist sets LSUIElement=true (no Dock icon).
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let windowID = self.windowID

    // Schedule activation after NSApp.run() establishes the WindowServer
    // connection via finishLaunching().
    DispatchQueue.main.async {
      let manager = SpaceManager()
      do {
        try manager.activateWindow(id: windowID)
      } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        Darwin.exit(1)
      }

      // Brief pause for the space-switch animation to begin, then exit.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        Darwin.exit(0)
      }
    }

    app.run()
  }
}
