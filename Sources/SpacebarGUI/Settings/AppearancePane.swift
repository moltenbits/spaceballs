import SpacebarGUILib
import SwiftUI

struct AppearancePane: View {
  @ObservedObject var settings: AppSettings

  var body: some View {
    Form {
      Section("Color") {
        Picker("Color scheme", selection: $settings.colorScheme) {
          ForEach(AppColorScheme.allCases) { scheme in
            Text(scheme.label).tag(scheme)
          }
        }
        .pickerStyle(.segmented)

        LabeledContent("Background opacity") {
          HStack {
            Slider(value: $settings.backgroundOpacity, in: 0.2...1.0)
            Text("\(Int(settings.backgroundOpacity * 100))%")
              .monospacedDigit()
              .frame(width: 36, alignment: .trailing)
          }
        }
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
        Toggle("Show current space badge", isOn: $settings.showCurrentBadge)
        Toggle("Show display name badge", isOn: $settings.showDisplayBadge)
          .disabled(settings.filterSpacesByDisplay)
      }

      Section("Display") {
        Picker("Show panel on", selection: $settings.panelDisplay) {
          ForEach(PanelDisplay.allCases) { display in
            Text(display.label).tag(display)
          }
        }
        .pickerStyle(.radioGroup)
        .disabled(settings.filterSpacesByDisplay)

        Text(
          settings.filterSpacesByDisplay
            ? "Forced to active display when filtering by display"
            : settings.panelDisplay.description
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Toggle("Only show current display's spaces", isOn: $settings.filterSpacesByDisplay)
      }
    }
    .formStyle(.grouped)
  }
}
