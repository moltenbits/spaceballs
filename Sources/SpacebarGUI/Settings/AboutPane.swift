import SwiftUI

struct AboutPane: View {
  private var version: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
  }

  private var build: String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
  }

  var body: some View {
    VStack(spacing: 12) {
      Spacer()

      Image(systemName: "command")
        .font(.system(size: 48, weight: .thin))
        .foregroundStyle(.secondary)

      Text("Spacebar")
        .font(.title)
        .fontWeight(.semibold)

      Text("Version \(version) (\(build))")
        .font(.caption)
        .foregroundStyle(.secondary)

      Text("Built by MoltenBits")
        .font(.caption)
        .foregroundStyle(.tertiary)

      Spacer()
    }
    .frame(maxWidth: .infinity)
  }
}
