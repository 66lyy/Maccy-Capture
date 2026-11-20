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
        option(.screenshotSoundEnabled, "ScreenshotSound")
        if let notificationsURL = notificationsURL {
          Link(destination: notificationsURL, label: {
            Text("NotificationsAndSounds", tableName: "GeneralSettings")
          })
          .padding(.bottom, 10)
        }
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
    PreferencesRow(title: Text(title, tableName: "GeneralSettings")) {
      Defaults.Toggle(key: key) {
        Text(title, tableName: "GeneralSettings")
      }
      .toggleStyle(.switch)
      .labelsHidden()
      .accessibilityLabel(Text(title, tableName: "GeneralSettings"))
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
  @GestureState private var draggedTool: Tool?
  @GestureState private var dragOffset: CGFloat = 0

  private static let rowHeight: CGFloat = 28

  private var tools: [Tool] { Tool.toolbarTools(order: order, disabled: []) }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      VStack(spacing: 0) {
        ForEach(tools, id: \.self) { tool in
          HStack(spacing: 8) {
            HStack(spacing: 8) {
              Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
              Image(systemName: ScreenshotAnnotationWindow.symbol(for: tool))
                .frame(width: 20)
              Text(LocalizedStringKey(tool.titleKey), tableName: "GeneralSettings")
              Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
              DragGesture(minimumDistance: 4, coordinateSpace: .named("annotation-tools"))
                .updating($draggedTool) { _, state, _ in state = tool }
                .updating($dragOffset) { value, state, _ in state = value.translation.height }
                .onEnded { value in
                  if let reordered = Self.reorderedTools(tool, translation: value.translation.height, order: order) {
                    order = reordered
                  }
                }
            )
            Toggle(isOn: binding(for: tool)) {
              Text(LocalizedStringKey(tool.titleKey), tableName: "GeneralSettings")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(isLastEnabled(tool))
          }
          .padding(.horizontal, 8)
          .frame(height: Self.rowHeight)
          .background(draggedTool == tool ? Color.accentColor.opacity(0.15) : Color.clear)
          .offset(y: draggedTool == tool ? dragOffset : 0)
          .zIndex(draggedTool == tool ? 1 : 0)
        }
        Color.clear
          .frame(height: 8)
      }
      .coordinateSpace(name: "annotation-tools")
      .background(.background)
      .overlay {
        Rectangle().strokeBorder(.separator).allowsHitTesting(false)
      }
      Text("AnnotationToolsHelp", tableName: "GeneralSettings")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
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

  private func isLastEnabled(_ tool: Tool) -> Bool {
    !disabled.contains(tool.rawValue) && tools.filter { !disabled.contains($0.rawValue) }.count == 1
  }

  private func binding(for tool: Tool) -> Binding<Bool> {
    Binding(
      get: { !disabled.contains(tool.rawValue) },
      set: { enabled in
        disabled.removeAll { $0 == tool.rawValue }
        if !enabled { disabled.append(tool.rawValue) }
      }
    )
  }
}
