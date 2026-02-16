import SpacebarGUILib
import SwiftUI

struct SwitcherView: View {
  @ObservedObject var viewModel: SwitcherViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(viewModel.filteredSections) { section in
        sectionContent(section)
      }
    }
    .padding(.top, 10)
    .padding(.bottom, 10)
    .padding(.leading, 10)
    .fixedSize()
    .background(VibrancyBackground())
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  private func sectionContent(_ section: SwitcherSection) -> some View {
    Section {
      ForEach(section.windows) { row in
        SwitcherRowView(
          row: row,
          isSelected: viewModel.selectedRowID == row.id
        )
        .id(row.id)
        .onTapGesture {
          viewModel.selectedRowID = row.id
          viewModel.activateSelected()
        }
      }
    } header: {
      SectionHeaderView(label: section.label, isCurrent: section.isCurrent)
    }
  }
}

// MARK: - Vibrancy Background

struct VibrancyBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
