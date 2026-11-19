import Defaults
import KeyboardShortcuts
import SwiftUI

struct ShortcutSettingsPane: View {
  @Default(.scopedShortcuts) private var scopedValues
  @State private var resetConflict: String?
  @State private var expandedScopes: Set<ShortcutScope> = []

  private static let clipboard: [RecordedAction] = [
    .init("Open", "OpenTooltip", "list.bullet.rectangle", .popup, .global),
    .init("Pin", "PinTooltip", "pin", .pin, .history),
    .init("Delete", "DeleteTooltip", "trash", .delete, .history),
    .init("ShowPreview", "ShowPreviewTooltip", "sidebar.right", .togglePreview, .history)
  ]

  private static let capture: [RecordedAction] = [
    .init("Screenshot", "ScreenshotMainHint", "display", .screenshot, .global),
    .init("ScreenshotSelection", "ScreenshotSelectionHint", "crop", .screenshotSelection, .global),
    .init("PinScreenshot", "ScreenshotPinHint", "pin", .pinScreenshot, .global),
    .init("PinClipboardImage", "ScreenshotClipboardHint", "photo.on.rectangle", .pinClipboardImage, .global)
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      clipboardGroup
      captureGroup
      inWindowGroup
    }
    .alert(
      Text("ShortcutResetConflict", tableName: "GeneralSettings"),
      isPresented: Binding(get: { resetConflict != nil }, set: { if !$0 { resetConflict = nil } }),
      presenting: resetConflict
    ) { _ in
    } message: { reason in
      Text(reason)
    }
  }

  private var clipboardGroup: some View {
    PreferencesGroup(title: Text("ShortcutClipboardSection", tableName: "GeneralSettings"), symbol: "clipboard") {
      recordedRows(Self.clipboard)
    }
  }

  private var captureGroup: some View {
    PreferencesGroup(title: Text("ScreenshotSection", tableName: "GeneralSettings"), symbol: "viewfinder") {
      recordedRows(Self.capture)
    }
  }

  private var inWindowGroup: some View {
    PreferencesGroup(title: Text("ShortcutInContext", tableName: "GeneralSettings"), symbol: "keyboard") {
      scopedGroup(.history, title: String(localized: "ShortcutHistoryActions", table: "GeneralSettings"))
      Divider()
      scopedGroup(.historyEditor, title: String(localized: "ShortcutHistoryEditor", table: "GeneralSettings"))
      Divider()
      scopedGroup(.capture, title: String(localized: "ShortcutCaptureActions", table: "GeneralSettings"))
      Divider()
      scopedGroup(.selection, title: String(localized: "ShortcutSelectionActions", table: "GeneralSettings"))
      Divider()
      scopedGroup(.annotation, title: String(localized: "ShortcutAnnotationActions", table: "GeneralSettings"))
      Divider()
      scopedGroup(.pinnedImage, title: String(localized: "ShortcutPinnedActions", table: "GeneralSettings"))
    }
  }

  @ViewBuilder private func recordedRows(_ actions: [RecordedAction]) -> some View {
    ForEach(actions) { action in
      if action.id != actions.first?.id { Divider() }
      recordedRow(action)
    }
  }

  private func recordedRow(_ action: RecordedAction) -> some View {
    shortcutRow(title: action.title, symbol: action.symbol) {
      KeyboardShortcuts.Recorder(for: action.name, onChange: { newShortcut in
        if action.name == .popup {
          let popup = AppState.shared.popup
          if newShortcut == nil {
            popup.deinitEventsMonitor()
          } else {
            popup.initEventsMonitor()
          }
        }
      })
      .shortcutValidation { validate($0, id: action.id, scope: action.scope) }
      .accessibilityLabel(Text(action.title))
    }
    .help(Text(LocalizedStringKey(action.detail), tableName: "GeneralSettings"))
  }

  private func scopedGroup(_ scope: ShortcutScope, title: String) -> some View {
    DisclosureGroup(isExpanded: Binding(
      get: { expandedScopes.contains(scope) },
      set: { expanded in
        if expanded { expandedScopes.insert(scope) } else { expandedScopes.remove(scope) }
      }
    )) {
      ForEach(ScopedShortcut.allCases.filter { $0.scope == scope }, id: \.self) { action in
        scopedRow(action)
      }
    } label: {
      Text(title)
    }
    .disclosureGroupStyle(ShortcutDisclosureStyle())
  }

  private func scopedRow(_ action: ScopedShortcut) -> some View {
    let detail = Text(String(
      localized: "ShortcutDefaultHint", defaultValue: "Default: \(action.initial.description)", table: "GeneralSettings"
    ))
    return shortcutRow(title: action.title, symbol: "keyboard", detail: detail) {
      KeyboardShortcuts.Recorder(shortcut: Binding(get: { action.current }, set: {
        action.set($0)
      }))
      .shortcutValidation { validate($0, id: action.rawValue, scope: action.scope) }
      .keyboardShortcutsConflictPolicy(.init(menuItem: .allow))
      .accessibilityLabel(Text(action.title))

      Button {
        reset(action)
      } label: {
        Image(systemName: "arrow.counterclockwise")
      }
      .accessibilityLabel(Text("ShortcutReset", tableName: "GeneralSettings"))
      .help(Text("ShortcutReset", tableName: "GeneralSettings"))
      .disabled(ScopedShortcut.resolve(initial: action.initial, stored: scopedValues[action.rawValue]) == action.initial)
    }
  }

  private func reset(_ action: ScopedShortcut) {
    let shortcut = action.initial
    if case .disallow(let reason) = validate(shortcut, id: action.rawValue, scope: action.scope) {
      resetConflict = reason
    } else if shortcut.isTakenBySystem {
      resetConflict = String(
        localized: "ShortcutResetSystemConflict",
        defaultValue: "The default shortcut is already in use by macOS.",
        table: "GeneralSettings"
      )
    } else {
      action.set(shortcut)
    }
  }

  private func shortcutRow<Controls: View>(
    title: String, symbol: String, detail: Text? = nil, @ViewBuilder controls: () -> Controls
  ) -> some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .foregroundStyle(.secondary)
        .frame(width: 20)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        if let detail {
          detail
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 5) {
        controls()
      }
      .frame(width: 155, alignment: .trailing)
    }
    .frame(minHeight: 28)
    .padding(.vertical, 6)
  }

  private func validate(
    _ shortcut: KeyboardShortcuts.Shortcut, id: String, scope: ShortcutScope
  ) -> KeyboardShortcuts.ValidationResult {
    if scope == .historyEditor, shortcut.toSwiftUI == nil {
      return .disallow(reason: String(
        localized: "ShortcutEditorUnsupported",
        defaultValue: "That key is not available in the history editor. Try another combination.",
        table: "GeneralSettings"
      ))
    }
    let action = ScopedShortcut(rawValue: id)
    let alternates: Set<KeyboardShortcuts.Shortcut> = action?.initial == shortcut ? action?.defaultAlternates ?? [] : []
    let candidate = ShortcutAssignment(id: id, title: "", scope: scope, shortcut: shortcut, alternates: alternates)
    if let other = candidate.conflicts(in: assignments).first {
      return .disallow(reason: String(
        localized: "ShortcutDuplicate", defaultValue: "This shortcut is already used by \(other.title).",
        table: "GeneralSettings"
      ))
    }
    if let menuItem = ScopedShortcut.mainMenuItem(for: shortcut, scope: scope) {
      return .disallow(reason: String(
        localized: "ShortcutMenuConflict", defaultValue: "This shortcut is used by the menu item \(menuItem.title).",
        table: "GeneralSettings"
      ))
    }
    return .allow
  }

  private var assignments: [ShortcutAssignment] {
    (Self.clipboard + Self.capture).compactMap { action in
      action.name.shortcut.map {
        ShortcutAssignment(id: action.id, title: action.title, scope: action.scope, shortcut: $0)
      }
    } + ScopedShortcut.allCases.compactMap { action in
      action.current.map {
        ShortcutAssignment(
          id: action.rawValue, title: action.title, scope: action.scope, shortcut: $0,
          alternates: $0 == action.initial ? action.defaultAlternates : []
        )
      }
    }
  }
}

private struct ShortcutDisclosureStyle: DisclosureGroupStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        configuration.isExpanded.toggle()
      } label: {
        HStack(spacing: 10) {
          configuration.label
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 14)
            .accessibilityHidden(true)
        }
        .frame(minHeight: 34)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityValue(configuration.isExpanded
        ? Text("ShortcutGroupExpanded", tableName: "GeneralSettings")
        : Text("ShortcutGroupCollapsed", tableName: "GeneralSettings"))

      if configuration.isExpanded {
        configuration.content
          .padding(.bottom, 8)
      }
    }
  }
}

struct ShortcutAssignment {
  let id: String
  let title: String
  let scope: ShortcutScope
  let shortcut: KeyboardShortcuts.Shortcut
  var alternates: Set<KeyboardShortcuts.Shortcut> = []

  func conflicts(in assignments: [Self]) -> [Self] {
    assignments.filter { $0.id != id && scope.overlaps($0.scope) && overlap(with: $0) != nil }
  }

  func overlap(with other: Self) -> KeyboardShortcuts.Shortcut? {
    if shortcut == other.shortcut || other.alternates.contains(shortcut) { return shortcut }
    if alternates.contains(other.shortcut) { return other.shortcut }
    return alternates.intersection(other.alternates).min {
      ($0.carbonKeyCode, $0.carbonModifiers) < ($1.carbonKeyCode, $1.carbonModifiers)
    }
  }
}

private struct RecordedAction: Identifiable {
  let key: String
  let detail: String
  let symbol: String
  let name: KeyboardShortcuts.Name
  let scope: ShortcutScope

  init(_ key: String, _ detail: String, _ symbol: String, _ name: KeyboardShortcuts.Name, _ scope: ShortcutScope) {
    self.key = key
    self.detail = detail
    self.symbol = symbol
    self.name = name
    self.scope = scope
  }

  var id: String { "recorded:\(name.rawValue)" }
  var title: String {
    NSLocalizedString(key, tableName: "GeneralSettings", comment: "")
      .trimmingCharacters(in: CharacterSet(charactersIn: ":：").union(.whitespaces))
  }
}
