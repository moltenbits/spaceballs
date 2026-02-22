import Foundation

// MARK: - Enums

public enum AppColorScheme: String, CaseIterable, Identifiable {
  case auto
  case light
  case dark

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .auto: "Auto"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
}

public enum PanelDisplay: String, CaseIterable, Identifiable {
  case active
  case primary
  case all

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .active: "Active"
    case .primary: "Primary"
    case .all: "All"
    }
  }

  public var description: String {
    switch self {
    case .active: "Display with keyboard focus"
    case .primary: "Display with the menu bar"
    case .all: "Show on every connected display"
    }
  }
}

// MARK: - Settings Store

public final class AppSettings: ObservableObject {
  private let defaults: UserDefaults

  @Published public var showAppIcons: Bool {
    didSet { defaults.set(showAppIcons, forKey: "showAppIcons") }
  }

  @Published public var showCurrentBadge: Bool {
    didSet { defaults.set(showCurrentBadge, forKey: "showCurrentBadge") }
  }

  @Published public var colorScheme: AppColorScheme {
    didSet { defaults.set(colorScheme.rawValue, forKey: "colorScheme") }
  }

  @Published public var textSize: Double {
    didSet { defaults.set(textSize, forKey: "textSize") }
  }

  @Published public var backgroundOpacity: Double {
    didSet { defaults.set(backgroundOpacity, forKey: "backgroundOpacity") }
  }

  @Published public var panelDisplay: PanelDisplay {
    didSet { defaults.set(panelDisplay.rawValue, forKey: "panelDisplay") }
  }

  @Published public var filterSpacesByDisplay: Bool {
    didSet { defaults.set(filterSpacesByDisplay, forKey: "filterSpacesByDisplay") }
  }

  @Published public var showDisplayBadge: Bool {
    didSet { defaults.set(showDisplayBadge, forKey: "showDisplayBadge") }
  }

  @Published public var showEmptySpaces: Bool {
    didSet { defaults.set(showEmptySpaces, forKey: "showEmptySpaces") }
  }

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults

    defaults.register(defaults: [
      "showAppIcons": true,
      "showCurrentBadge": true,
      "colorScheme": AppColorScheme.auto.rawValue,
      "textSize": 13.0,
      "backgroundOpacity": 1.0,
      "panelDisplay": PanelDisplay.active.rawValue,
      "filterSpacesByDisplay": false,
      "showDisplayBadge": true,
      "showEmptySpaces": true,
    ])

    self.showAppIcons = defaults.bool(forKey: "showAppIcons")
    self.showCurrentBadge = defaults.bool(forKey: "showCurrentBadge")
    self.colorScheme =
      AppColorScheme(rawValue: defaults.string(forKey: "colorScheme") ?? "") ?? .auto
    self.textSize = defaults.double(forKey: "textSize")
    self.backgroundOpacity = defaults.double(forKey: "backgroundOpacity")
    self.panelDisplay =
      PanelDisplay(rawValue: defaults.string(forKey: "panelDisplay") ?? "") ?? .active
    self.filterSpacesByDisplay = defaults.bool(forKey: "filterSpacesByDisplay")
    self.showDisplayBadge = defaults.bool(forKey: "showDisplayBadge")
    self.showEmptySpaces = defaults.bool(forKey: "showEmptySpaces")
  }

  /// Icon size proportional to text size (20px at 13pt text).
  public var iconSize: CGFloat {
    CGFloat(round(textSize * 20.0 / 13.0))
  }
}
