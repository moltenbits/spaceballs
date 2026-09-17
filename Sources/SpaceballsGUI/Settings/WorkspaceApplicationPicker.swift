import AppKit
import SpaceballsGUILib
import UniformTypeIdentifiers

enum WorkspaceApplicationPicker {
  static func choose() -> WorkspaceApplication? {
    let panel = NSOpenPanel()
    panel.title = "Choose Application"
    panel.prompt = "Choose"
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.allowedContentTypes = [.applicationBundle]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    guard let application = WorkspaceApplication(url: url) else {
      let alert = NSAlert()
      alert.messageText = "Could not use this application"
      alert.informativeText = "Choose a macOS application with a valid bundle identifier."
      alert.runModal()
      return nil
    }
    return application
  }
}
