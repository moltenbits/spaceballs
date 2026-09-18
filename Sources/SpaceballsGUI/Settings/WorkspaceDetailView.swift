import AppKit
import SpaceballsCore
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
                Text(
                  launcher.steps.count == 1
                    ? launcher.steps[0].type.label : "\(launcher.steps.count)-step launcher"
                )
                .font(.callout.weight(.medium))
                if !launcher.appName.isEmpty {
                  Text(launcher.appName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if launcher.steps.count > 1 {
                  Text(launcher.steps.map { $0.type.label }.joined(separator: " → "))
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
                var launcher = template.launcher
                if template == .genericOpen || template == .genericLaunchServices {
                  guard let application = WorkspaceApplicationPicker.choose() else { return }
                  launcher.selectApplication(application)
                }
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
          applicationSelection
          if simpleApplicationStep != nil {
            DisclosureGroup("Advanced") {
              pipelineEditor
                .padding(.top, 8)
            }
          } else {
            pipelineEditor
          }
        }
        .padding(16)
      }
    }
  }

  /// The single Open App or Launch Services step of a plain app launcher, whose
  /// pipeline controls belong under Advanced.
  private var simpleApplicationStep: WorkspaceLauncherStep? {
    let steps = settings.workspaces[workspaceIndex].launchers[launcherIndex].steps
    guard steps.count == 1 else { return nil }
    switch steps[0].action {
    case .openApplication, .launchServices: return steps[0]
    case .shell, .appleScript: return nil
    }
  }

  private var applicationSelection: some View {
    let launcher = settings.workspaces[workspaceIndex].launchers[launcherIndex]
    let step = simpleApplicationStep
    let target = if case .openApplication(let value)? = step?.action { value } else { "" }
    let applicationURL =
      target.hasPrefix("/")
      ? URL(fileURLWithPath: target)
      : NSWorkspace.shared.urlForApplication(withBundleIdentifier: launcher.bundleID)
    let name = launcher.appName.isEmpty ? target : launcher.appName
    return HStack(spacing: 12) {
      if let applicationURL {
        Image(nsImage: NSWorkspace.shared.icon(forFile: applicationURL.path))
          .resizable()
          .frame(width: 40, height: 40)
      } else {
        Image(systemName: "app")
          .font(.largeTitle)
          .foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("Application").font(.caption).foregroundStyle(.secondary)
        Text(name.isEmpty ? "No application chosen" : name)
          .font(.headline)
          .foregroundStyle(name.isEmpty ? .secondary : .primary)
        if !launcher.bundleID.isEmpty {
          Text(launcher.bundleID)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        if launcher.hasAmbiguousOpenSteps {
          Text(
            "Choosing an app updates only the Open App steps that launched the previous app. Check the other steps under the pipeline."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      Spacer()
      if launcher.hasApplication, launcher.applicationIsOptional {
        Button("Clear") {
          settings.workspaces[workspaceIndex].launchers[launcherIndex].clearApplication()
        }
        .help(
          "Run this launcher without an associated app: it always executes and skips window placement."
        )
      }
      Button("Choose Application…") {
        guard let application = WorkspaceApplicationPicker.choose() else { return }
        settings.workspaces[workspaceIndex].launchers[launcherIndex]
          .selectApplication(application)
      }
    }
    .padding(.vertical, 8)
  }

  private var pipelineEditor: some View {
    VStack(alignment: .leading, spacing: 12) {
      let launcher = settings.workspaces[workspaceIndex].launchers[launcherIndex]

      Text("Launcher Pipeline")
        .font(.headline)

      Text(
        "Steps run from top to bottom. Steps that wait stop the pipeline on failure; background shell steps continue immediately. Use $PATH, $NAME, and $PROFILE in configurable values."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Toggle(
        "Allow relocating an existing window",
        isOn: $settings.workspaces[workspaceIndex].launchers[launcherIndex].allowsExistingWindow
      )
      Text(
        "Turn off when this launcher must create a new window, such as the iTerm and Safari templates."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if launcher.usesProfileVariable {
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

      Divider()

      ForEach(Array(launcher.steps.enumerated()), id: \.element.id) { stepIndex, step in
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("\(stepIndex + 1). \(step.type.label)")
              .font(.callout.weight(.semibold))
            Spacer()
            Button {
              moveStep(from: stepIndex, by: -1)
            } label: {
              Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(stepIndex == 0)
            .help("Move step earlier")

            Button {
              moveStep(from: stepIndex, by: 1)
            } label: {
              Image(systemName: "arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(stepIndex == launcher.steps.count - 1)
            .help("Move step later")

            Button {
              removeStep(at: stepIndex)
            } label: {
              Image(systemName: "minus.circle.fill")
                .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .disabled(launcher.steps.count == 1)
            .help(
              launcher.steps.count == 1
                ? "A launcher must contain at least one step" : "Remove step")
          }

          LauncherStepEditor(
            step: $settings.workspaces[workspaceIndex].launchers[launcherIndex].steps[
              stepIndex],
            bundleID: launcher.bundleID
          )
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
      }

      Menu("Add Step") {
        ForEach(
          [
            WorkspaceLaunchType.launchServices, .applescript, .shell, .open,
          ]
        ) { type in
          Button(type.label) {
            settings.workspaces[workspaceIndex].launchers[launcherIndex].steps.append(
              WorkspaceLauncherStep(action: .empty(for: type)))
          }
        }
      }
      .menuStyle(.borderlessButton)
    }
  }

  private func moveStep(from index: Int, by offset: Int) {
    let destination = index + offset
    guard destination >= 0,
      destination < settings.workspaces[workspaceIndex].launchers[launcherIndex].steps.count
    else { return }
    settings.workspaces[workspaceIndex].launchers[launcherIndex].steps.swapAt(
      index, destination)
  }

  private func removeStep(at index: Int) {
    guard settings.workspaces[workspaceIndex].launchers[launcherIndex].steps.count > 1 else {
      return
    }
    settings.workspaces[workspaceIndex].launchers[launcherIndex].steps.remove(at: index)
  }
}

private struct LauncherStepEditor: View {
  @Binding var step: WorkspaceLauncherStep
  let bundleID: String

  var body: some View {
    switch step.action {
    case .launchServices:
      LaunchServicesStepEditor(
        configuration: launchServicesConfiguration, bundleID: bundleID)
    case .appleScript:
      commandEditor(
        title: "Script", text: stringValue(for: .applescript), minimumHeight: 140)
    case .shell:
      VStack(alignment: .leading, spacing: 8) {
        commandEditor(title: "Command", text: stringValue(for: .shell), minimumHeight: 100)
        Toggle("Wait for command to finish", isOn: shellWaitsForExit)
        Text(
          "Turn off for commands that stay running with the app. Later steps will start immediately, and command failures will not stop the pipeline."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    case .openApplication:
      VStack(alignment: .leading, spacing: 4) {
        Text("Application Name or Path").font(.caption).foregroundStyle(.secondary)
        TextField("e.g. Preview", text: stringValue(for: .open))
          .textFieldStyle(.roundedBorder)
      }
    }
  }

  private var launchServicesConfiguration: Binding<WorkspaceLaunchServicesConfiguration> {
    Binding(
      get: {
        guard case .launchServices(let configuration) = step.action else {
          return WorkspaceLaunchServicesConfiguration()
        }
        return configuration
      },
      set: { step.action = .launchServices($0) })
  }

  private func stringValue(for type: WorkspaceLaunchType) -> Binding<String> {
    Binding(
      get: {
        switch step.action {
        case .shell(let command, _): command
        case .appleScript(let source): source
        case .openApplication(let applicationName): applicationName
        case .launchServices: ""
        }
      },
      set: { value in
        switch type {
        case .shell: step.action = .shell(value, waitsForExit: shellWaitsForExit.wrappedValue)
        case .applescript: step.action = .appleScript(value)
        case .open: step.action = .openApplication(value)
        case .launchServices: break
        }
      })
  }

  private var shellWaitsForExit: Binding<Bool> {
    Binding(
      get: {
        guard case .shell(_, let waits) = step.action else { return true }
        return waits
      },
      set: { waits in
        guard case .shell(let command, _) = step.action else { return }
        step.action = .shell(command, waitsForExit: waits)
      })
  }

  private func commandEditor(
    title: String, text: Binding<String>, minimumHeight: CGFloat
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      TextEditor(text: text)
        .font(.system(.body, design: .monospaced))
        .frame(maxWidth: .infinity, minHeight: minimumHeight)
        .overlay(
          RoundedRectangle(cornerRadius: 5)
            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }
  }
}

private struct LaunchServicesStepEditor: View {
  @Binding var configuration: WorkspaceLaunchServicesConfiguration
  let bundleID: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Label(
          "Choose an application above before using this Launch Services step.",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Path or URL").font(.caption).foregroundStyle(.secondary)
        TextField("Optional — $PATH opens the workspace project", text: $configuration.target)
          .textFieldStyle(.roundedBorder)
        Text("Leave blank to launch the application without opening a resource.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Toggle(
        "Create a new application instance", isOn: $configuration.createsNewApplicationInstance)

      Toggle("Activate application", isOn: $configuration.activates)

      VStack(alignment: .leading, spacing: 4) {
        Text("Arguments").font(.caption).foregroundStyle(.secondary)
        TextEditor(text: argumentsText)
          .font(.system(.body, design: .monospaced))
          .frame(maxWidth: .infinity, minHeight: 70)
          .overlay(
            RoundedRectangle(cornerRadius: 5)
              .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
          )
        Text("Enter one argument per line.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Environment Variables").font(.caption).foregroundStyle(.secondary)
        ForEach(Array(configuration.environment.enumerated()), id: \.element.id) {
          index, variable in
          HStack {
            TextField("NAME", text: $configuration.environment[index].name)
              .textFieldStyle(.roundedBorder)
              .frame(width: 180)
            TextField("Value", text: $configuration.environment[index].value)
              .textFieldStyle(.roundedBorder)
            Button {
              configuration.environment.removeAll { $0.id == variable.id }
            } label: {
              Image(systemName: "minus.circle.fill")
                .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
          }
        }
        Button("Add Environment Variable") {
          configuration.environment.append(WorkspaceEnvironmentVariable())
        }
        .buttonStyle(.borderless)
      }

      if !configuration.arguments.isEmpty || !configuration.environment.isEmpty {
        Text(
          "Arguments and environment variables affect only a newly launched process. Enable New Application Instance to guarantee they are used when the app is already running."
        )
        .font(.caption)
        .foregroundStyle(
          configuration.createsNewApplicationInstance ? Color.secondary : Color.orange)
      }
    }
  }

  private var argumentsText: Binding<String> {
    Binding(
      get: { configuration.arguments.joined(separator: "\n") },
      set: { value in
        configuration.arguments =
          value.isEmpty
          ? [] : value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      })
  }
}
