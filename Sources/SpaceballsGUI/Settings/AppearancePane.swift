import SpaceballsCore
import SpaceballsGUILib
import SwiftUI

struct AppearancePane: View {
  @ObservedObject var settings: AppSettings
  let windowLayoutStore: WindowLayoutStore
  @State private var showClearConfirm = false

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
            Slider(value: $settings.textSize, in: 10...17, step: 1)
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

      Section("Sorting") {
        Picker("Sort spaces by", selection: $settings.spaceSortOrder) {
          ForEach(SpaceSortOrder.allCases) { order in
            Text(order.label).tag(order)
          }
        }
        .pickerStyle(.radioGroup)
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

      Section("Window Memory") {
        Toggle(
          "Remember window layouts per space and display",
          isOn: $settings.rememberWindowLayouts)
        Text(
          "When you resize a window via Spaceballs, its frame is saved for the current space and display. Switching that space to a different display restores each app's last layout for that display."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Button("Clear All Saved Layouts") {
          showClearConfirm = true
        }
        .confirmationDialog(
          "Clear all saved window layouts?",
          isPresented: $showClearConfirm
        ) {
          Button("Clear", role: .destructive) { windowLayoutStore.clearAll() }
          Button("Cancel", role: .cancel) {}
        }
      }
    }
    .formStyle(.grouped)
  }
}
