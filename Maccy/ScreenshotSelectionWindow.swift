import AppKit
import CoreGraphics

@MainActor
final class ScreenshotSelectionWindow: ScreenshotAnnotationWindow {
  var onCancel: (() -> Void)?
  let selectionView: ScreenshotSelectionView

  init(frame: NSRect, visibleFrame: NSRect, scale: CGFloat, pinImmediately: Bool, frozen: CGImage? = nil) {
    selectionView = ScreenshotSelectionView(
      frame: NSRect(origin: .zero, size: frame.size), scale: scale, pinImmediately: pinImmediately
    )
    selectionView.frozen = frozen.map { NSImage(cgImage: $0, size: frame.size) }
    super.init(display: frame, visibleFrame: visibleFrame)
    level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
    collectionBehavior.insert(.canJoinAllApplications)
    ignoresMouseEvents = false
    contentView = selectionView
    initialFirstResponder = selectionView
    selectionView.onCancel = { [weak self] in self?.cancelOperation(nil) }
    selectionView.onValidSelection = { [weak self] rectangle in self?.showToolbar(beside: rectangle) }
    selectionView.onChooseDrawingTool = { [weak self] in self?.chooseTool(.arrow) }
  }

  override func complete(_ action: OutputAction) {
    if canvas != nil {
      super.complete(action)
    } else if !isPreparingImage {
      selectionView.captureSelection(pinToScreen: action == .pin)
    }
  }

  override func keyDown(with event: NSEvent) {
    if canvas != nil || isPreparingImage {
      super.keyDown(with: event)
    } else if event.keyCode == 53 {
      cancelOperation(nil)
    } else {
      selectionView.keyDown(with: event)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if canvas == nil, !isPreparingImage, selectionView.handleSelectionShortcut(event) {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func windowWillClose(_ notification: Notification) {
    let handler = onCancel
    onCancel = nil
    super.windowWillClose(notification)
    handler?()
  }
}
