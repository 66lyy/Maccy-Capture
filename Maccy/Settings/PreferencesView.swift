import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController {
  init(page: PreferencesView.Page = .general, onLayout: PreferencesView.LayoutObserver? = nil) {
    let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 800)
    let availableWidth = visibleFrame.width - 24
    let availableHeight = visibleFrame.height - 24
    let initialSize = NSSize(width: min(800, availableWidth), height: min(740, availableHeight))
    let contentRect = NSRect(origin: .zero, size: initialSize)
    let window = PreferencesWindow(
      contentRect: contentRect,
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = String(localized: "PreferencesWindowTitle", defaultValue: "Settings", table: "GeneralSettings")
    window.titlebarAppearsTransparent = true
    window.backgroundColor = .windowBackgroundColor
    window.isReleasedWhenClosed = false
    let contentView = NSView(frame: contentRect)
    let hostingView = NSHostingView(rootView: PreferencesView(page: page, onLayout: onLayout))
    hostingView.sizingOptions = []
    hostingView.frame = contentView.bounds
    hostingView.autoresizingMask = [.width, .height]
    contentView.addSubview(hostingView)
    window.contentView = contentView
    window.contentMinSize = NSSize(width: min(700, availableWidth), height: min(530, availableHeight))
    window.setContentSize(initialSize)
    window.setFrameOrigin(NSPoint(x: visibleFrame.midX - window.frame.width / 2,
                                  y: visibleFrame.midY - window.frame.height / 2))
    super.init(window: window)
  }

  required init?(coder: NSCoder) { nil }

  func show() {
    NSApp.activate()
    window?.makeKeyAndOrderFront(nil)
    window?.orderFrontRegardless()
  }
}

private final class PreferencesWindow: NSWindow {
  override var canBecomeMain: Bool { false }
}

struct PreferencesView: View {
  typealias LayoutObserver = @MainActor (String, CGRect) -> Void

  enum Page: String, CaseIterable, Identifiable {
    case general, appearance, shortcuts, storage, ignore, advanced

    var id: String { rawValue }

    var title: Text {
      switch self {
      case .general: Text("Title", tableName: "GeneralSettings")
      case .appearance: Text("Title", tableName: "AppearanceSettings")
      case .shortcuts: Text("ShortcutSettingsTitle", tableName: "GeneralSettings")
      case .storage: Text("Title", tableName: "StorageSettings")
      case .ignore: Text("Title", tableName: "IgnoreSettings")
      case .advanced: Text("Title", tableName: "AdvancedSettings")
      }
    }

    var symbol: String {
      switch self {
      case .general: "gearshape"
      case .appearance: "paintpalette"
      case .shortcuts: "keyboard"
      case .storage: "externaldrive"
      case .ignore: "nosign"
      case .advanced: "slider.horizontal.3"
      }
    }
  }

  private let sidebarWidth: CGFloat = 186
  private let contentInset: CGFloat = 22
  private let onLayout: LayoutObserver?
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme
  @State private var selection: Page

  init(page: Page = .general, onLayout: LayoutObserver? = nil) {
    _selection = State(initialValue: page)
    self.onLayout = onLayout
  }

  var body: some View {
    GeometryReader { geometry in
      columns(in: geometry.size)
    }
    .coordinateSpace(name: "preferences")
    .background {
      Color(nsColor: .windowBackgroundColor)
        .overlay {
          if !reduceTransparency {
            let strength = colorScheme == .dark ? 0.21 : 0.27
            RadialGradient(colors: [.blue.opacity(strength), .clear],
                           center: .topLeading, startRadius: 16, endRadius: 560)
            RadialGradient(colors: [.teal.opacity(strength * 0.8), .clear],
                           center: .bottomTrailing, startRadius: 12, endRadius: 500)
          }
        }
        .ignoresSafeArea()
    }
  }

  private func columns(in size: CGSize) -> some View {
    HStack(spacing: 0) {
      sidebar
        .frame(width: sidebarWidth, height: size.height, alignment: .top)
      detail(for: selection)
        .frame(width: max(0, size.width - sidebarWidth), height: size.height, alignment: .topLeading)
    }
  }

  private func detail(for page: Page) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      page.title
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
        .reportPreferencesLayout("title.\(page.id)", to: onLayout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, contentInset)
        .padding(.vertical, 12)

      Divider()

      ScrollView {
        settingsContent(for: page)
          .reportPreferencesLayout("detail.\(page.id)", to: onLayout)
          .frame(maxWidth: 720, alignment: .leading)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, contentInset)
          .padding(.vertical, 16)
      }
      .id(page)
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 9) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .frame(width: 26, height: 26)
          .accessibilityHidden(true)
        Text(verbatim: "Maccy Capture")
          .font(.headline)
      }
      .padding(.horizontal, 12)
      .padding(.top, 12)

      ScrollView {
        VStack(spacing: 3) {
          ForEach(Page.allCases) { page in
            navigationButton(for: page)
          }
        }
        .padding(.horizontal, 7)
      }
      .padding(.bottom, 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .modifier(PreferencesGlassSurface(radius: 18))
    .padding(.leading, 10)
    .padding(.vertical, 8)
  }

  private func navigationButton(for page: Page) -> some View {
    let isSelected = page == selection
    return Button {
      selection = page
    } label: {
      HStack(spacing: 9) {
        Image(systemName: page.symbol)
          .frame(width: 22)
          .foregroundStyle(isSelected ? Color.accentColor : Color(nsColor: .secondaryLabelColor))
          .accessibilityHidden(true)
        page.title
          .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
          .reportPreferencesLayout("navigation.\(page.id)", to: onLayout)
      }
      .padding(.horizontal, 9)
      .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
      .background {
        if isSelected {
          RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.16))
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  @ViewBuilder private func settingsContent(for page: Page) -> some View {
    switch page {
    case .general: GeneralSettingsPane()
    case .appearance: AppearanceSettingsPane()
    case .shortcuts: ShortcutSettingsPane()
    case .storage: StorageSettingsPane()
    case .ignore: IgnoreSettingsPane(onLayout: onLayout)
    case .advanced: AdvancedSettingsPane()
    }
  }
}

extension View {
  @ViewBuilder func reportPreferencesLayout(_ id: String, to observer: PreferencesView.LayoutObserver?) -> some View {
    if let observer {
      onGeometryChange(for: CGRect.self) { geometry in
        geometry.frame(in: .named("preferences"))
      } action: { frame in
        observer(id, frame)
      }
    } else {
      self
    }
  }
}

private struct PreferencesGlassSurface: ViewModifier {
  let radius: CGFloat
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius)
    Group {
      if reduceTransparency {
        content.background(Color(nsColor: .controlBackgroundColor), in: shape)
      } else if #available(macOS 26.0, *) {
        content.glassEffect(.regular, in: shape)
      } else {
        content.background(.regularMaterial, in: shape)
      }
    }
      .overlay {
        if reduceTransparency {
          shape.strokeBorder(.primary.opacity(0.12)).allowsHitTesting(false)
        } else {
          let highlight = colorScheme == .dark ? 0.23 : 0.80
          shape.strokeBorder(.primary.opacity(0.10))
            .overlay {
              shape.strokeBorder(LinearGradient(
                colors: [.white.opacity(highlight), .clear, .white.opacity(highlight * 0.25)],
                startPoint: .topLeading, endPoint: .bottomTrailing
              ))
            }
            .allowsHitTesting(false)
        }
      }
  }
}

struct PreferencesGroup<Content: View>: View {
  let title: Text
  let symbol: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label {
        title
      } icon: {
        Image(systemName: symbol).foregroundStyle(.secondary)
      }
      .font(.headline)
      .accessibilityAddTraits(.isHeader)

      VStack(alignment: .leading, spacing: 0) {
        content
      }
      .padding(.horizontal, 14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .modifier(PreferencesGlassSurface(radius: 12))
    }
  }
}

struct PreferencesRow<Content: View>: View {
  let title: Text
  @ViewBuilder let content: Content

  var body: some View {
    HStack(spacing: 12) {
      title
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      content
    }
    .frame(minHeight: 34)
  }
}
