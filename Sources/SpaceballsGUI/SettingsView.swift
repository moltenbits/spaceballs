import SpaceballsCore
import SpaceballsGUILib
import SwiftUI

// MARK: - Pane Enum

enum SettingsPane: String, CaseIterable, Identifiable {
  case general
  case appearance
  case workspaces
  case resize
  case shortcuts
  case timing
  case excluded
  case diagnostics
  case about

  var id: String { rawValue }

  var label: String {
    switch self {
    case .general: "General"
    case .workspaces: "Workspaces"
    case .shortcuts: "Shortcuts"
    case .timing: "Timing"
    case .resize: "Resize"
    case .excluded: "Excluded"
    case .appearance: "Appearance"
    case .diagnostics: "Diagnostics"
    case .about: "About"
    }
  }

  var icon: String {
    switch self {
    case .general: "gearshape"
    case .workspaces: "square.grid.2x2"
    case .shortcuts: "keyboard"
    case .timing: "timer"
    case .resize: "rectangle.split.3x3"
    case .excluded: "eye.slash"
    case .appearance: "paintbrush"
    case .diagnostics: "stethoscope"
    case .about: "info.circle"
    }
  }
}

// MARK: - Settings View

struct SettingsView: View {
  let spaceManager: SpaceManager
  let spaceNameStore: SpaceNameStoring
  @ObservedObject var appSettings: AppSettings
  let windowLayoutStore: WindowLayoutStore

  @State private var selectedPane: SettingsPane = .general

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider()
      content
        .frame(maxHeight: .infinity, alignment: .top)
    }
    .frame(width: 600)
  }

  // MARK: - Sidebar

  private var sidebar: some View {
    List(SettingsPane.allCases, selection: $selectedPane) { pane in
      Label(pane.label, systemImage: pane.icon)
        .tag(pane)
    }
    .listStyle(.sidebar)
    .frame(width: 170)
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    switch selectedPane {
    case .general:
      GeneralPane(settings: appSettings)
    case .workspaces:
      WorkspacesPane(settings: appSettings)
    case .shortcuts:
      ShortcutsPane(settings: appSettings)
    case .timing:
      TimingPane(settings: appSettings)
    case .resize:
      ResizePane(settings: appSettings)
    case .excluded:
      ExcludedAppsPane(settings: appSettings)
    case .appearance:
      AppearancePane(settings: appSettings, windowLayoutStore: windowLayoutStore)
    case .diagnostics:
      DiagnosticsPane(settings: appSettings, spaceManager: spaceManager)
    case .about:
      AboutPane()
    }
  }
}
