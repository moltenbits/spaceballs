import SpaceballsGUILib
import SwiftUI

struct ShortcutsPane: View {
  @ObservedObject var settings: AppSettings

  private var currentConflicts: [(ShortcutAction, ShortcutAction)] {
    settings.keyBindings.conflicts()
  }

  private var generalActions: [ShortcutAction] {
    ShortcutAction.allCases.filter { !$0.isDisplayShortcut }
  }

  private var displayActions: [ShortcutAction] {
    ShortcutAction.allCases.filter { $0.isDisplayShortcut }
  }

  var body: some View {
    Form {
      Section("Keyboard Shortcuts") {
        Text("All shortcuts use the ⌘ (Cmd) modifier.")
          .font(.caption)
          .foregroundStyle(.secondary)

        ForEach(generalActions) { action in
          shortcutRow(for: action)
        }
      }

      Section("Display Cycling") {
        Text("Requires \"Only show current display's spaces\" in Appearance.")
          .font(.caption)
          .foregroundStyle(.secondary)

        ForEach(displayActions) { action in
          shortcutRow(for: action)
            .disabled(!settings.filterSpacesByDisplay)
        }
      }

      if !currentConflicts.isEmpty {
        Section {
          ForEach(currentConflicts, id: \.0) { first, second in
            Label(
              "\(first.label) and \(second.label) use the same key",
              systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
            .font(.caption)
          }
        }
      }

      Section {
        Button("Restore Defaults") {
          settings.keyBindings = KeyBindings()
        }
        .disabled(settings.keyBindings == KeyBindings())
      }
    }
    .formStyle(.grouped)
  }

  private func shortcutRow(for action: ShortcutAction) -> some View {
    LabeledContent {
      KeyRecorderView(
        keyCode: shortcutBinding(for: action),
        isRecording: $settings.isRecordingShortcut
      )
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(action.label)
        Text(action.description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func shortcutBinding(for action: ShortcutAction) -> Binding<UInt16> {
    Binding(
      get: { settings.keyBindings[action] },
      set: { settings.keyBindings[action] = $0 }
    )
  }
}
