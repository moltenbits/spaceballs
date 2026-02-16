import ServiceManagement
import SwiftUI

struct GeneralPane: View {
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

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
}
