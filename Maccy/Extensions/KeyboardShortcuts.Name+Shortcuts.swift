import AppKit
import Defaults
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
  static let popup = Self("popup", initial: Shortcut(.c, modifiers: [.command, .shift]))
  static let pin = Self("pin", initial: Shortcut(.p, modifiers: [.option]))
  static let delete = Self("delete", initial: Shortcut(.delete, modifiers: [.option]))
  static let togglePreview = Self("togglePreview", initial: Shortcut(.space, modifiers: [.control]))
  static let screenshot = Self("screenshot")
  static let screenshotSelection = Self("screenshotSelection", initial: Shortcut(.f1))
  static let pinScreenshot = Self("pinScreenshot", initial: Shortcut(.f3))
  static let pinClipboardImage = Self("pinClipboardImage")
  static let togglePinnedClickThrough = Self("togglePinnedClickThrough")
}

enum ShortcutScope: Hashable {
  case global, history, historyEditor, capture, selection, annotation, pinnedImage

  func overlaps(_ other: Self) -> Bool {
    self == other || self == .global || other == .global
      || (self == .capture && [.selection, .annotation].contains(other))
      || (other == .capture && [.selection, .annotation].contains(self))
  }
}

enum ScopedShortcut: String, CaseIterable {
  case clearHistory, clearHistoryAll, clearSearch, deleteSearchCharacter, deleteSearchWord
  case nextItem, previousItem, firstItem, lastItem, selectItem, openPreferences, closeHistory, saveHistoryEdit
  case copyCapture, copyCaptureWithCommand, pinCapture, closeCapture, closeCaptureWindow
  case annotateSelection, selectParent, selectChild
  case saveCapture, undoAnnotation, redoAnnotation
  case copyPinnedImage, editPinnedImage, clickThroughPinnedImage, closePinnedImage

  var scope: ShortcutScope {
    switch self {
    case .saveHistoryEdit: .historyEditor
    case .copyCapture, .copyCaptureWithCommand, .pinCapture, .closeCapture, .closeCaptureWindow, .saveCapture: .capture
    case .annotateSelection, .selectParent, .selectChild: .selection
    case .undoAnnotation, .redoAnnotation: .annotation
    case .copyPinnedImage, .editPinnedImage, .clickThroughPinnedImage, .closePinnedImage: .pinnedImage
    default: .history
    }
  }

  var initial: KeyboardShortcuts.Shortcut {
    switch self {
    case .clearHistory: .init(.delete, modifiers: [.command, .option])
    case .clearHistoryAll: .init(.delete, modifiers: [.command, .option, .shift])
    case .clearSearch: .init(.u, modifiers: [.control])
    case .deleteSearchCharacter: .init(.h, modifiers: [.control])
    case .deleteSearchWord: .init(.w, modifiers: [.control])
    case .nextItem: .init(.downArrow)
    case .previousItem: .init(.upArrow)
    case .firstItem: .init(.pageUp)
    case .lastItem: .init(.pageDown)
    case .selectItem, .copyCapture: .init(.return)
    case .saveHistoryEdit: .init(.return, modifiers: [.command])
    case .openPreferences: .init(.comma, modifiers: [.command])
    case .closeHistory, .closeCapture: .init(.escape)
    case .copyCaptureWithCommand, .copyPinnedImage: .init(.c, modifiers: [.command])
    case .pinCapture: .init(.p)
    case .annotateSelection: .init(.e)
    case .selectParent: .init(.tab, modifiers: [.option])
    case .selectChild: .init(.tab, modifiers: [.option, .shift])
    case .saveCapture: .init(.s, modifiers: [.command])
    case .undoAnnotation: .init(.z, modifiers: [.command])
    case .redoAnnotation: .init(.z, modifiers: [.command, .shift])
    case .editPinnedImage: .init(.e, modifiers: [.command])
    case .clickThroughPinnedImage: .init(.t, modifiers: [.command])
    case .closePinnedImage, .closeCaptureWindow: .init(.w, modifiers: [.command])
    }
  }

  var title: String {
    switch self {
    case .clearHistory: String(localized: "sc_clearHistory", defaultValue: "Clear unpinned history", table: "GeneralSettings")
    case .clearHistoryAll: String(localized: "sc_clearHistoryAll", defaultValue: "Clear all history", table: "GeneralSettings")
    case .clearSearch: String(localized: "sc_clearSearch", defaultValue: "Clear search", table: "GeneralSettings")
    case .deleteSearchCharacter:
      String(localized: "sc_deleteSearchCharacter", defaultValue: "Delete search character", table: "GeneralSettings")
    case .deleteSearchWord:
      String(localized: "sc_deleteSearchWord", defaultValue: "Delete search word", table: "GeneralSettings")
    case .nextItem: String(localized: "sc_nextItem", defaultValue: "Next item", table: "GeneralSettings")
    case .previousItem: String(localized: "sc_previousItem", defaultValue: "Previous item", table: "GeneralSettings")
    case .firstItem: String(localized: "sc_firstItem", defaultValue: "First item", table: "GeneralSettings")
    case .lastItem: String(localized: "sc_lastItem", defaultValue: "Last item", table: "GeneralSettings")
    case .selectItem: String(localized: "sc_selectItem", defaultValue: "Confirm selection", table: "GeneralSettings")
    case .openPreferences: String(localized: "sc_openPreferences", defaultValue: "Open settings", table: "GeneralSettings")
    case .closeHistory: String(localized: "sc_closeHistory", defaultValue: "Close history", table: "GeneralSettings")
    case .saveHistoryEdit:
      String(localized: "sc_saveHistoryEdit", defaultValue: "Save changes to history item", table: "GeneralSettings")
    case .copyCapture:
      String(localized: "sc_copyCapture", defaultValue: "Copy capture", table: "GeneralSettings")
    case .copyCaptureWithCommand:
      String(localized: "sc_copyCaptureWithCommand", defaultValue: "Copy capture (alternate)", table: "GeneralSettings")
    case .pinCapture: String(localized: "sc_pinCapture", defaultValue: "Pin or apply annotation", table: "GeneralSettings")
    case .closeCapture: String(localized: "sc_closeCapture", defaultValue: "Cancel capture", table: "GeneralSettings")
    case .closeCaptureWindow:
      String(localized: "sc_closeCaptureWindow", defaultValue: "Close capture overlay", table: "GeneralSettings")
    case .annotateSelection:
      String(localized: "sc_annotateSelection", defaultValue: "Annotate selection", table: "GeneralSettings")
    case .selectParent: String(localized: "sc_selectParent", defaultValue: "Select parent element", table: "GeneralSettings")
    case .selectChild: String(localized: "sc_selectChild", defaultValue: "Select child element", table: "GeneralSettings")
    case .saveCapture: String(localized: "AnnotationSave", defaultValue: "Save PNG…", table: "GeneralSettings")
    case .undoAnnotation: String(localized: "AnnotationUndo", defaultValue: "Undo", table: "GeneralSettings")
    case .redoAnnotation: String(localized: "AnnotationRedo", defaultValue: "Redo", table: "GeneralSettings")
    case .copyPinnedImage: String(localized: "ScreenshotCopy", defaultValue: "Copy image", table: "GeneralSettings")
    case .editPinnedImage: String(localized: "AnnotationEdit", defaultValue: "Annotate…", table: "GeneralSettings")
    case .clickThroughPinnedImage:
      String(localized: "PinnedClickThrough", defaultValue: "Click-Through", table: "GeneralSettings")
    case .closePinnedImage: String(localized: "ScreenshotClose", defaultValue: "Close pinned image", table: "GeneralSettings")
    }
  }

  var current: KeyboardShortcuts.Shortcut? {
    Self.resolve(initial: initial, stored: Defaults[.scopedShortcuts][rawValue])
  }

  static func resolve(initial: KeyboardShortcuts.Shortcut, stored: Data?) -> KeyboardShortcuts.Shortcut? {
    guard let stored else { return initial }
    do { return try JSONDecoder().decode(KeyboardShortcuts.Shortcut?.self, from: stored) }
    catch { return initial }
  }

  func set(_ value: KeyboardShortcuts.Shortcut?) {
    Defaults[.scopedShortcuts][rawValue] = value == initial ? nil : try? JSONEncoder().encode(value)
  }

  func matches(_ event: NSEvent) -> Bool {
    guard let current, let pressed = KeyboardShortcuts.Shortcut(event: event) else { return false }
    if current == pressed { return true }
    return current == initial && initial.key == .return && pressed.key == .keypadEnter && pressed.modifiers.isEmpty
  }

  var defaultAlternates: Set<KeyboardShortcuts.Shortcut> {
    switch self {
    case .nextItem:
      [.init(.n, modifiers: [.control]), .init(.j, modifiers: [.control]),
       .init(.downArrow, modifiers: [.shift]), .init(.n, modifiers: [.control, .shift])]
    case .previousItem:
      [.init(.p, modifiers: [.control]), .init(.k, modifiers: [.control]),
       .init(.upArrow, modifiers: [.shift]), .init(.p, modifiers: [.control, .shift])]
    case .firstItem:
      [.init(.upArrow, modifiers: [.command]), .init(.upArrow, modifiers: [.option]),
       .init(.upArrow, modifiers: [.command, .shift]), .init(.upArrow, modifiers: [.option, .shift]),
       .init(.p, modifiers: [.control, .option]), .init(.p, modifiers: [.control, .option, .shift])]
    case .lastItem:
      [.init(.downArrow, modifiers: [.command]), .init(.downArrow, modifiers: [.option]),
       .init(.downArrow, modifiers: [.command, .shift]), .init(.downArrow, modifiers: [.option, .shift]),
       .init(.n, modifiers: [.control, .option]), .init(.n, modifiers: [.control, .option, .shift])]
    case .selectItem, .copyCapture: [.init(.keypadEnter)]
    default: []
    }
  }

  static func mainMenuItem(for shortcut: KeyboardShortcuts.Shortcut, scope: ShortcutScope) -> NSMenuItem? {
    guard let equivalent = shortcut.nsMenuItemKeyEquivalent else { return nil }
    if [.capture, .selection, .annotation, .pinnedImage].contains(scope),
       [.init(.c, modifiers: .command), .init(.z, modifiers: .command),
        .init(.z, modifiers: [.command, .shift]), .init(.w, modifiers: .command)].contains(shortcut) {
      return nil
    }
    func find(in menu: NSMenu) -> NSMenuItem? {
      for item in menu.items {
        let isUppercase = item.keyEquivalent != item.keyEquivalent.lowercased()
        let modifiers = isUppercase ? item.keyEquivalentModifierMask.union(.shift) : item.keyEquivalentModifierMask
        if item.keyEquivalent.lowercased() == equivalent.lowercased(), modifiers == shortcut.modifiers {
          return item
        }
        if let submenu = item.submenu, let conflict = find(in: submenu) { return conflict }
      }
      return nil
    }
    return NSApp.mainMenu.flatMap(find)
  }
}
