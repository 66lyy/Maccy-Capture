import AppKit.NSEvent
import KeyboardShortcuts
import Sauce

enum KeyChord: CaseIterable {
  static var pasteKey: Key { pasteMenuItem?.key ?? Key.v }
  static var pasteKeyModifiers: NSEvent.ModifierFlags { pasteMenuItem?.keyEquivalentModifierMask ?? .command }
  private static var pasteMenuItem: NSMenuItem? {
    NSApp.mainMenu?.items
      .flatMap { $0.submenu?.items ?? [] }
      .first { $0.action == #selector(NSText.paste) }
  }

  static var deleteKey: Key? { Sauce.shared.key(shortcut: .delete) }
  static var deleteModifiers: NSEvent.ModifierFlags? { KeyboardShortcuts.Shortcut(name: .delete)?.modifiers }

  static var pinKey: Key? { Sauce.shared.key(shortcut: .pin) }
  static var pinModifiers: NSEvent.ModifierFlags? { KeyboardShortcuts.Shortcut(name: .pin)?.modifiers }

  static var previewKey: Key? { Sauce.shared.key(shortcut: .togglePreview) }
  static var previewModifiers: NSEvent.ModifierFlags? { KeyboardShortcuts.Shortcut(name: .togglePreview)?.modifiers }

  case clearHistory
  case clearHistoryAll
  case clearSearch
  case cycleSearchTag
  case deleteCurrentItem
  case deleteOneCharFromSearch
  case deleteLastWordFromSearch
  case ignored
  case moveToNext
  case moveToLast
  case moveToPrevious
  case moveToFirst
  case extendToNext
  case extendToLast
  case extendToPrevious
  case extendToFirst
  case openPreferences
  case pinOrUnpin
  case selectCurrentItem
  case close
  case togglePreview
  case unknown

  private static let historyBindings: [(ScopedShortcut, Self)] = [
    (.clearHistory, .clearHistory), (.clearHistoryAll, .clearHistoryAll), (.clearSearch, .clearSearch),
    (.cycleSearchTag, .cycleSearchTag),
    (.deleteSearchCharacter, .deleteOneCharFromSearch), (.deleteSearchWord, .deleteLastWordFromSearch),
    (.nextItem, .moveToNext), (.previousItem, .moveToPrevious), (.firstItem, .moveToFirst),
    (.lastItem, .moveToLast), (.selectItem, .selectCurrentItem),
    (.openPreferences, .openPreferences), (.closeHistory, .close)
  ]

  init(_ event: NSEvent?) {
    guard let event, event.type == .keyDown else {
      self = .unknown
      return
    }

    if let match = Self.historyBindings.first(where: { $0.0.matches(event) }) {
      self = match.1
      return
    }

    let modifierFlags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
    var key: Key?

    if KeyboardLayout.current.commandSwitchesToQWERTY, modifierFlags.contains(.command) {
      key = Key(QWERTYKeyCode: Int(event.keyCode))
    } else {
      key = Sauce.shared.key(for: Int(event.keyCode))
    }

    guard let key else {
      self = .unknown
      return
    }

    self.init(key, modifierFlags)
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  init(_ key: Key, _ modifierFlags: NSEvent.ModifierFlags) {
    switch (key, modifierFlags) {
    case (KeyChord.deleteKey, KeyChord.deleteModifiers):
      self = .deleteCurrentItem
    case (.downArrow, [.shift]),
         (.n, [.control, .shift]):
      self = AppState.shared.multiSelectionEnabled ? .extendToNext : Self.defaultNavigation(.nextItem, as: .moveToNext)
    case (.n, [.control]),
         (.j, [.control]):
      self = Self.defaultNavigation(.nextItem, as: .moveToNext)
    case (.downArrow, [.command, .shift]),
         (.downArrow, [.option, .shift]),
         (.n, [.control, .option, .shift]):
      self = AppState.shared.multiSelectionEnabled ? .extendToLast : Self.defaultNavigation(.lastItem, as: .moveToLast)
    case (.downArrow, _) where modifierFlags.contains(.command) || modifierFlags.contains(.option),
         (.n, [.control, .option]):
      self = Self.defaultNavigation(.lastItem, as: .moveToLast)
    case (.upArrow, [.shift]),
         (.p, [.control, .shift]):
      self = AppState.shared.multiSelectionEnabled ? .extendToPrevious
        : Self.defaultNavigation(.previousItem, as: .moveToPrevious)
    case (.p, [.control]):
      self = Self.defaultNavigation(.previousItem, as: .moveToPrevious)
    case (.k, [.control]) where !AppState.shared.navigator.isFirstItemHighlighted:
      // See https://github.com/p0deje/Maccy/issues/1055
      self = Self.defaultNavigation(.previousItem, as: .moveToPrevious)
    case (.upArrow, [.command, .shift]),
         (.upArrow, [.option, .shift]),
         (.p, [.control, .option, .shift]):
      self = AppState.shared.multiSelectionEnabled ? .extendToFirst : Self.defaultNavigation(.firstItem, as: .moveToFirst)
    case (.upArrow, _) where modifierFlags.contains(.command) || modifierFlags.contains(.option),
         (.p, [.control, .option]):
      self = Self.defaultNavigation(.firstItem, as: .moveToFirst)
    case (KeyChord.pinKey, KeyChord.pinModifiers):
      self = .pinOrUnpin
    case (.return, _),
         (.keypadEnter, _):
      self = Self.defaultNavigation(.selectItem, as: .selectCurrentItem)
    case (KeyChord.previewKey, KeyChord.previewModifiers):
      self = .togglePreview
    case (_, _) where !modifierFlags.isDisjoint(with: [.command, .control, .option]):
      self = .ignored
    default:
      self = .unknown
    }
  }

  private static func defaultNavigation(_ shortcut: ScopedShortcut, as action: Self) -> Self {
    shortcut.current == shortcut.initial ? action : .unknown
  }
}
