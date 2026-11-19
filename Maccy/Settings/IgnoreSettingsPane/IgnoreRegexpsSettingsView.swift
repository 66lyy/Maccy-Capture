import SwiftUI
import Defaults

struct IgnoreRegexpsSettingsView: View {
  @Default(.ignoreRegexp) private var ignoredRegexps

  @FocusState private var focus: String.ID?
  @State private var edit = ""
  @State private var selection = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      List(selection: $selection) {
        ForEach(ignoredRegexps) { regexp in
          TextField("", text: Binding(
            get: { regexp },
            set: {
              guard !$0.isEmpty, regexp != $0 else { return }
              edit = $0
            })
          ).onSubmit {
            remove(regexp)
            ignoredRegexps.append(edit)
          }.focused($focus, equals: regexp)
        }
      }
      .ignoreRulesList(isEmpty: ignoredRegexps.isEmpty)
      .onDeleteCommand {
        remove(selection)
      }

      ControlGroup {
        Button("", systemImage: "plus") {
          ignoredRegexps.append("^[a-zA-Z0-9]{50}$")
          focus = "^[a-zA-Z0-9]{50}$"
        }
        .accessibilityLabel(Text("AddIgnoreRule", tableName: "IgnoreSettings"))
        Button("", systemImage: "minus") {
          remove(selection)
        }
        .disabled(!ignoredRegexps.contains(selection))
        .accessibilityLabel(Text("RemoveIgnoreRule", tableName: "IgnoreSettings"))
      }
      .frame(width: 50)

      Text("IgnoredRegexpsDescription", tableName: "IgnoreSettings")
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.secondary)
    }
  }

  private func remove(_ regexp: String?) {
    guard let regexp else { return }

    ignoredRegexps.removeAll(where: { $0 == regexp })
  }
}

#Preview {
  IgnoreRegexpsSettingsView()
    .environment(\.locale, .init(identifier: "en"))
}
