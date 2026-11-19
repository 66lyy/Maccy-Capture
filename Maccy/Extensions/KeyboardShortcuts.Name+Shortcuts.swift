import KeyboardShortcuts

extension KeyboardShortcuts.Name {
  static let popup = Self("popup", initial: Shortcut(.c, modifiers: [.command, .shift]))
  static let pin = Self("pin", initial: Shortcut(.p, modifiers: [.option]))
  static let delete = Self("delete", initial: Shortcut(.delete, modifiers: [.option]))
  static let togglePreview = Self("togglePreview", initial: Shortcut(.space, modifiers: [.control]))
  static let screenshot = Self("screenshot", initial: Shortcut(.s, modifiers: [.command, .shift]))
  static let screenshotSelection = Self("screenshotSelection", initial: Shortcut(.s, modifiers: [.command, .control]))
  static let pinScreenshot = Self("pinScreenshot", initial: Shortcut(.s, modifiers: [.command, .option]))
  static let pinClipboardImage = Self("pinClipboardImage")
}
