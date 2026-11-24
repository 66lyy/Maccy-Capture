import AppKit
import Defaults

nonisolated enum ScreenshotToolbarItem: String, CaseIterable, Sendable {
  case undo, redo, longScreenshot, recognizeText, pin, save, copy, cancel, palette, customColor, size

  enum Group: CaseIterable, Sendable { case history, output, style }

  var group: Group {
    switch self {
    case .undo, .redo: .history
    case .palette, .customColor, .size: .style
    default: .output
    }
  }

  var titleKey: String {
    switch self {
    case .undo: "AnnotationUndo"
    case .redo: "AnnotationRedo"
    case .longScreenshot: "ScreenshotLong"
    case .recognizeText: "AnnotationRecognizeText"
    case .pin: "ToolbarPinOrApply"
    case .save: "AnnotationSave"
    case .copy: "AnnotationCopy"
    case .cancel: "ScreenshotCancel"
    case .palette: "ToolbarPalette"
    case .customColor: "AnnotationColor"
    case .size: "ToolbarSize"
    }
  }

  var symbol: String {
    switch self {
    case .undo: "arrow.uturn.backward"
    case .redo: "arrow.uturn.forward"
    case .longScreenshot: "arrow.up.arrow.down"
    case .recognizeText: "text.viewfinder"
    case .pin: "pin.fill"
    case .save: "square.and.arrow.down"
    case .copy: "doc.on.doc"
    case .cancel: "xmark"
    case .palette: "circle.grid.2x2"
    case .customColor: "paintpalette"
    case .size: "slider.horizontal.3"
    }
  }

  // Items follow the order chosen in Settings within their toolbar row; items added later are appended.
  static func items(in group: Group, order: [String], disabled: [String]) -> [Self] {
    var items: [Self] = []
    for item in order.compactMap(Self.init(rawValue:)) + allCases where item.group == group && !items.contains(item) {
      items.append(item)
    }
    return items.filter { !disabled.contains($0.rawValue) }
  }

  static func styleRows(order: [String], disabled: [String], narrow: Bool) -> [[Self]] {
    let style = items(in: .style, order: order, disabled: disabled)
    guard narrow, let size = style.firstIndex(of: .size) else { return style.isEmpty ? [] : [style] }
    return [Array(style[..<size]), [.size], Array(style[(size + 1)...])].filter { !$0.isEmpty }
  }
}

extension ScreenshotAnnotationWindow {
  static func toolbarFrame(beside imageFrame: NSRect, bounds: NSRect, size: NSSize) -> NSRect {
    let margin: CGFloat = min(8, bounds.width / 4, bounds.height / 4)
    let available = bounds.insetBy(dx: margin, dy: margin)
    let width = min(size.width, available.width)
    let height = min(size.height, available.height)
    let below = imageFrame.minY - height - 10
    let above = imageFrame.maxY + 10
    let preferredY = below >= available.minY ? below
      : above + height <= available.maxY ? above : available.minY
    return NSRect(
      x: max(available.minX, min(imageFrame.maxX - width, available.maxX - width)),
      y: max(available.minY, min(preferredY, available.maxY - height)),
      width: width, height: height
    )
  }

  func configureToolbar(originalWasCopied: Bool, compact: Bool, narrow: Bool) {
    annotationToolbar.setAccessibilityLabel(text("AnnotationTools"))
    let availableTools = ScreenshotAnnotationDocument.Tool.toolbarTools(
      order: Defaults[.annotationToolOrder], disabled: Defaults[.disabledAnnotationTools]
    )
    if let selected = selectedTool, !availableTools.contains(selected) { selectedTool = availableTools.first }
    toolButtons = availableTools.map { tool in
      let control = button(tool.titleKey, symbol: Self.symbol(for: tool), action: #selector(selectTool(_:)))
      control.tag = tool.rawValue
      control.isChosen = tool == selectedTool
      return control
    }
    undoButton = button("AnnotationUndo", symbol: "arrow.uturn.backward", action: #selector(undoMark))
    redoButton = button("AnnotationRedo", symbol: "arrow.uturn.forward", action: #selector(redoMark))
    copyButton = button("AnnotationCopy", symbol: "doc.on.doc", action: #selector(copyImage))
    addShortcutHint(to: copyButton, [ScopedShortcut.copyCapture, .copyCaptureWithCommand])
    pinButton = button(
      editingPin ? "AnnotationApply" : "ScreenshotPinImage",
      symbol: editingPin ? "checkmark" : "pin.fill",
      action: editingPin ? #selector(applyImage) : #selector(pinImage)
    )
    addShortcutHint(to: pinButton, [ScopedShortcut.pinCapture])
    recognitionButton = button("AnnotationRecognizeText", symbol: "text.viewfinder", action: #selector(recognizeText))
    let saveButton = button("AnnotationSave", symbol: "square.and.arrow.down", action: #selector(saveImage))
    addShortcutHint(to: saveButton, [ScopedShortcut.saveCapture])
    var controls: [ScreenshotToolbarItem: NSView] = [
      .undo: undoButton, .redo: redoButton, .recognizeText: recognitionButton, .pin: pinButton, .save: saveButton,
      .copy: copyButton, .cancel: button("ScreenshotCancel", symbol: "xmark", action: #selector(cancelEditor))
    ]
    if let selection = self as? ScreenshotSelectionWindow, selection.allowsLongScreenshot {
      let symbol = NSImage(systemSymbolName: "arrow.up.and.down.text.horizontal", accessibilityDescription: nil) != nil
        ? "arrow.up.and.down.text.horizontal" : "arrow.up.arrow.down"
      let control = button(
        "ScreenshotLong", symbol: symbol, action: #selector(ScreenshotSelectionWindow.beginLongScreenshot)
      )
      selection.longScreenshotButton = control
      controls[.longScreenshot] = control
    }
    swatches = palette.enumerated().map { index, entry in
      let swatch = button(entry.1, symbol: "", action: #selector(selectColor(_:)), width: 23)
      swatch.tag = index
      swatch.swatchColor = entry.0
      swatch.isChosen = index == 0
      return swatch
    }
    colorWell.colorWellStyle = .minimal
    colorWell.supportsAlpha = false
    colorWell.color = palette[0].0
    colorWell.target = self
    colorWell.action = #selector(selectCustomColor)
    colorWell.setAccessibilityLabel(text("AnnotationColor"))
    colorWell.toolTip = text("AnnotationColor")
    colorWell.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      colorWell.widthAnchor.constraint(equalToConstant: 28),
      colorWell.heightAnchor.constraint(equalToConstant: 25)
    ])
    styleSlider.target = self
    styleSlider.action = #selector(changeSize)
    styleSlider.isContinuous = true
    styleSlider.controlSize = .small
    styleSlider.widthAnchor.constraint(equalToConstant: 95).isActive = true
    styleLabel.font = .systemFont(ofSize: 11, weight: .medium)
    let labelWidth = ["AnnotationFontSize", "AnnotationMosaicSize", "AnnotationMagnification", "AnnotationWidth"]
      .map { key -> CGFloat in
        styleLabel.stringValue = text(key)
        return ceil(styleLabel.intrinsicContentSize.width)
      }.max() ?? 0
    styleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: labelWidth).isActive = true
    styleValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    styleValue.alignment = .right
    styleValue.widthAnchor.constraint(equalToConstant: 34).isActive = true
    refreshStyle()
    let info = NSImageView(image: NSImage(
      systemSymbolName: "info.circle", accessibilityDescription: text("AnnotationInlineHelp")
    ) ?? NSImage())
    info.toolTip = text("AnnotationInlineHelp") + "\n" + text(
      originalWasCopied ? "AnnotationExistingOriginalNotice" : "AnnotationPrivateNotice"
    )
    info.contentTintColor = .secondaryLabelColor
    statusLabel.font = .systemFont(ofSize: 11)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.isHidden = true
    statusLabel.lineBreakMode = .byTruncatingTail
    statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let grip = ScreenshotToolbarGrip(image: NSImage(
      systemSymbolName: "line.3.horizontal", accessibilityDescription: text("AnnotationMoveToolbar")
    ) ?? NSImage())
    grip.toolTip = text("AnnotationMoveToolbar")
    grip.contentTintColor = .secondaryLabelColor
    controls[.palette] = row(swatches.map { $0 as NSView })
    controls[.customColor] = colorWell
    controls[.size] = row([styleLabel, styleSlider, styleValue])
    let order = Defaults[.toolbarItemOrder], disabled = Defaults[.disabledToolbarItems]
    func items(_ group: ScreenshotToolbarItem.Group) -> [ScreenshotToolbarItem] {
      ScreenshotToolbarItem.items(in: group, order: order, disabled: disabled).filter { controls[$0] != nil }
    }
    func joined(_ groups: [[NSView]]) -> [NSView] {
      groups.filter { !$0.isEmpty }.map { row($0) as NSView }.enumerated().flatMap { $0.offset == 0 ? [$0.element] : [separator(), $0.element] }
    }
    var tools: [NSView] = toolButtons
    if editingPin {
      let crop = button("AnnotationCropPin", symbol: "crop", action: #selector(togglePinCrop))
      crop.toolTip = PinnedScreenshotWindow.localized("AnnotationPinCropHelp")
      crop.setAccessibilityLabel(PinnedScreenshotWindow.localized("AnnotationCropPin"))
      cropButton = crop
      tools.append(crop)
    }
    let history = items(.history).compactMap { controls[$0] }
    let output = items(.output).compactMap { controls[$0] }
    var styleRows = ScreenshotToolbarItem.styleRows(order: order, disabled: disabled, narrow: narrow)
      .map { $0.compactMap { controls[$0] } }
    if styleRows.isEmpty { styleRows = [[]] }
    styleRows[styleRows.count - 1].append(info)
    var rows: [NSView]
    if narrow {
      rows = [row([grip] + joined([tools]))]
      let actions = joined([history, output])
      if !actions.isEmpty { rows.append(row(actions)) }
    } else {
      rows = compact ? [row([grip] + joined([tools, history]))] : [row([grip] + joined([tools, history, output]))]
      if compact, !output.isEmpty { rows.append(row(output)) }
    }
    rows.append(contentsOf: styleRows.map { row($0) })
    rows.append(statusLabel)
    let stack = NSStackView(views: rows)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 3
    stack.translatesAutoresizingMaskIntoConstraints = false
    let fitting = stack.fittingSize
    toolbarSize = NSSize(width: ceil(fitting.width) + 20, height: fitting.height + 19)
    let controlsView = annotationToolbar.controlsView
    let group = GlassContainerView(frame: controlsView.bounds)
    group.translatesAutoresizingMaskIntoConstraints = false
    group.controlsView.addSubview(stack)
    controlsView.addSubview(group)
    NSLayoutConstraint.activate([
      group.leadingAnchor.constraint(equalTo: controlsView.leadingAnchor),
      group.trailingAnchor.constraint(equalTo: controlsView.trailingAnchor),
      group.topAnchor.constraint(equalTo: controlsView.topAnchor),
      group.bottomAnchor.constraint(equalTo: controlsView.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: controlsView.leadingAnchor, constant: 10),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: controlsView.trailingAnchor, constant: -10),
      stack.centerYAnchor.constraint(equalTo: controlsView.centerYAnchor)
    ])
  }

  static func symbol(for tool: ScreenshotAnnotationDocument.Tool) -> String {
    let candidates: [String] = switch tool {
    case .arrow: ["arrow.up.right"]
    case .rectangle: ["rectangle"]
    case .ellipse: ["oval"]
    case .pen: ["pencil.tip"]
    case .text: ["character.cursor.ibeam", "character"]
    case .number: ["1.circle", "number.circle"]
    case .magnifier: ["plus.magnifyingglass", "magnifyingglass"]
    case .redact: ["rectangle.fill"]
    case .mosaic: ["checkerboard.rectangle", "square.grid.3x3.fill"]
    case .eraser: ["eraser", "eraser.fill", "delete.left"]
    }
    return candidates.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? candidates[0]
  }

  private func addShortcutHint(to button: NSButton, _ shortcuts: [ScopedShortcut]) {
    let keys = shortcuts.compactMap { $0.current?.description }.joined(separator: " / ")
    guard !keys.isEmpty, let title = button.toolTip else { return }
    button.toolTip = "\(title)  \(keys)"
  }

  private func row(_ views: [NSView]) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.spacing = 3
    stack.alignment = .centerY
    return stack
  }

  private func separator() -> NSBox {
    let divider = NSBox()
    divider.boxType = .separator
    divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
    divider.heightAnchor.constraint(equalToConstant: 16).isActive = true
    return divider
  }

  private func button(_ key: String, symbol: String, action: Selector, width: CGFloat = 28) -> ScreenshotToolbarButton {
    let button = ScreenshotToolbarButton(frame: .zero)
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text(key))?
      .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
    button.target = self
    button.action = action
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.contentTintColor = .labelColor
    if !symbol.isEmpty { button.usesGlass = button.applyGlassBezel() }
    button.toolTip = text(key)
    button.setAccessibilityLabel(text(key))
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: width).isActive = true
    button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    return button
  }

  func refreshHistoryButtons() {
    undoButton.isEnabled = canvas?.document.canUndo == true
    redoButton.isEnabled = canvas?.document.canRedo == true
    if let tool = selectedTool, let size = canvas?.selectedMarkSize(for: tool) {
      styleSlider.doubleValue = size
      styleValue.stringValue = tool == .magnifier ? "\(Int(size.rounded()))×" : "\(Int(size.rounded()))"
    } else {
      refreshStyle()
    }
    canvas?.needsDisplay = true
  }

  @objc private func selectTool(_ sender: NSButton) {
    guard let tool = ScreenshotAnnotationDocument.Tool(rawValue: sender.tag) else { return }
    chooseTool(tool)
  }

  func chooseTool(_ tool: ScreenshotAnnotationDocument.Tool) {
    setPinCropMode(false)
    canvas?.cancelTextDrag()
    canvas?.commitText()
    let tools = ScreenshotAnnotationDocument.Tool.toolbarTools(
      order: Defaults[.annotationToolOrder], disabled: Defaults[.disabledAnnotationTools]
    )
    selectedTool = tools.contains(tool) ? tool : tools.first
    updateTool()
    withCanvas { [weak self] canvas in self?.makeFirstResponder(canvas) }
  }

  func updateTool() {
    if let selectedTool { canvas?.tool = selectedTool }
    for button in toolButtons { button.isChosen = canvas?.isCroppingPin != true && button.tag == selectedTool?.rawValue }
    refreshStyle()
    if let canvas { invalidateCursorRects(for: canvas) }
    refreshHistoryButtons()
  }

  @objc private func selectColor(_ sender: NSButton) {
    guard palette.indices.contains(sender.tag) else { return }
    applyColor(palette[sender.tag].0, selectedSwatch: sender.tag)
    if let canvas { makeFirstResponder(canvas) }
  }

  @objc private func selectCustomColor() {
    let color = colorWell.color.withAlphaComponent(1)
    applyColor(color, selectedSwatch: palette.firstIndex { $0.0.withAlphaComponent(1) == color })
  }

  private func applyColor(_ color: NSColor, selectedSwatch: Int?) {
    canvas?.commitText()
    colorWell.color = color
    canvas?.color = color
    for swatch in swatches { swatch.isChosen = swatch.tag == selectedSwatch }
  }

  private func refreshStyle() {
    let tool = selectedTool ?? .arrow
    let label = text(
      tool == .text || tool == .number ? "AnnotationFontSize"
        : tool == .mosaic ? "AnnotationMosaicSize" : tool == .magnifier ? "AnnotationMagnification" : "AnnotationWidth"
    )
    styleLabel.stringValue = label
    styleSlider.setAccessibilityLabel(label)
    switch tool {
    case .text, .number:
      styleSlider.minValue = 10
      styleSlider.maxValue = 120
      styleSlider.doubleValue = fontSize
    case .magnifier:
      styleSlider.minValue = 2
      styleSlider.maxValue = 6
      styleSlider.doubleValue = magnifierZoom
    case .mosaic:
      styleSlider.minValue = 4
      styleSlider.maxValue = 40
      styleSlider.doubleValue = mosaicSize
    default:
      styleSlider.minValue = 1
      styleSlider.maxValue = 40
      styleSlider.doubleValue = lineWidth
    }
    let adjustable = tool != .redact && tool != .eraser
    styleSlider.isEnabled = adjustable
    styleValue.stringValue = !adjustable ? "—" : tool == .magnifier ? "\(styleSlider.integerValue)×" : "\(styleSlider.integerValue)"
  }

  @objc private func changeSize() {
    let size = CGFloat(styleSlider.doubleValue.rounded())
    switch selectedTool {
    case .text, .number:
      fontSize = size
      canvas?.fontSize = size
    case .magnifier:
      magnifierZoom = size
      canvas?.magnifierZoom = size
    case .mosaic:
      mosaicSize = size
      canvas?.mosaicSize = size
    case .redact, .eraser:
      return
    default:
      lineWidth = size
      canvas?.lineWidth = size
    }
    styleValue.stringValue = selectedTool == .magnifier ? "\(Int(size))×" : "\(Int(size))"
    if let tool = selectedTool {
      // One slider drag is one undo step; each click or key press is its own.
      if NSApp.currentEvent?.type != .leftMouseDragged { canvas?.endStyleResize() }
      canvas?.resizeSelectedMark(to: size, as: tool)
    }
  }
}

@MainActor
final class ScreenshotToolbarButton: NSButton {
  var isChosen = false {
    didSet {
      setAccessibilityValue(isChosen)
      refreshAppearance()
    }
  }
  var swatchColor: NSColor? { didSet { refreshAppearance() } }
  // Tool buttons use the macOS 26 glass bezel, tinted with the accent color while chosen.
  var usesGlass = false { didSet { refreshAppearance() } }

  override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

  override func highlight(_ flag: Bool) {
    super.highlight(flag)
    refreshAppearance(pressed: flag)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshAppearance()
  }

  private func refreshAppearance(pressed: Bool = false) {
    if let swatchColor {
      image = swatchImage(swatchColor)
    }
    if usesGlass {
      applyGlassBezel(tint: isChosen ? LiquidGlass.selectionFill : nil)
      let foreground: NSColor = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
      image = image?.withSymbolConfiguration(.init(paletteColors: [foreground]))
      image?.isTemplate = false
      return
    }
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.cornerCurve = .continuous
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let fill = isChosen
        ? NSColor.controlAccentColor.withAlphaComponent(0.22)
        : pressed ? NSColor.labelColor.withAlphaComponent(0.10) : NSColor.clear
      layer?.backgroundColor = fill.cgColor
    }
  }

  private func swatchImage(_ color: NSColor) -> NSImage {
    let chosen = isChosen
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
      let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
      color.setFill()
      dot.fill()
      let outline = chosen ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.35)
      outline.setStroke()
      dot.lineWidth = chosen ? 2 : 1
      dot.stroke()
      return true
    }
    image.isTemplate = false
    return image
  }
}

@MainActor
private final class ScreenshotToolbarGrip: NSImageView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class ScreenshotAnnotationToolbar: GlassSurfaceView {
  var movementBounds = NSRect.zero
  var onMove: (() -> Void)?
  private var dragOrigin: NSPoint?
  private var originalFrame = NSRect.zero

  override var mouseDownCanMoveWindow: Bool { false }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }
    var candidate: NSView? = hit
    while let view = candidate, view !== self {
      if view is NSControl { return hit }
      candidate = view.superview
    }
    return self
  }

  override func mouseDown(with event: NSEvent) {
    beginMove(at: superview?.convert(event.locationInWindow, from: nil) ?? .zero)
  }

  override func mouseDragged(with event: NSEvent) {
    move(to: superview?.convert(event.locationInWindow, from: nil) ?? .zero)
  }

  override func mouseUp(with event: NSEvent) {
    dragOrigin = nil
  }

  func beginMove(at point: NSPoint) {
    dragOrigin = point
    originalFrame = frame
  }

  func move(to point: NSPoint) {
    guard let dragOrigin, point.x.isFinite, point.y.isFinite else { return }
    let bounds = movementBounds.insetBy(dx: 8, dy: 8)
    setFrameOrigin(alignedOrigin(NSPoint(
      x: max(bounds.minX, min(originalFrame.minX + point.x - dragOrigin.x, bounds.maxX - frame.width)),
      y: max(bounds.minY, min(originalFrame.minY + point.y - dragOrigin.y, bounds.maxY - frame.height))
    )))
    onMove?()
  }

  // Keeps the glass and its symbols on whole backing pixels so icons render crisply.
  func alignedOrigin(_ origin: NSPoint) -> NSPoint {
    guard let superview else { return NSPoint(x: origin.x.rounded(), y: origin.y.rounded()) }
    let rect = NSRect(origin: origin, size: frame.size)
    return superview.backingAlignedRect(rect, options: .alignAllEdgesNearest).origin
  }
}
