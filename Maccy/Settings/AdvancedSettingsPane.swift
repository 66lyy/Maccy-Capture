import SwiftUI
import Defaults

struct AdvancedSettingsPane: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      PreferencesGroup(title: Text("TurnOff", tableName: "AdvancedSettings"), symbol: "pause.circle") {
        VStack(alignment: .leading) {
          Defaults.Toggle(key: .ignoreEvents) {
            Text("TurnOff", tableName: "AdvancedSettings")
          }
          Text("TurnOffDescription", tableName: "AdvancedSettings")
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.secondary)
            .controlSize(.small)
          Text("TurnOffShellScript", tableName: "AdvancedSettings")
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.secondary)
            .font(.system(size: 11, design: .monospaced))
            .controlSize(.small)
            .padding(.vertical, 2)
            .textSelection(.enabled)
          Text("TurnOffViaMenuIconDescription", tableName: "AdvancedSettings")
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.secondary)
            .controlSize(.small)
          Text("TurnOffNextShellScript", tableName: "AdvancedSettings")
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.secondary)
            .font(.system(size: 11, design: .monospaced))
            .controlSize(.small)
            .padding(.vertical, 2)
            .textSelection(.enabled)
        }
        .padding(.vertical, 12)
      }

      PreferencesGroup(title: Text("Title", tableName: "StorageSettings"), symbol: "trash") {
        VStack(alignment: .leading, spacing: 8) {
          Defaults.Toggle(key: .clearOnQuit) {
            Text("ClearHistoryOnQuit", tableName: "AdvancedSettings")
          }.help(Text("ClearHistoryOnQuitTooltip", tableName: "AdvancedSettings"))

          Defaults.Toggle(key: .clearSystemClipboard) {
            Text("ClearSystemClipboard", tableName: "AdvancedSettings")
          }.help(Text("ClearSystemClipboardTooltip", tableName: "AdvancedSettings"))
        }
        .padding(.vertical, 12)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

#Preview {
  AdvancedSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
