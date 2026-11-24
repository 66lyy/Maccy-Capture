import SwiftUI
import Defaults
import LaunchAtLogin

struct GeneralSettingsPane: View {
  private let notificationsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(Bundle.main.bundleIdentifier ?? "")"
  )

  @Default(.searchMode) private var searchMode
  @Default(.pasteByDefault) private var pasteByDefault
  @Default(.removeFormattingByDefault) private var removeFormattingByDefault

  @State private var copyModifier = HistoryItemAction.copy.modifierFlags.description
  @State private var pasteModifier = HistoryItemAction.paste.modifierFlags.description
  @State private var pasteWithoutFormatting = HistoryItemAction.pasteWithoutFormatting.modifierFlags.description

  @State private var updater = SoftwareUpdater.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      PreferencesGroup(title: Text("GeneralLanguageSection", tableName: "GeneralSettings"), symbol: "globe") {
        LanguageSettingsView()
          .padding(.vertical, 10)
      }

      PreferencesGroup(title: Text("GeneralBehaviorSection", tableName: "GeneralSettings"), symbol: "slider.horizontal.3") {
        PreferencesRow(title: Text("LaunchAtLogin", tableName: "GeneralSettings")) {
          LaunchAtLogin.Toggle {
            Text("LaunchAtLogin", tableName: "GeneralSettings")
          }
          .toggleStyle(.switch)
          .labelsHidden()
          .accessibilityLabel(Text("LaunchAtLogin", tableName: "GeneralSettings"))
        }
        Divider()

        PreferencesRow(title: Text("Search", tableName: "GeneralSettings")) {
          Picker("", selection: $searchMode) {
            ForEach(Search.Mode.allCases) { mode in
              Text(mode.description)
            }
          }
          .labelsHidden()
          .accessibilityLabel(Text("Search", tableName: "GeneralSettings"))
          .frame(width: 176, alignment: .trailing)
        }
        Divider()

        option(.pasteByDefault, "PasteAutomatically")
        Divider()
        option(.removeFormattingByDefault, "PasteWithoutFormatting")

        Text(String(
          format: NSLocalizedString("Modifiers", tableName: "GeneralSettings", comment: ""),
          copyModifier, pasteModifier, pasteWithoutFormatting
        ))
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.secondary)
        .font(.subheadline)
        .padding(.bottom, 10)

        Divider()
        option(.formatJSON, "FormatJSON")
        Divider()
        if let notificationsURL = notificationsURL {
          Link(destination: notificationsURL, label: {
            Text("NotificationsAndSounds", tableName: "GeneralSettings")
          })
          .padding(.bottom, 10)
        }
        Divider()
        option(.screenshotRemoveWindowShadow, "ScreenshotRemoveWindowShadow")
        Divider()
        option(.screenshotWindowBackdrop, "ScreenshotWindowBackdrop")
        Divider()
        option(.automaticPinStackingEnabled, Text(verbatim: String(
          localized: "ScreenshotAutoStackPins",
          defaultValue: "Automatically stack pinned screenshots",
          table: "GeneralSettings"
        )))
      }

      PreferencesGroup(title: Text("AnnotationToolsSection", tableName: "GeneralSettings"), symbol: "pencil.tip.crop.circle") {
        AnnotationToolSettings()
          .padding(.vertical, 10)
      }

      PreferencesGroup(title: Text("UpdateSection", tableName: "GeneralSettings"), symbol: "arrow.down.circle") {
        updateSettings
          .padding(.vertical, 10)
      }
    }
    .onChange(of: pasteByDefault, refreshModifiers)
    .onChange(of: removeFormattingByDefault, refreshModifiers)
  }

  private func option(_ key: Defaults.Key<Bool>, _ title: LocalizedStringKey) -> some View {
    option(key, Text(title, tableName: "GeneralSettings"))
  }

  private func option(_ key: Defaults.Key<Bool>, _ title: Text) -> some View {
    PreferencesRow(title: title) {
      Defaults.Toggle(key: key) {
        title
      }
      .toggleStyle(.switch)
      .labelsHidden()
      .accessibilityLabel(title)
    }
  }

  private var updateSettings: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: updater.currentVersion)
        .font(.caption)
        .textSelection(.enabled)
      Picker(selection: $updater.channel) {
        Text("UpdateChannelStable", tableName: "GeneralSettings").tag(RepositoryUpdateFeed.Channel.stable)
        Text("UpdateChannelPreview", tableName: "GeneralSettings").tag(RepositoryUpdateFeed.Channel.preview)
      } label: {
        Text("UpdateChannel", tableName: "GeneralSettings")
      }
      .pickerStyle(.menu)
      .disabled(!updater.isAvailable || updater.isBusy)
      Text("UpdateChannelHelp", tableName: "GeneralSettings")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Toggle(isOn: $updater.automaticallyChecksForUpdates) {
        Text("UpdateAutomaticChecks", tableName: "GeneralSettings")
      }
      .disabled(!updater.isAvailable)
      HStack {
        Button {
          updater.checkForUpdates()
        } label: {
          Text("CheckNow", tableName: "GeneralSettings")
        }
        .disabled(!updater.isAvailable || updater.isBusy)
        if updater.isChecking {
          ProgressView().controlSize(.small)
        }
      }
      Text(LocalizedStringKey(updater.statusKey), tableName: "GeneralSettings")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text("UpdateRestartHelp", tableName: "GeneralSettings")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func refreshModifiers() {
    copyModifier = HistoryItemAction.copy.modifierFlags.description
    pasteModifier = HistoryItemAction.paste.modifierFlags.description
    pasteWithoutFormatting = HistoryItemAction.pasteWithoutFormatting.modifierFlags.description
  }
}

#Preview {
  GeneralSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}

struct AnnotationToolSettings: View {
  typealias Tool = ScreenshotAnnotationDocument.Tool

  @Default(.annotationToolOrder) private var order
  @Default(.disabledAnnotationTools) private var disabled
  @Default(.toolbarItemOrder) private var itemOrder
  @Default(.disabledToolbarItems) private var disabledItems

  static let rowHeight: CGFloat = 28

  private var tools: [Tool] { Tool.toolbarTools(order: order, disabled: []) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ReorderableToggleList(
        title: "AnnotationTools",
        rows: tools.map { .init(id: $0.rawValue, symbol: ScreenshotAnnotationWindow.symbol(for: $0), titleKey: $0.titleKey) },
        isOn: { !disabled.contains($0) },
        canSwitchOff: { id in tools.filter { !disabled.contains($0.rawValue) }.count > 1 || disabled.contains(id) },
        setOn: { id, enabled in
          disabled.removeAll { $0 == id }
          if !enabled { disabled.append(id) }
        },
        move: { id, translation in
          if let tool = Tool(rawValue: id), let reordered = Self.reorderedTools(tool, translation: translation, order: order) {
            order = reordered
          }
        }
      )
      ForEach(ScreenshotToolbarItem.Group.allCases, id: \.self) { group in
        let items = ScreenshotToolbarItem.items(in: group, order: itemOrder, disabled: [])
        ReorderableToggleList(
          title: Self.titleKey(for: group),
          rows: items.map { .init(id: $0.rawValue, symbol: $0.symbol, titleKey: $0.titleKey) },
          isOn: { !disabledItems.contains($0) },
          canSwitchOff: { _ in true },
          setOn: { id, enabled in
            disabledItems.removeAll { $0 == id }
            if !enabled { disabledItems.append(id) }
          },
          move: { id, translation in
            if let item = ScreenshotToolbarItem(rawValue: id),
               let reordered = Self.reorderedItems(item, translation: translation, order: itemOrder) {
              itemOrder = reordered
            }
          }
        )
      }
      Text("AnnotationToolsHelp", tableName: "GeneralSettings")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  static func titleKey(for group: ScreenshotToolbarItem.Group) -> String {
    switch group {
    case .history: "ToolbarHistoryGroup"
    case .output: "ToolbarOutputGroup"
    case .style: "ToolbarStyleGroup"
    }
  }

  static func reorderedItems(_ item: ScreenshotToolbarItem, translation: CGFloat, order: [String]) -> [String]? {
    guard translation.isFinite else { return nil }
    let group = ScreenshotToolbarItem.items(in: item.group, order: order, disabled: [])
    guard let source = group.firstIndex(of: item) else { return nil }
    let destination = Int(min(max(CGFloat(source) + (translation / rowHeight).rounded(), 0), CGFloat(group.count - 1)))
    guard destination != source else { return nil }
    var reordered = group
    reordered.remove(at: source)
    reordered.insert(item, at: destination)
    let others = ScreenshotToolbarItem.Group.allCases.filter { $0 != item.group }
      .flatMap { ScreenshotToolbarItem.items(in: $0, order: order, disabled: []) }
    return (reordered + others).map(\.rawValue)
  }

  static func reorderedTools(_ tool: Tool, translation: CGFloat, order: [Int]) -> [Int]? {
    guard translation.isFinite else { return nil }
    let tools = Tool.toolbarTools(order: order, disabled: [])
    guard let source = tools.firstIndex(of: tool) else { return nil }
    let destination = Int(min(max(CGFloat(source) + (translation / rowHeight).rounded(), 0), CGFloat(tools.count - 1)))
    guard destination != source else { return nil }
    let remaining = tools.filter { $0 != tool }
    let target = remaining.indices.contains(destination) ? remaining[destination] : nil
    return reorderedTools(["annotation-tool:\(tool.rawValue)"], before: target, order: order)
  }

  static func reorderedTools(_ items: [String], before target: Tool?, order: [Int]) -> [Int]? {
    guard items.count == 1, let item = items.first,
          item.hasPrefix("annotation-tool:"),
          let rawValue = Int(item.dropFirst("annotation-tool:".count)),
          let tool = Tool(rawValue: rawValue), tool != target else { return nil }
    var reordered = Tool.toolbarTools(order: order, disabled: []).filter { $0 != tool }
    if let target, let index = reordered.firstIndex(of: target) {
      reordered.insert(tool, at: index)
    } else {
      reordered.append(tool)
    }
    return reordered.map(\.rawValue)
  }
}

struct ReorderableToggleList<ID: Hashable>: View {
  struct Row: Identifiable {
    let id: ID
    let symbol: String
    let titleKey: String
  }

  let title: String
  let rows: [Row]
  let isOn: (ID) -> Bool
  let canSwitchOff: (ID) -> Bool
  let setOn: (ID, Bool) -> Void
  let move: (ID, CGFloat) -> Void

  @GestureState private var dragged: ID?
  @GestureState private var offset: CGFloat = 0
  @Namespace private var dragCoordinateSpace

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(LocalizedStringKey(title), tableName: "GeneralSettings")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
      VStack(spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
          if index > 0 { Divider().frame(height: 1) }
          HStack(spacing: 8) {
            HStack(spacing: 8) {
              Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
              Image(systemName: row.symbol)
                .frame(width: 20)
              Text(LocalizedStringKey(row.titleKey), tableName: "GeneralSettings")
              Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
              DragGesture(minimumDistance: 4, coordinateSpace: .named(dragCoordinateSpace))
                .updating($dragged) { _, state, _ in state = row.id }
                .updating($offset) { value, state, _ in state = value.translation.height }
                .onEnded { value in move(row.id, value.translation.height) }
            )
            Toggle(isOn: Binding(get: { isOn(row.id) }, set: { setOn(row.id, $0) })) {
              Text(LocalizedStringKey(row.titleKey), tableName: "GeneralSettings")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(isOn(row.id) && !canSwitchOff(row.id))
          }
          .frame(height: AnnotationToolSettings.rowHeight - 1)
          .background {
            if dragged == row.id {
              RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15))
            }
          }
          .offset(y: dragged == row.id ? offset : 0)
          .zIndex(dragged == row.id ? 1 : 0)
        }
      }
      .coordinateSpace(name: dragCoordinateSpace)
    }
  }
}
