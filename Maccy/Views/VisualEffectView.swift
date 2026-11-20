import SwiftUI

enum LiquidGlass {
  static func isActive(reduceTransparency: Bool) -> Bool {
    guard #available(macOS 26.0, *) else { return false }
    return !reduceTransparency
  }

  // Neutral highlight for selected items on clear glass, instead of the saturated accent color.
  static let selectionFill = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor.white.withAlphaComponent(0.2)
      : NSColor.white.withAlphaComponent(0.6)
  }

  // Light dimming laid over clear glass so text stays readable on busy backgrounds.
  static let clearDimming = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor.black.withAlphaComponent(0.22)
      : NSColor.white.withAlphaComponent(0.18)
  }
}

struct GlassEffectView: NSViewRepresentable {
  let cornerRadius: CGFloat

  func makeNSView(context: Context) -> NSView {
    GlassSurfaceView(frame: .zero, cornerRadius: cornerRadius)
  }

  func updateNSView(_ view: NSView, context: Context) {}
}

@MainActor
class GlassSurfaceView: NSView {
  let controlsView: NSView

  convenience override init(frame: NSRect) {
    self.init(frame: frame, cornerRadius: 14)
  }

  init(
    frame: NSRect,
    cornerRadius: CGFloat,
    blending: NSVisualEffectView.BlendingMode = .behindWindow,
    tintColor: NSColor? = nil
  ) {
    let surfaceBounds = NSRect(origin: .zero, size: frame.size)
    let effectView: NSView
    if #available(macOS 26.0, *) {
      let glass = NSGlassEffectView(frame: surfaceBounds)
      let controls = NSView(frame: surfaceBounds)
      controls.autoresizingMask = [.width, .height]
      let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
      glass.style = reduceTransparency ? .regular : .clear
      glass.cornerRadius = cornerRadius
      glass.tintColor = tintColor ?? (reduceTransparency ? nil : LiquidGlass.clearDimming)
      glass.contentView = controls
      controlsView = controls
      effectView = glass
    } else {
      let blur = NSVisualEffectView(frame: surfaceBounds)
      blur.material = .popover
      blur.blendingMode = blending
      blur.state = .active
      blur.wantsLayer = true
      blur.layer?.cornerRadius = cornerRadius
      blur.layer?.cornerCurve = .continuous
      blur.layer?.masksToBounds = true
      blur.layer?.borderColor = NSColor(white: 0.5, alpha: 0.32).cgColor
      blur.layer?.borderWidth = 1
      controlsView = blur
      effectView = blur
    }
    super.init(frame: frame)
    effectView.autoresizingMask = [.width, .height]
    addSubview(effectView)
  }

  required init?(coder: NSCoder) { nil }
}

// Icon buttons grouped as separate Liquid Glass buttons on macOS 26, or a shared blurred capsule before it.
@MainActor
final class GlassControlStrip: NSView {
  static let buttonSize: CGFloat = 24
  static let inset: CGFloat = 3
  let controlsView: NSView

  init(buttons: [NSButton]) {
    let size = Self.buttonSize
    let inset = Self.inset
    let height = size + inset * 2
    let frame = NSRect(x: 0, y: 0, width: CGFloat(buttons.count) * size + inset * 2, height: height)
    let bounds = NSRect(origin: .zero, size: frame.size)
    let surface: NSView
    if #available(macOS 26.0, *) {
      let container = GlassContainerView(frame: bounds, spacing: inset)
      surface = container
      controlsView = container.controlsView
    } else {
      let glass = GlassSurfaceView(frame: bounds, cornerRadius: height / 2, blending: .withinWindow)
      surface = glass
      controlsView = glass.controlsView
    }
    super.init(frame: frame)
    surface.autoresizingMask = [.width, .height]
    addSubview(surface)
    for (index, button) in buttons.enumerated() {
      button.contentTintColor = .labelColor
      if !button.applyGlassBezel() {
        button.isBordered = false
      }
      button.frame = NSRect(x: inset + CGFloat(index) * size, y: inset, width: size, height: size)
      controlsView.addSubview(button)
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    var view = super.hitTest(point)
    while let candidate = view, !(candidate is NSButton) {
      view = candidate.superview
      if candidate === self { return nil }
    }
    return view
  }

  required init?(coder: NSCoder) { nil }
}

// Groups glass descendants so they render and blend together on macOS 26.
@MainActor
final class GlassContainerView: NSView {
  let controlsView: NSView

  init(frame: NSRect, spacing: CGFloat = 0) {
    let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
    content.autoresizingMask = [.width, .height]
    controlsView = content
    super.init(frame: frame)
    let host: NSView
    if #available(macOS 26.0, *) {
      let container = NSGlassEffectContainerView(frame: bounds)
      container.spacing = spacing
      container.contentView = content
      host = container
    } else {
      host = content
    }
    host.autoresizingMask = [.width, .height]
    addSubview(host)
  }

  required init?(coder: NSCoder) { nil }
}

extension NSButton {
  // Switches to the macOS 26 glass bezel; returns false on older systems so callers keep their own look.
  @discardableResult
  func applyGlassBezel(tint: NSColor? = nil) -> Bool {
    guard #available(macOS 26.0, *) else { return false }
    isBordered = true
    bezelStyle = .glass
    bezelColor = tint
    return true
  }
}

// Liquid Glass background on macOS 26; `fallback` is drawn before it or with Reduce Transparency.
private struct LiquidGlassBackground<S: Shape, Fallback: View>: ViewModifier {
  let shape: S
  let tint: Color?
  let interactive: Bool
  let enabled: Bool
  let fallback: Fallback
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    if !enabled {
      content
    } else if #available(macOS 26.0, *), !reduceTransparency {
      content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
    } else {
      content.background { fallback }
    }
  }
}

extension View {
  func liquidGlass<S: Shape, Fallback: View>(
    in shape: S,
    tint: Color? = nil,
    interactive: Bool = false,
    enabled: Bool = true,
    @ViewBuilder fallback: () -> Fallback
  ) -> some View {
    modifier(LiquidGlassBackground(
      shape: shape, tint: tint, interactive: interactive, enabled: enabled, fallback: fallback()
    ))
  }

  @ViewBuilder
  func glassButtonStyle(prominent: Bool = false) -> some View {
    if #available(macOS 26.0, *) {
      if prominent {
        buttonStyle(.glassProminent)
      } else {
        buttonStyle(.glass)
      }
    } else {
      self
    }
  }
}

// GlassEffectContainer on macOS 26, a plain pass-through before it.
struct GlassGroup<Content: View>: View {
  var spacing: CGFloat?
  @ViewBuilder var content: Content

  var body: some View {
    if #available(macOS 26.0, *) {
      GlassEffectContainer(spacing: spacing) { content }
    } else {
      content
    }
  }
}
