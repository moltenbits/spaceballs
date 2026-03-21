import SpacebarCore
import SpacebarGUILib
import SwiftUI

// MARK: - Pane Enum

enum SettingsPane: String, CaseIterable, Identifiable {
  case general
  case shortcuts
  case excluded
  case appearance
  case about

  var id: String { rawValue }

  var label: String {
    switch self {
    case .general: "General"
    case .shortcuts: "Shortcuts"
    case .excluded: "Excluded"
    case .appearance: "Appearance"
    case .about: "About"
    }
  }

  var icon: String {
    switch self {
    case .general: "gearshape"
    case .shortcuts: "keyboard"
    case .excluded: "eye.slash"
    case .appearance: "paintbrush"
    case .about: "info.circle"
    }
  }
}

// MARK: - Settings View

struct SettingsView: View {
  let spaceManager: SpaceManager
  let spaceNameStore: SpaceNameStoring
  @ObservedObject var appSettings: AppSettings

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
      GeneralPane()
    case .shortcuts:
      ShortcutsPane(settings: appSettings)
    case .excluded:
      ExcludedAppsPane(settings: appSettings)
    case .appearance:
      AppearancePane(settings: appSettings)
    case .about:
      AboutPane()
    }
  }
}
