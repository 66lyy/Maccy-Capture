import Defaults
import SwiftUI
import Testing
@testable import Maccy

@MainActor
@Suite(.serialized)
struct FloatingPanelTests {
  @Observable final class Rows {
    var count = 1
  }

  @Test("Changing scroll content cannot resize the clipboard panel during layout")
  func panelOwnsWindowSize() async throws {
    try #require(AppDelegate.isTesting)
    let savedSize = Defaults[.windowSize]
    defer { Defaults[.windowSize] = savedSize }
    let rows = Rows()
    let initialSize = NSSize(width: 450, height: 210)
    let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: initialSize), onClose: {}) {
      ScrollView {
        VStack {
          ForEach(0..<rows.count, id: \.self) { index in Text("Row \(index)") }
        }
      }
      .frame(minHeight: rows.count > 10 ? 380 : 80)
    }
    panel.isReleasedWhenClosed = false
    defer { panel.close() }
    panel.orderBack(nil)
    let contentView = try #require(panel.contentView)
    let hostedView = try #require(contentView.subviews.first)
    for size in [initialSize, NSSize(width: 500, height: 240)] {
      panel.setContentSize(size)
      for count in [40, 1] {
        withAnimation(.linear(duration: 0.05)) { rows.count = count }
        try await Task.sleep(for: .milliseconds(150))
        panel.layoutIfNeeded()
        #expect(panel.contentRect(forFrameRect: panel.frame).size == size)
        #expect(contentView.bounds.size == size)
        #expect(hostedView.frame == contentView.bounds)
      }
    }
  }
}
