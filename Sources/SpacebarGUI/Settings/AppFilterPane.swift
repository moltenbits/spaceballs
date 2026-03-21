import Cocoa
import SpacebarGUILib
import SwiftUI

/// Info about a discovered app for the filter UI.
struct DiscoveredApp: Identifiable {
  let bundleID: String
  let name: String
  let icon: NSImage?
  let isRunning: Bool

  var id: String { bundleID }
}

struct AppFilterPane: View {
  let title: String
  let description: String
  let policy: NSApplication.ActivationPolicy
  @Binding var selectedBundleIDs: Set<String>

  @State private var discoveredApps: [DiscoveredApp] = []

  private static let selfBundleID = Bundle.main.bundleIdentifier ?? "com.moltenbits.spacebar"

  var body: some View {
    Form {
      Section(title) {
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)

        if runningApps.isEmpty && savedButNotRunningApps.isEmpty {
          Text("No apps found.")
            .foregroundStyle(.secondary)
        }

        ForEach(runningApps) { app in
          appRow(app: app)
        }
      }

      if !savedButNotRunningApps.isEmpty {
        Section("Not Running") {
          ForEach(savedButNotRunningApps) { app in
            appRow(app: app)
          }
        }
      }

      Section {
        Button("Refresh") {
          scanApps()
        }
      }
    }
    .formStyle(.grouped)
    .onAppear {
      scanApps()
    }
  }

  private var runningApps: [DiscoveredApp] {
    discoveredApps.filter(\.isRunning)
  }

  private var savedButNotRunningApps: [DiscoveredApp] {
    discoveredApps.filter { !$0.isRunning }
  }

  private func appRow(app: DiscoveredApp) -> some View {
    Toggle(isOn: toggleBinding(for: app.bundleID)) {
      HStack(spacing: 8) {
        if let icon = app.icon {
          Image(nsImage: icon)
            .resizable()
            .frame(width: 20, height: 20)
        } else {
          Image(systemName: "app")
            .frame(width: 20, height: 20)
        }
        VStack(alignment: .leading, spacing: 1) {
          Text(app.name)
            .lineLimit(1)
          Text(app.bundleID)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
    }
    .opacity(app.isRunning ? 1.0 : 0.5)
  }

  private func toggleBinding(for bundleID: String) -> Binding<Bool> {
    Binding(
      get: { selectedBundleIDs.contains(bundleID) },
      set: { enabled in
        if enabled {
          selectedBundleIDs.insert(bundleID)
        } else {
          selectedBundleIDs.remove(bundleID)
        }
      }
    )
  }

  private func scanApps() {
    let running = NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == policy }
      .filter { $0.bundleIdentifier != Self.selfBundleID }
      .compactMap { app -> DiscoveredApp? in
        guard let bid = app.bundleIdentifier else { return nil }
        return DiscoveredApp(
          bundleID: bid,
          name: app.localizedName ?? bid,
          icon: app.icon,
          isRunning: true
        )
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    let runningBundleIDs = Set(running.map(\.bundleID))
    let savedNotRunning = selectedBundleIDs
      .filter { !runningBundleIDs.contains($0) }
      .map { bid in
        DiscoveredApp(
          bundleID: bid,
          name: bid,
          icon: nil,
          isRunning: false
        )
      }
      .sorted { $0.bundleID < $1.bundleID }

    discoveredApps = running + savedNotRunning
  }
}
