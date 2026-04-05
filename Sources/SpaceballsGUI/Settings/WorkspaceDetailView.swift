import SpaceballsGUILib
import SwiftUI

// MARK: - Workspace Detail (Sheet)

struct WorkspaceDetailView: View {
  @ObservedObject var settings: AppSettings
  let workspaceIndex: Int
  let onBack: () -> Void
  @State private var editingLauncherIndex: Int? = nil

  var body: some View {
    VStack(spacing: 0) {
      if let launcherIdx = editingLauncherIndex,
        launcherIdx < settings.workspaces[workspaceIndex].launchers.count
      {
        LauncherDetailView(
          settings: settings,
          workspaceIndex: workspaceIndex,
          launcherIndex: launcherIdx,
          onBack: { withAnimation(.easeInOut(duration: 0.2)) { editingLauncherIndex = nil } }
        )
        .transition(.move(edge: .trailing))
      } else {
        workspaceContent
          .transition(.move(edge: .leading))
      }
    }
    .animation(.easeInOut(duration: 0.2), value: editingLauncherIndex)
  }

  private var workspaceContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Title bar
      HStack {
        Text("Configure Workspace")
          .font(.headline)
        Spacer()
        Button("Done") { onBack() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(16)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          // Name
          LabeledContent("Name") {
            TextField("Workspace name", text: $settings.workspaces[workspaceIndex].name)
              .textFieldStyle(.roundedBorder)
          }

          // Path
          LabeledContent("Project Path") {
            HStack {
              TextField(
                "~/Projects/...",
                text: Binding(
                  get: { settings.workspaces[workspaceIndex].path ?? "" },
                  set: { settings.workspaces[workspaceIndex].path = $0.isEmpty ? nil : $0 }
                )
              )
              .textFieldStyle(.roundedBorder)

              Button("Browse...") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                  settings.workspaces[workspaceIndex].path = url.path
                }
              }
            }
          }

          Divider()

          // Launchers
          Text("App Launchers")
            .font(.subheadline)
            .foregroundStyle(.secondary)

          ForEach(
            Array(settings.workspaces[workspaceIndex].launchers.enumerated()), id: \.element.id
          ) { launcherIdx, launcher in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(launcher.type.label)
                  .font(.callout.weight(.medium))
                if !launcher.appName.isEmpty {
                  Text(launcher.appName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }

              Spacer()

              Button {
                settings.workspaces[workspaceIndex].launchers.removeAll { $0.id == launcher.id }
              } label: {
                Image(systemName: "minus.circle.fill")
                  .foregroundStyle(.red)
              }
              .buttonStyle(.plain)

              Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
                .font(.caption)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
              withAnimation(.easeInOut(duration: 0.2)) {
                editingLauncherIndex = launcherIdx
              }
            }

            Divider()
          }

          Menu("Add Launcher") {
            ForEach(LauncherTemplate.allCases) { template in
              Button(template.label) {
                let launcher = template.launcher
                settings.workspaces[workspaceIndex].launchers.append(launcher)
                let newIdx = settings.workspaces[workspaceIndex].launchers.count - 1
                withAnimation(.easeInOut(duration: 0.2)) {
                  editingLauncherIndex = newIdx
                }
              }
            }
          }
          .menuStyle(.borderlessButton)
        }
        .padding(16)
      }
    }
  }
}

// MARK: - Launcher Detail (Slide-in)

struct LauncherDetailView: View {
  @ObservedObject var settings: AppSettings
  let workspaceIndex: Int
  let launcherIndex: Int
  let onBack: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Back breadcrumb + title
      HStack {
        Button(action: onBack) {
          HStack(spacing: 4) {
            Image(systemName: "chevron.left")
              .font(.caption)
            Text(
              settings.workspaces[workspaceIndex].name.isEmpty
                ? "Workspace" : settings.workspaces[workspaceIndex].name
            )
            .font(.callout)
          }
          .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)

        Spacer()
      }
      .padding(16)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          let launcher = settings.workspaces[workspaceIndex].launchers[launcherIndex]

          Text(launcher.type.label)
            .font(.headline)

          HStack(spacing: 16) {
            // Only show Profile field if the command uses $PROFILE
            if launcher.command.contains("$PROFILE") || launcher.command.contains("${PROFILE}") {
              VStack(alignment: .leading, spacing: 2) {
                Text("Profile").font(.caption).foregroundStyle(.secondary)
                TextField(
                  "$NAME",
                  text: $settings.workspaces[workspaceIndex].launchers[launcherIndex].label
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
              }
            }

            VStack(alignment: .leading, spacing: 2) {
              Text("App Name").font(.caption).foregroundStyle(.secondary)
              TextField(
                "e.g. Safari",
                text: $settings.workspaces[workspaceIndex].launchers[launcherIndex].appName
              )
              .textFieldStyle(.roundedBorder)
              .frame(width: 160)
            }
          }

          VStack(alignment: .leading, spacing: 2) {
            Text("Command").font(.caption).foregroundStyle(.secondary)
            TextEditor(
              text: $settings.workspaces[workspaceIndex].launchers[launcherIndex].command
            )
            .font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, minHeight: 150)
            .overlay(
              RoundedRectangle(cornerRadius: 5)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
          }
        }
        .padding(16)
      }
    }
  }
}
