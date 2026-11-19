import Defaults
import SwiftUI

struct IgnorePasteboardTypesSettingsView: View {
  @Default(.ignoredPasteboardTypes) private var ignoredPasteboardTypes

  @FocusState private var focus: String.ID?
  @State private var edit = ""
  @State private var selection = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      List(selection: $selection) {
        ForEach(ignoredPasteboardTypes.sorted()) { type in
          TextField("", text: Binding(
            get: { type },
            set: {
              guard !$0.isEmpty, type != $0 else { return }
              edit = $0
            })
          )
          .onSubmit {
            remove(type)
            ignoredPasteboardTypes.insert(edit)
          }
          .focused($focus, equals: type)
        }
      }
      .ignoreRulesList(isEmpty: ignoredPasteboardTypes.isEmpty)
      .onDeleteCommand {
        remove(selection)
      }

      HStack {
        ControlGroup {
          Button("", systemImage: "plus") {
            ignoredPasteboardTypes.insert("xxx.yyy.zzz")
            focus = "xxx.yyy.zzz"
          }
          .accessibilityLabel(Text("AddIgnoreRule", tableName: "IgnoreSettings"))
          Button("", systemImage: "minus") {
            remove(selection)
          }
          .disabled(!ignoredPasteboardTypes.contains(selection))
          .accessibilityLabel(Text("RemoveIgnoreRule", tableName: "IgnoreSettings"))
        }
        .frame(width: 50)

        Spacer()

        Button {
          Defaults.reset(.ignoredPasteboardTypes)
        } label: {
          Text("IgnoredPasteboardTypesReset", tableName: "IgnoreSettings")
        }
      }

      Text("IgnoredPasteboardTypesDescription", tableName: "IgnoreSettings")
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.secondary)
    }
  }

  private func remove(_ type: String?) {
    guard let type else { return }

    ignoredPasteboardTypes.remove(type)
  }
}

#Preview {
  IgnorePasteboardTypesSettingsView()
    .environment(\.locale, .init(identifier: "en"))
}
