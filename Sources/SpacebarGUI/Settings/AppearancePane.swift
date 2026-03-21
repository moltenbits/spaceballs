import SpacebarGUILib
import SwiftUI

struct AppearancePane: View {
  @ObservedObject var settings: AppSettings

  private var panelDisplayDescription: String {
    if settings.filterSpacesByDisplay {
      switch settings.panelDisplay {
      case .all:
        return "A panel on each display shows its own spaces"
      case .active, .primary:
        return "Use Cmd+← / Cmd+→ to cycle displays"
      }
    }
    return settings.panelDisplay.description
  }

  var body: some View {
    Form {
      Section("Color") {
        Picker("Color scheme", selection: $settings.colorScheme) {
          ForEach(AppColorScheme.allCases) { scheme in
            Text(scheme.label).tag(scheme)
          }
        }
        .pickerStyle(.segmented)
      }

      Section("Text") {
        LabeledContent("Text size") {
          HStack {
            Slider(value: $settings.textSize, in: 11...17, step: 1)
            Text("\(Int(settings.textSize))pt")
              .monospacedDigit()
              .frame(width: 32, alignment: .trailing)
          }
        }
        Text("Icons scale to match.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Elements") {
        Toggle("Show app icons", isOn: $settings.showAppIcons)
        Toggle("Show space number badge", isOn: $settings.showCurrentBadge)
        Toggle("Show display name badge", isOn: $settings.showDisplayBadge)
          .disabled(settings.filterSpacesByDisplay)
        Toggle("Show empty spaces", isOn: $settings.showEmptySpaces)
      }

      Section("Display") {
        Picker("Show panel on", selection: $settings.panelDisplay) {
          ForEach(PanelDisplay.allCases) { display in
            Text(display.label).tag(display)
          }
        }
        .pickerStyle(.radioGroup)

        Text(panelDisplayDescription)
          .font(.caption)
          .foregroundStyle(.secondary)

        Toggle("Only show current display's spaces", isOn: $settings.filterSpacesByDisplay)
      }
    }
    .formStyle(.grouped)
  }
}
