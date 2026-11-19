import Defaults
import Sauce
import SwiftUI

struct FooterItemView: View {
  @Bindable var item: FooterItem
  @Environment(AppState.self) private var appState
  @Default(.scopedShortcuts) private var scopedShortcuts

  private var shortcuts: [KeyShortcut] {
    let action: ScopedShortcut
    switch item.title {
    case "clear": action = .clearHistory
    case "clear_all": action = .clearHistoryAll
    case "preferences": action = .openPreferences
    default: return item.shortcuts
    }
    guard let shortcut = ScopedShortcut.resolve(initial: action.initial, stored: scopedShortcuts[action.rawValue]),
          let key = Sauce.shared.key(for: shortcut.carbonKeyCode) else { return [] }
    return [KeyShortcut(key: key, modifierFlags: shortcut.modifiers)]
  }

  var body: some View {
    ConfirmationView(item: item) {
      ListItemView(
        id: item.id,
        selectionId: item.id,
        shortcuts: shortcuts,
        isSelected: item.isSelected,
        accessibilityLabel: NSLocalizedString(item.title, comment: "")
      ) {
        Text(LocalizedStringKey(item.title))
      }
    }
    .onHover { hovering in
      if hovering && appState.preview.state.isOpen {
        appState.preview.togglePreview()
      }
    }
  }
}
