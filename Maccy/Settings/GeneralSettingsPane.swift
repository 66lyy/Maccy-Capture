import SwiftUI
import Defaults
import KeyboardShortcuts
import LaunchAtLogin
import Settings

struct GeneralSettingsPane: View {
  private let notificationsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(Bundle.main.bundleIdentifier ?? "")"
  )

  @Default(.searchMode) private var searchMode

  @State private var copyModifier = HistoryItemAction.copy.modifierFlags.description
  @State private var pasteModifier = HistoryItemAction.paste.modifierFlags.description
  @State private var pasteWithoutFormatting = HistoryItemAction.pasteWithoutFormatting.modifierFlags.description

  @State private var updater = SoftwareUpdater()

  var body: some View {
    ScrollView {
      settingsContent
    }
    .frame(width: 510, height: min(680, (NSScreen.main?.visibleFrame.height ?? 800) - 120))
  }

  private var settingsContent: some View {
    Settings.Container(contentWidth: 450) {
      Settings.Section(
        bottomDivider: true,
        label: { Text(String(localized: "Language", defaultValue: "Language:", table: "GeneralSettings")) }
      ) {
        LanguageSettingsView()
      }

      Settings.Section(title: "", bottomDivider: true) {
        LaunchAtLogin.Toggle {
          Text("LaunchAtLogin", tableName: "GeneralSettings")
        }
        if updater.isAvailable {
          Toggle(isOn: $updater.automaticallyChecksForUpdates) {
            Text("CheckForUpdates", tableName: "GeneralSettings")
          }
          Button(
            action: { updater.checkForUpdates() },
            label: { Text("CheckNow", tableName: "GeneralSettings") }
          )
        } else {
          Text("CustomizedUpdatesDisabled", tableName: "GeneralSettings")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Settings.Section(label: { Text("Open", tableName: "GeneralSettings") }) {
        KeyboardShortcuts.Recorder(for: .popup, onChange: { newShortcut in
          if newShortcut == nil {
            // No shortcut is recorded. Remove keys monitor
            AppState.shared.popup.deinitEventsMonitor()
          } else {
            // User is using shortcut. Ensure keys monitor is initialized
            AppState.shared.popup.initEventsMonitor()
          }
        })
          .help(Text("OpenTooltip", tableName: "GeneralSettings"))
          .accessibilityLabel(Text("Open", tableName: "GeneralSettings"))
      }

      Settings.Section(label: { Text("Pin", tableName: "GeneralSettings") }) {
        KeyboardShortcuts.Recorder(for: .pin)
          .help(Text("PinTooltip", tableName: "GeneralSettings"))
          .accessibilityLabel(Text("Pin", tableName: "GeneralSettings"))
      }
      Settings.Section(label: { Text("Delete", tableName: "GeneralSettings") }
      ) {
        KeyboardShortcuts.Recorder(for: .delete)
          .help(Text("DeleteTooltip", tableName: "GeneralSettings"))
          .accessibilityLabel(Text("Delete", tableName: "GeneralSettings"))
      }
      Settings.Section(
        bottomDivider: true,
        label: { Text("ShowPreview", tableName: "GeneralSettings") }
      ) {
        KeyboardShortcuts.Recorder(for: .togglePreview)
          .help(Text("ShowPreviewTooltip", tableName: "GeneralSettings"))
          .accessibilityLabel(Text("ShowPreview", tableName: "GeneralSettings"))
      }
      Settings.Section(
        title: NSLocalizedString("ScreenshotSection", tableName: "GeneralSettings", comment: ""),
        bottomDivider: true
      ) {
        screenshotAction("Screenshot", symbol: "display", detail: "ScreenshotMainHint", shortcut: .screenshot) {
          ScreenshotCapture.shared.captureMainDisplay()
        }
        screenshotAction(
          "ScreenshotSelection", symbol: "crop", detail: "ScreenshotSelectionHint", shortcut: .screenshotSelection
        ) {
          ScreenshotCapture.shared.captureSelection()
        }
        screenshotAction("PinScreenshot", symbol: "pin", detail: "ScreenshotPinHint", shortcut: .pinScreenshot) {
          ScreenshotCapture.shared.captureSelection(pinToScreen: true)
        }
        screenshotAction(
          "PinClipboardImage", symbol: "photo.on.rectangle",
          detail: "ScreenshotClipboardHint", shortcut: .pinClipboardImage, buttonTitle: "ScreenshotPinImage"
        ) {
          ScreenshotCapture.shared.pinClipboardImage()
        }
        Defaults.Toggle(key: .screenshotSoundEnabled) {
          Text("ScreenshotSound", tableName: "GeneralSettings")
        }
        Text("ScreenshotHelp", tableName: "GeneralSettings")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack {
          Button {
            ScreenshotCapture.shared.openPermissionSettings()
          } label: {
            Text("ScreenshotOpenSettings", tableName: "GeneralSettings")
          }
          Button {
            AppState.shared.appDelegate?.restartCurrentApplication()
          } label: {
            Text("ScreenshotRestartCurrentApp", tableName: "GeneralSettings")
          }
        }
        Button {
          ScreenshotCapture.shared.cancelCapture()
        } label: {
          Text("ScreenshotCancelCapture", tableName: "GeneralSettings")
        }
      }

      Settings.Section(
        bottomDivider: true,
        label: { Text("Search", tableName: "GeneralSettings") }
      ) {
        Picker("", selection: $searchMode) {
          ForEach(Search.Mode.allCases) { mode in
            Text(mode.description)
          }
        }
        .labelsHidden()
        .accessibilityLabel(Text("Search", tableName: "GeneralSettings"))
        .frame(width: 180, alignment: .leading)
      }

      Settings.Section(
        bottomDivider: true,
        label: { Text("Behavior", tableName: "GeneralSettings") }
      ) {
        Defaults.Toggle(key: .pasteByDefault) {
          Text("PasteAutomatically", tableName: "GeneralSettings")
        }
        .onChange(refreshModifiers)
        .fixedSize()

        Defaults.Toggle(key: .removeFormattingByDefault) {
          Text("PasteWithoutFormatting", tableName: "GeneralSettings")
        }
        .onChange(refreshModifiers)
        .fixedSize()

        Text(String(
          format: NSLocalizedString("Modifiers", tableName: "GeneralSettings", comment: ""),
          copyModifier, pasteModifier, pasteWithoutFormatting
        ))
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.gray)
        .controlSize(.small)
      }

      Settings.Section(title: "") {
        if let notificationsURL = notificationsURL {
          Link(destination: notificationsURL, label: {
            Text("NotificationsAndSounds", tableName: "GeneralSettings")
          })
        }
      }
    }
  }

  private func screenshotAction(
    _ title: String,
    symbol: String,
    detail: String,
    shortcut: KeyboardShortcuts.Name,
    buttonTitle: String = "ScreenshotCaptureNow",
    action: @escaping @MainActor () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Label {
          Text(LocalizedStringKey(title), tableName: "GeneralSettings")
        } icon: {
          Image(systemName: symbol)
            .foregroundStyle(.tint)
            .frame(width: 20)
        }
        Spacer()
        Button(action: action) {
          Text(LocalizedStringKey(buttonTitle), tableName: "GeneralSettings")
        }
      }
      Text(LocalizedStringKey(detail), tableName: "GeneralSettings")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      KeyboardShortcuts.Recorder(for: shortcut)
        .accessibilityLabel(Text(LocalizedStringKey(title), tableName: "GeneralSettings"))
    }
    .padding(.bottom, 10)
  }

  private func refreshModifiers(_ sender: Sendable) {
    copyModifier = HistoryItemAction.copy.modifierFlags.description
    pasteModifier = HistoryItemAction.paste.modifierFlags.description
    pasteWithoutFormatting = HistoryItemAction.pasteWithoutFormatting.modifierFlags.description
  }
}

#Preview {
  GeneralSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
