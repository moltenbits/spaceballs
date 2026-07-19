import Cocoa

// Single-instance guard: a second instance would install a second CGEvent tap
// at cghidEventTap, and competing taps intercepting the same hotkeys freeze
// keyboard input system-wide. Accessory apps get no automatic protection here
// (`open -n` or direct binary execution happily spawns duplicates), so exit
// immediately if another instance of this bundle is already running.
if let bundleID = Bundle.main.bundleIdentifier {
  let selfPID = ProcessInfo.processInfo.processIdentifier
  let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != selfPID && !$0.isTerminated }
  if let existing = others.first {
    print("Spaceballs is already running (pid \(existing.processIdentifier)); exiting.")
    exit(0)
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
