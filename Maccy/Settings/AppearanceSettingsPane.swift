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
  @Default(.glassStyle) private var glassStyle
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
      PreferencesGroup(title: Text("AnnotationToolsSection", tableName: "GeneralSettings"), symbol: "pencil.tip.crop.circle") {
        AnnotationToolSettings()
          .padding(.vertical, 10)
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
      PreferencesRow(title: label("GlassStyle")) {
        Picker("", selection: $glassStyle) {
          ForEach(GlassStyle.allCases) { style in
            Text(style.description)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(reduceTransparency)
        .help(label(reduceTransparency ? "GlassTransparencyReduceTransparency" : "GlassStyleTooltip"))
        .accessibilityLabel(label("GlassStyle"))
      }
      Divider()

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

struct AnnotationToolSettings: View {
  typealias Tool = ScreenshotAnnotationDocument.Tool
  typealias Group = ScreenshotToolbarItem.Group

  @Default(.annotationToolOrder) private var order
  @Default(.disabledAnnotationTools) private var disabled
  @Default(.toolbarGroupOrder) private var groupOrder
  @Default(.toolbarItemOrder) private var itemOrder
  @Default(.disabledToolbarItems) private var disabledItems
  @State private var groupPositions: [Group: CGFloat] = [:]
  @GestureState private var draggedGroup: Group?
  @GestureState private var groupOffset: CGFloat = 0
  @Namespace private var groupCoordinateSpace

  static let rowHeight: CGFloat = 28

  private var tools: [Tool] { Tool.toolbarTools(order: order, disabled: []) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Group.ordered(groupOrder), id: \.self) { group in
        groupRows(group)
          .opacity(draggedGroup == group ? 0.7 : 1)
          .offset(y: draggedGroup == group ? groupOffset : 0)
          .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .named(groupCoordinateSpace)).minY
          } action: { position in
            groupPositions[group] = position
          }
          .zIndex(draggedGroup == group ? 1 : 0)
      }
      Text("AnnotationToolsHelp", tableName: "GeneralSettings")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .coordinateSpace(name: groupCoordinateSpace)
  }

  @ViewBuilder private func groupRows(_ group: Group) -> some View {
    if group == .tools {
      ReorderableToggleList(
        header: groupHeader(group),
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
    } else {
      let items = ScreenshotToolbarItem.items(in: group, order: itemOrder, disabled: [])
      ReorderableToggleList(
        header: groupHeader(group),
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
  }

  private func groupHeader(_ group: Group) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "line.3.horizontal.decrease")
        .foregroundStyle(.tertiary)
      Text(LocalizedStringKey(group.titleKey), tableName: "GeneralSettings")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 4, coordinateSpace: .named(groupCoordinateSpace))
        .updating($draggedGroup) { _, state, _ in state = group }
        .updating($groupOffset) { value, state, _ in state = value.translation.height }
        .onEnded { value in
          if let reordered = group.reordered(translation: value.translation.height, positions: groupPositions, order: groupOrder) {
            groupOrder = reordered
          }
        }
    )
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

private struct ReorderableToggleList<ID: Hashable, Header: View>: View {
  struct Row: Identifiable {
    let id: ID
    let symbol: String
    let titleKey: String
  }

  let header: Header
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
      header
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
