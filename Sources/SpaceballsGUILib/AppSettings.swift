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

public enum SpaceSortOrder: String, CaseIterable, Identifiable {
  case mru
  case desktopNumber
  case alphabetical

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .mru: "Most Recently Active"
    case .desktopNumber: "Desktop Ordinal"
    case .alphabetical: "Desktop Name"
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

  @Published public var spaceSortOrder: SpaceSortOrder {
    didSet { defaults.set(spaceSortOrder.rawValue, forKey: "spaceSortOrder") }
  }

  @Published public var workspaces: [WorkspaceConfig] {
    didSet {
      if let data = try? JSONEncoder().encode(workspaces) {
        defaults.set(data, forKey: "workspaces")
      }
    }
  }

  /// Backward-compatible accessor for space names only.
  public var customSpaceNames: [String] {
    get { workspaces.map(\.name) }
    set {
      // Update names in-place, preserving launchers; add/remove as needed
      var updated = workspaces
      while updated.count < newValue.count {
        updated.append(WorkspaceConfig())
      }
      while updated.count > newValue.count {
        updated.removeLast()
      }
      for i in newValue.indices {
        updated[i].name = newValue[i]
      }
      workspaces = updated
    }
  }

  @Published public var excludedBundleIDs: Set<String> {
    didSet { defaults.set(Array(excludedBundleIDs), forKey: "excludedBundleIDs") }
  }

  @Published public var keyBindings: KeyBindings {
    didSet {
      if let data = try? JSONEncoder().encode(keyBindings) {
        defaults.set(data, forKey: "keyBindings")
      }
    }
  }

  /// Transient flag — not persisted. Disables the event tap while recording a shortcut.
  @Published public var isRecordingShortcut = false

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults

    defaults.register(defaults: [
      "showAppIcons": true,
      "showCurrentBadge": true,
      "colorScheme": AppColorScheme.auto.rawValue,
      "textSize": 13.0,
      "panelDisplay": PanelDisplay.active.rawValue,
      "filterSpacesByDisplay": false,
      "showDisplayBadge": true,
      "showEmptySpaces": true,
      "spaceSortOrder": SpaceSortOrder.mru.rawValue,
    ])

    self.showAppIcons = defaults.bool(forKey: "showAppIcons")
    self.showCurrentBadge = defaults.bool(forKey: "showCurrentBadge")
    self.colorScheme =
      AppColorScheme(rawValue: defaults.string(forKey: "colorScheme") ?? "") ?? .auto
    self.textSize = defaults.double(forKey: "textSize")
    self.panelDisplay =
      PanelDisplay(rawValue: defaults.string(forKey: "panelDisplay") ?? "") ?? .active
    self.filterSpacesByDisplay = defaults.bool(forKey: "filterSpacesByDisplay")
    self.showDisplayBadge = defaults.bool(forKey: "showDisplayBadge")
    self.showEmptySpaces = defaults.bool(forKey: "showEmptySpaces")
    self.spaceSortOrder =
      SpaceSortOrder(rawValue: defaults.string(forKey: "spaceSortOrder") ?? "") ?? .mru

    // Load workspaces (with migration from old customSpaceNames format)
    if let data = defaults.data(forKey: "workspaces"),
      let decoded = try? JSONDecoder().decode([WorkspaceConfig].self, from: data)
    {
      self.workspaces = decoded
    } else if let oldNames = defaults.stringArray(forKey: "customSpaceNames"), !oldNames.isEmpty {
      let migrated = oldNames.map { WorkspaceConfig(name: $0) }
      self.workspaces = migrated
      // didSet doesn't fire during init, so persist explicitly
      if let data = try? JSONEncoder().encode(migrated) {
        defaults.set(data, forKey: "workspaces")
      }
      defaults.removeObject(forKey: "customSpaceNames")
    } else {
      self.workspaces = []
    }

    self.excludedBundleIDs = Set(defaults.stringArray(forKey: "excludedBundleIDs") ?? [])

    if let data = defaults.data(forKey: "keyBindings"),
      let decoded = try? JSONDecoder().decode(KeyBindings.self, from: data)
    {
      self.keyBindings = decoded
    } else {
      self.keyBindings = KeyBindings()
    }
  }

  /// Icon size proportional to text size (20px at 13pt text).
  public var iconSize: CGFloat {
    CGFloat(round(textSize * 20.0 / 13.0))
  }

}
