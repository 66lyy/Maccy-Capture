import SwiftUI

struct SearchFieldView: View {
  var placeholder: LocalizedStringKey
  @Binding var query: String
  var isFocused = false

  @Environment(AppState.self) private var appState
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      TextField(placeholder, text: $query)
        .disableAutocorrection(true)
        .lineLimit(1)
        .textFieldStyle(.plain)
        .onSubmit {
          appState.select(flags: .currentModifierFlags)
        }

      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 12))
            .frame(width: 18, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(Text("search_clear_accessibility_label"))
      }
    }
    .padding(.horizontal, 8)
    .frame(height: 28)
    .liquidGlass(in: Capsule(), interactive: true) {
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.secondary.opacity(0.09))
        .strokeBorder(isFocused ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.18))
    }
    .overlay {
      if isFocused, LiquidGlass.isActive(reduceTransparency: reduceTransparency) {
        Capsule().strokeBorder(Color.accentColor.opacity(0.45)).allowsHitTesting(false)
      }
    }
  }
}

#Preview {
  return List {
    SearchFieldView(placeholder: "search_placeholder", query: .constant(""))
    SearchFieldView(placeholder: "search_placeholder", query: .constant("search"))
  }
  .frame(width: 300)
  .environment(\.locale, .init(identifier: "en"))
}
