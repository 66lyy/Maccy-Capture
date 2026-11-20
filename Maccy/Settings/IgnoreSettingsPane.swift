import SwiftUI

struct IgnoreSettingsPane: View {
  var onLayout: PreferencesView.LayoutObserver?
  @State private var selection = Category.applications

  private enum Category: String, CaseIterable {
    case applications, pasteboardTypes, regexp

    var title: Text {
      switch self {
      case .applications: Text("ApplicationsTab", tableName: "IgnoreSettings")
      case .pasteboardTypes: Text("PasteboardTypesTab", tableName: "IgnoreSettings")
      case .regexp: Text("RegexpTab", tableName: "IgnoreSettings")
      }
    }

    var symbol: String {
      switch self {
      case .applications: "square.grid.2x2"
      case .pasteboardTypes: "clipboard"
      case .regexp: "character.textbox"
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      GlassGroup {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 6) {
            ForEach(Category.allCases, id: \.self) { category in
              categoryButton(category, allowsWrapping: false)
            }
          }
          VStack(spacing: 4) {
            ForEach(Category.allCases, id: \.self) { category in
              categoryButton(category, allowsWrapping: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
      .padding(4)
      .liquidGlass(in: .rect(cornerRadius: 12)) {
        RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.045))
      }

      PreferencesGroup(title: selection.title, symbol: selection.symbol) {
        Group {
          switch selection {
          case .applications: IgnoreApplicationsSettingsView()
          case .pasteboardTypes: IgnorePasteboardTypesSettingsView()
          case .regexp: IgnoreRegexpsSettingsView()
          }
        }
        .padding(.vertical, 14)
      }
    }
  }

  private func categoryButton(_ category: Category, allowsWrapping: Bool) -> some View {
    let isSelected = selection == category
    return Button {
      selection = category
    } label: {
      category.title
        .font(.subheadline.weight(.semibold))
        .fixedSize(horizontal: !allowsWrapping, vertical: true)
        .reportPreferencesLayout("ignore.category.\(category.rawValue)", to: onLayout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: allowsWrapping ? .infinity : nil, alignment: .leading)
        .modifier(GlassSelection(isSelected: isSelected, cornerRadius: 8, fallbackOpacity: 0.18))
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

extension View {
  func ignoreRulesList(isEmpty: Bool) -> some View {
    listStyle(.plain)
      .modifier(NeutralListSelection())
      .scrollContentBackground(.hidden)
      .frame(height: isEmpty ? 76 : 184)
      .background(.primary.opacity(0.04), in: .rect(cornerRadius: 8))
      .clipShape(.rect(cornerRadius: 8))
      .overlay {
        if isEmpty {
          Label {
            Text("NoIgnoreRules", tableName: "IgnoreSettings")
          } icon: {
            Image(systemName: "list.bullet")
          }
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .allowsHitTesting(false)
        }
      }
  }
}

#Preview {
  IgnoreSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}

// Keeps native list selection neutral on clear glass instead of the saturated accent color.
private struct NeutralListSelection: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    content.tint(LiquidGlass.isActive(reduceTransparency: reduceTransparency) ? Color(nsColor: .systemGray) : nil)
  }
}
