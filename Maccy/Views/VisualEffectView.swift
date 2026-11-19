import SwiftUI

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

  init(frame: NSRect, cornerRadius: CGFloat, blending: NSVisualEffectView.BlendingMode = .behindWindow) {
    let surfaceBounds = NSRect(origin: .zero, size: frame.size)
    let effectView: NSView
    if #available(macOS 26.0, *) {
      let glass = NSGlassEffectView(frame: surfaceBounds)
      let controls = NSView(frame: surfaceBounds)
      controls.autoresizingMask = [.width, .height]
      glass.style = .regular
      glass.cornerRadius = cornerRadius
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

@MainActor
final class GlassControlStrip: GlassSurfaceView {
  static let buttonSize: CGFloat = 24
  static let inset: CGFloat = 3

  init(buttons: [NSButton]) {
    let size = Self.buttonSize
    let inset = Self.inset
    let height = size + inset * 2
    super.init(
      frame: NSRect(x: 0, y: 0, width: CGFloat(buttons.count) * size + inset * 2, height: height),
      cornerRadius: height / 2, blending: .withinWindow
    )
    for (index, button) in buttons.enumerated() {
      button.isBordered = false
      button.contentTintColor = .labelColor
      button.frame = NSRect(x: inset + CGFloat(index) * size, y: inset, width: size, height: size)
      controlsView.addSubview(button)
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    super.hitTest(point) as? NSButton
  }

  required init?(coder: NSCoder) { nil }
}
