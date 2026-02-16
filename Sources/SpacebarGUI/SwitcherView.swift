import SpacebarGUILib
import SwiftUI

struct SwitcherView: View {
  @ObservedObject var viewModel: SwitcherViewModel
  @ObservedObject var appSettings: AppSettings

  private var preferredColorScheme: ColorScheme? {
    switch appSettings.colorScheme {
    case .auto: nil
    case .light: .light
    case .dark: .dark
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(viewModel.filteredSections) { section in
        sectionContent(section)
      }
      settingsRow
    }
    .padding(.top, 10)
    .padding(.bottom, 10)
    .padding(.leading, 10)
    .fixedSize()
    .background(
      ZStack {
        // Vibrancy blur — fades with opacity setting
        VibrancyBackground(opacity: appSettings.backgroundOpacity)
        // Solid backing — ensures no bleed-through at 100%
        Color(nsColor: .controlBackgroundColor)
          .opacity(appSettings.backgroundOpacity)
      }
    )
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .preferredColorScheme(preferredColorScheme)
  }

  private var settingsRow: some View {
    let gearSize = CGFloat(round(appSettings.textSize * 14.0 / 13.0))
    return HStack(spacing: 8) {
      Spacer()
        .frame(width: 110)
      Image(systemName: "gearshape")
        .resizable()
        .frame(width: gearSize, height: gearSize)
        .foregroundStyle(.secondary)
      Text("Settings")
        .font(.system(size: CGFloat(appSettings.textSize)))
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 1)
    .padding(.horizontal, 10)
    .padding(.top, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      viewModel.settingsSelected
        ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.8))
        : nil
    )
    .contentShape(Rectangle())
  }

  private func sectionContent(_ section: SwitcherSection) -> some View {
    Section {
      ForEach(section.windows) { row in
        SwitcherRowView(
          row: row,
          isSelected: viewModel.selectedRowID == row.id,
          showAppIcon: appSettings.showAppIcons,
          textSize: CGFloat(appSettings.textSize),
          iconSize: appSettings.iconSize
        )
        .id(row.id)
        .onTapGesture {
          viewModel.selectedRowID = row.id
          viewModel.activateSelected()
        }
      }
    } header: {
      SectionHeaderView(
        label: section.label,
        isCurrent: section.isCurrent,
        showCurrentBadge: appSettings.showCurrentBadge,
        textSize: CGFloat(appSettings.textSize)
      )
    }
  }
}

// MARK: - Vibrancy Background

struct VibrancyBackground: NSViewRepresentable {
  var opacity: Double = 1.0

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    view.alphaValue = CGFloat(opacity)
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
    nsView.alphaValue = CGFloat(opacity)
  }
}
