import AppKit
import SpaceballsCore
import SpaceballsGUILib
import SwiftUI

struct DiagnosticsPane: View {
  @ObservedObject var settings: AppSettings
  let spaceManager: SpaceManager

  @State private var logSizeBytes: Int = 0
  @State private var statusMessage: String?

  private var appVersion: String {
    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    return "\(v) (\(b))"
  }

  /// Periodically refreshes the log size readout while the pane is visible.
  private let sizeRefresh = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

  var body: some View {
    Form {
      Section {
        Toggle("Enable diagnostic logging", isOn: $settings.diagnosticsEnabled)
          .onChange(of: settings.diagnosticsEnabled) { _, isOn in
            if isOn {
              // Write a fresh header immediately so the log contains the system context
              // for whatever the user is about to reproduce.
              Diagnostics.writeHeader(appVersion: appVersion, spaceManager: spaceManager)
              statusMessage = "Logging enabled. A system snapshot has been written."
            } else {
              statusMessage = "Logging disabled."
            }
          }
        Text(
          "When on, Spaceballs writes detailed events to a log file you can attach to bug "
            + "reports. Off by default. Includes window resize/move events, space changes, "
            + "and display reconfigurations."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Privacy") {
        Toggle("Redact window titles", isOn: $settings.diagnosticsRedactWindowTitles)
        Text("Window titles in log entries are replaced with `<redacted>`.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Log file") {
        LabeledContent("Location") {
          HStack(spacing: 6) {
            Text(Diagnostics.logPath)
              .font(.system(.caption, design: .monospaced))
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
            Button {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(Diagnostics.logPath, forType: .string)
              statusMessage = "Path copied."
            } label: {
              Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy path")
          }
        }

        LabeledContent("Current size") {
          Text(humanReadableSize(logSizeBytes))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }

        HStack(spacing: 8) {
          Button("Open Log") { openLog() }
            .disabled(!FileManager.default.fileExists(atPath: Diagnostics.logPath))
          Button("Reveal in Finder") { revealLog() }
            .disabled(!FileManager.default.fileExists(atPath: Diagnostics.logPath))
          Button("Clear Log", role: .destructive) {
            Diagnostics.clear()
            statusMessage = "Log cleared."
            refreshSize()
          }
          .disabled(!FileManager.default.fileExists(atPath: Diagnostics.logPath))
        }

        if let statusMessage {
          Text(statusMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear { refreshSize() }
    .onReceive(sizeRefresh) { _ in refreshSize() }
  }

  // MARK: - Actions

  private func openLog() {
    let url = URL(fileURLWithPath: Diagnostics.logPath)
    NSWorkspace.shared.open(url)
  }

  private func revealLog() {
    let url = URL(fileURLWithPath: Diagnostics.logPath)
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private func refreshSize() {
    logSizeBytes = Diagnostics.currentLogSize()
  }

  private func humanReadableSize(_ bytes: Int) -> String {
    if bytes == 0 { return "—" }
    let kb = Double(bytes) / 1024.0
    if kb < 1024 { return String(format: "%.1f KB", kb) }
    return String(format: "%.2f MB", kb / 1024.0)
  }
}
