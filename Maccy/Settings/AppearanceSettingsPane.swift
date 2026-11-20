import AppKit
import SwiftUI
import Defaults

struct AppearanceSettingsPane: View {
  @Default(.popupPosition) private var popupAt
  @Default(.popupScreen) private var popupScreen
  @Default(.pinTo) private var pinTo
  @Default(.imageMaxHeight) private var imageHeight
  @Default(.openPreviewAutomatically) private var openPreviewAutomatically
  @Default(.previewDelay) private var previewDelay
  @Default(.highlightMatch) private var highlightMatch
  @Default(.menuIcon) private var menuIcon
  @Default(.showInStatusBar) private var showInStatusBar
  @Default(.showSearch) private var showSearch
  @Default(.searchVisibility) private var searchVisibility
  @Default(.showFooter) private var showFooter
  @Default(.windowPosition) private var windowPosition
  @Default(.glassTransparency) private var glassTransparency
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  @State private var screens = NSScreen.screens

  private let imageHeightFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 1
    formatter.maximum = 200
    return formatter
  }()

  private let previewDelayFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 200
    formatter.maximum = 100_000
    return formatter
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      placement
      previews
      interface
      if #available(macOS 26.0, *) {
        glass
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
      screens = NSScreen.screens
    }
  }

  private var placement: some View {
    PreferencesGroup(title: label("PlacementSection"), symbol: "macwindow") {
      PreferencesRow(title: label("PopupAt")) {
        HStack(spacing: 6) {
          if popupAt == .lastPosition {
            Button {
              _windowPosition.reset()
            } label: {
              Image(systemName: "arrow.uturn.backward")
            }
            .help(label("PopupAtLastLocationReset"))
            .accessibilityLabel(label("PopupAtLastLocationReset"))
            .disabled(windowPosition == _windowPosition.defaultValue)
          }

          Picker("", selection: $popupAt) {
            ForEach(PopupPosition.allCases) { position in
              if position == .center || position == .lastPosition, screens.count > 1 {
                screenPicker(for: position)
              } else {
                Text(position.description)
              }
            }
          }
          .labelsHidden()
          .frame(width: 176, alignment: .trailing)
          .help(label("PopupAtTooltip"))
          .accessibilityLabel(label("PopupAt"))
          .accessibilityIdentifier("preferences.appearance.popupPosition")
        }
      }

      Divider()

      PreferencesRow(title: label("PinTo")) {
        Picker("", selection: $pinTo) {
          ForEach(PinsPosition.allCases) { position in
            Text(position.description)
          }
        }
        .labelsHidden()
        .frame(width: 176, alignment: .trailing)
        .help(label("PinToTooltip"))
        .accessibilityLabel(label("PinTo"))
      }
    }
  }

  private var previews: some View {
    PreferencesGroup(title: label("PreviewSection"), symbol: "photo.on.rectangle") {
      PreferencesRow(title: label("ImageHeight")) {
        HStack {
          TextField("", value: $imageHeight, formatter: imageHeightFormatter)
            .frame(width: 74)
            .help(label("ImageHeightTooltip"))
            .accessibilityLabel(label("ImageHeight"))
          Stepper("", value: $imageHeight, in: 1...200)
            .labelsHidden()
            .accessibilityLabel(label("ImageHeight"))
        }
      }

      Divider()
      option(.openPreviewAutomatically, "OpenPreviewAutomatically")
      Divider()

      PreferencesRow(title: label("PreviewDelay")) {
        HStack {
          TextField("", value: $previewDelay, formatter: previewDelayFormatter)
            .frame(width: 74)
            .help(label("PreviewDelayTooltip"))
            .accessibilityLabel(label("PreviewDelay"))
          Stepper("", value: $previewDelay, in: 200...100_000)
            .labelsHidden()
            .accessibilityLabel(label("PreviewDelay"))
        }
        .disabled(!openPreviewAutomatically)
      }
    }
  }

  private var interface: some View {
    PreferencesGroup(title: label("InterfaceSection"), symbol: "rectangle.3.group") {
      PreferencesRow(title: label("HighlightMatches")) {
        Picker("", selection: $highlightMatch) {
          ForEach(HighlightMatch.allCases) { match in
            Text(match.description)
          }
        }
        .labelsHidden()
        .frame(width: 176, alignment: .trailing)
        .help(label("HighlightMatchesTooltip"))
        .accessibilityLabel(label("HighlightMatches"))
      }
      Divider()

      PreferencesRow(title: label("ShowMenuIcon")) {
        HStack(spacing: 12) {
          Picker("", selection: $menuIcon) {
            ForEach(MenuIcon.allCases) { icon in
              Image(nsImage: icon.image)
            }
          }
          .labelsHidden()
          .frame(width: 66, alignment: .trailing)
          .disabled(!showInStatusBar)
          .accessibilityLabel(label("MenuIconStyle"))

          preferenceSwitch(.showInStatusBar, "ShowMenuIcon")
        }
      }
      Divider()
      option(.showRecentCopyInMenuBar, "ShowRecentCopyInMenuBar")
      Divider()

      PreferencesRow(title: label("ShowSearchField")) {
        HStack(spacing: 12) {
          Picker("", selection: $searchVisibility) {
            ForEach(SearchVisibility.allCases) { type in
              Text(type.description)
            }
          }
          .labelsHidden()
          .frame(width: 138, alignment: .trailing)
          .disabled(!showSearch)
          .accessibilityLabel(label("SearchFieldVisibility"))

          preferenceSwitch(.showSearch, "ShowSearchField")
        }
      }
      Divider()

      option(.showTitle, "ShowTitleBeforeSearchField")
      Divider()
      option(.showApplicationIcons, "ShowApplicationIcons")
      Divider()
      option(.showSpecialSymbols, "ShowSpecialSymbols")
        .help(label("ShowSpecialSymbolsTooltip"))
      Divider()
      option(.showHexColorSwatch, "ShowHexColorSwatch")
        .help(label("ShowHexColorSwatchTooltip"))
      Divider()
      option(.showFooter, "ShowFooter")

      if !showFooter {
        label("OpenPreferencesWarning")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.bottom, 10)
      }
    }
  }

  private var glass: some View {
    PreferencesGroup(title: label("GlassSection"), symbol: "drop") {
      PreferencesRow(title: label("GlassTransparency")) {
        HStack(spacing: 12) {
          Slider(value: $glassTransparency, in: LiquidGlass.transparencyRange, step: 0.1)
            .frame(width: 150)
            .accessibilityLabel(label("GlassTransparency"))
          Text(glassTransparency, format: .percent.precision(.fractionLength(0)))
            .monospacedDigit()
            .frame(width: 40, alignment: .trailing)
          Button {
            glassTransparency = LiquidGlass.defaultTransparency
          } label: {
            label("GlassTransparencyReset")
          }
          .fixedSize()
          .disabled(glassTransparency == LiquidGlass.defaultTransparency)
        }
        .disabled(reduceTransparency)
        .help(label(reduceTransparency ? "GlassTransparencyReduceTransparency" : "GlassTransparencyTooltip"))
      }
    }
  }

  private func option(_ key: Defaults.Key<Bool>, _ title: LocalizedStringKey) -> some View {
    PreferencesRow(title: label(title)) {
      preferenceSwitch(key, title)
    }
  }

  private func preferenceSwitch(_ key: Defaults.Key<Bool>, _ title: LocalizedStringKey) -> some View {
    Defaults.Toggle(key: key) {
      label(title)
    }
    .toggleStyle(.switch)
    .labelsHidden()
    .accessibilityLabel(label(title))
  }

  private func label(_ key: LocalizedStringKey) -> Text {
    Text(key, tableName: "AppearanceSettings")
  }

  @ViewBuilder
  private func screenPicker(for position: PopupPosition) -> some View {
    let screenBinding: Binding<Int> = Binding {
      return popupScreen
    } set: {
      popupScreen = $0
      popupAt = position
    }

    Picker(selection: screenBinding) {
      Text(labelForScreen(index: 0))
        .tag(0)

      ForEach(screens.indices, id: \.self) { index in
        Text(labelForScreen(index: index + 1))
          .tag(index + 1)
      }
    } label: {
      if popupAt == position {
        Text("\(position.description) (\(labelForScreen(index: popupScreen)))")
      } else {
        Text(position.description)
      }
    }
  }

  private func labelForScreen(index screenIndex: Int) -> String {
    let index = screenIndex - 1
    guard screens.indices.contains(index) else {
      return String(localized: "ActiveScreen", table: "AppearanceSettings")
    }
    return screens[index].localizedName
  }
}

#Preview {
  AppearanceSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
