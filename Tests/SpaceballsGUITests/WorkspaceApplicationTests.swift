import Foundation
import SpaceballsCore
import Testing

@testable import SpaceballsGUILib

@Suite("Workspace Application Selection")
struct WorkspaceApplicationTests {
  @Test("Selection reads identity and uses the chosen bundle's path, not its display name")
  func selectedApplication() throws {
    let url = try makeApplication(name: "Renamed App", displayName: "Friendly App")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let application = try #require(WorkspaceApplication(url: url))
    #expect(application.name == "Friendly App")
    #expect(application.bundleID == "example.selected")

    var launcher = LauncherTemplate.genericOpen.launcher
    let stepID = launcher.steps[0].id
    launcher.selectApplication(application, forStep: stepID)
    #expect(launcher.appName == "Friendly App")
    #expect(launcher.bundleID == "example.selected")
    #expect(launcher.steps[0].action == .openApplication(url.path))
    #expect(launcher.steps[0].id == stepID)
    let restored = try JSONDecoder().decode(AppLauncher.self, from: JSONEncoder().encode(launcher))
    #expect(restored == launcher)
  }

  @Test(
    "Missing display names use the bundle name before the filename",
    arguments: [nil, "", "Bundle Name"])
  func fallbackName(bundleName: String?) throws {
    let url = try makeApplication(name: "Custom App", bundleName: bundleName)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(
      WorkspaceApplication(url: url)?.name
        == (bundleName == "Bundle Name" ? "Bundle Name" : "Custom App"))
  }

  @Test("Invalid selections cannot create an application identity", arguments: ["", "   "])
  func missingBundleID(bundleID: String) throws {
    let url = try makeApplication(name: "Invalid", bundleID: bundleID)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(WorkspaceApplication(url: url) == nil)
    #expect(WorkspaceApplication(url: url.deletingLastPathComponent()) == nil)
    #expect(WorkspaceApplication(url: url.appendingPathComponent("Contents/Info.plist")) == nil)
    #expect(WorkspaceApplication(url: url.appendingPathComponent("Missing.app")) == nil)
  }

  @Test("Replacing an app preserves launcher policy, identity, and unrelated pipeline steps")
  func replacement() throws {
    let url = try makeApplication(name: "Replacement")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let application = try #require(WorkspaceApplication(url: url))
    let script = WorkspaceLauncherStep(action: .shell("echo configured"))
    let open = WorkspaceLauncherStep(action: .openApplication("Old App"))
    var launcher = AppLauncher(
      label: "Custom label", appName: "Old", bundleID: "example.old",
      allowsExistingWindow: false, steps: [script, open])
    let id = launcher.id
    launcher.selectApplication(application, forStep: open.id)
    #expect(launcher.id == id)
    #expect(launcher.label == "Custom label")
    #expect(!launcher.allowsExistingWindow)
    #expect(launcher.steps[0] == script)
    #expect(launcher.steps[1].action == .openApplication(url.path))
    #expect(launcher.appName == "Replacement")
    #expect(launcher.bundleID == "example.selected")

    let selected = launcher
    launcher.selectApplication(application, forStep: UUID())
    #expect(launcher == selected)
    launcher.selectApplication(application, forStep: script.id)
    #expect(launcher == selected)
  }

  @Test("Selecting an app for a Launch Services step sets identity and leaves the step alone")
  func launchServicesSelection() throws {
    let url = try makeApplication(name: "Picked")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let application = try #require(WorkspaceApplication(url: url))

    var launcher = LauncherTemplate.genericLaunchServices.launcher
    let step = launcher.steps[0]
    launcher.selectApplication(application, forStep: step.id)
    #expect(launcher.appName == "Picked")
    #expect(launcher.bundleID == "example.selected")
    #expect(launcher.steps == [step])
  }

  @Test("Selecting an app without a step updates only the launcher identity")
  func identityOnlySelection() throws {
    let url = try makeApplication(name: "Picked")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let application = try #require(WorkspaceApplication(url: url))

    var launcher = LauncherTemplate.iterm.launcher
    let steps = launcher.steps
    launcher.selectApplication(application)
    #expect(launcher.appName == "Picked")
    #expect(launcher.bundleID == "example.selected")
    #expect(launcher.steps == steps)
    #expect(!launcher.allowsExistingWindow)
  }

  @Test("App bundles may omit the optional package type; other bundle extensions are rejected")
  func optionalPackageType() throws {
    let url = try makeApplication(name: "Script App", packageType: nil)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(WorkspaceApplication(url: url)?.bundleID == "example.selected")
    let otherBundle = url.deletingPathExtension().appendingPathExtension("bundle")
    try FileManager.default.copyItem(at: url, to: otherBundle)
    #expect(WorkspaceApplication(url: otherBundle) == nil)
  }

  private func makeApplication(
    name: String, displayName: String? = nil, bundleName: String? = nil,
    bundleID: String = "example.selected", packageType: String? = "APPL"
  ) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = root.appendingPathComponent(name + ".app")
    try FileManager.default.createDirectory(
      at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    var info = ["CFBundleIdentifier": bundleID]
    info["CFBundlePackageType"] = packageType
    info["CFBundleDisplayName"] = displayName
    info["CFBundleName"] = bundleName
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
    return url
  }
}
