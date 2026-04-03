import ServiceManagement
import SpacebarGUILib
import SwiftUI

struct GeneralPane: View {
  @ObservedObject var settings: AppSettings

  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @State private var statusMessage: String?

  var body: some View {
    Form {
      Section {
        Toggle("Launch at login", isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { _, newValue in
            do {
              if newValue {
                try SMAppService.mainApp.register()
              } else {
                try SMAppService.mainApp.unregister()
              }
            } catch {
              // Revert on failure
              launchAtLogin = SMAppService.mainApp.status == .enabled
            }
          }
        Text("Spacebar will start automatically when you log in.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Import & Export") {
        HStack(spacing: 12) {
          Button("Export Settings...") {
            exportSettings()
          }
          Button("Import Settings...") {
            importSettings()
          }
        }
        if let statusMessage {
          Text(statusMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section {
        Button("Quit Spacebar") {
          NSApp.terminate(nil)
        }
        Text("Will still launch at login if enabled above.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .onAppear {
      launchAtLogin = SMAppService.mainApp.status == .enabled
    }
  }

  private func exportSettings() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "spacebar-settings.json"
    panel.canCreateDirectories = true

    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      let data = try SettingsExport.exportJSON(settings: settings)
      try data.write(to: url)
      statusMessage = "Settings exported."
    } catch {
      statusMessage = "Export failed: \(error.localizedDescription)"
    }
  }

  private func importSettings() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false

    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      let data = try Data(contentsOf: url)
      try SettingsExport.importJSON(data, settings: settings)
      statusMessage = "Settings imported."
    } catch {
      statusMessage = "Import failed: \(error.localizedDescription)"
    }
  }
}
