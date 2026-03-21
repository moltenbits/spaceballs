import SpacebarGUILib
import SwiftUI

struct ExcludedAppsPane: View {
  @ObservedObject var settings: AppSettings

  var body: some View {
    AppFilterPane(
      title: "Excluded Apps",
      description: "Apps to hide from Spacebar.",
      policy: .regular,
      selectedBundleIDs: $settings.excludedBundleIDs
    )
  }
}
