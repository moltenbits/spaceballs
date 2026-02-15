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
    // Set up as a real GUI process — this is required for cross-space
    // window activation. WindowServer ignores space-switch requests from
    // processes that aren't registered GUI participants.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let windowID = self.windowID

    // Schedule activation to run after NSApp.run() establishes the
    // WindowServer connection (finishLaunching + event loop).
    DispatchQueue.main.async {
      let manager = SpaceManager()
      do {
        try manager.activateWindow(id: windowID)
      } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        Darwin.exit(1)
      }

      // Wait 5s to give WindowServer time to process space switch.
      DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
        Darwin.exit(0)
      }
    }

    // Start the event loop — blocks until exit() is called above.
    app.run()
  }
}
