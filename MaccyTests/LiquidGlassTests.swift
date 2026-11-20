import AppKit
import Defaults
import Testing
@testable import Maccy

@MainActor
@Suite(.serialized)
struct LiquidGlassTests {
  @Test("The glass transparency setting defaults to the standard clear glass look")
  func defaultTransparency() {
    #expect(Defaults.Keys.glassTransparency.defaultValue == LiquidGlass.defaultTransparency)
    #expect(LiquidGlass.dimmingAlpha(transparency: LiquidGlass.defaultTransparency, dark: true) == 0.22)
    #expect(LiquidGlass.dimmingAlpha(transparency: LiquidGlass.defaultTransparency, dark: false) == 0.18)
  }

  @Test("More transparency means less dimming, down to none")
  func mapping() {
    for dark in [true, false] {
      let values = stride(from: 0.0, through: 1.0, by: 0.1).map { LiquidGlass.dimmingAlpha(transparency: $0, dark: dark) }
      #expect(zip(values, values.dropFirst()).allSatisfy { $0 > $1 })
      #expect(values.first == 0.6)
      #expect(values.last == 0)
    }
    #expect(LiquidGlass.dimmingAlpha(transparency: -1, dark: true) == 0.6)
    #expect(LiquidGlass.dimmingAlpha(transparency: 2, dark: false) == 0)
  }

  @Test("The dimming color follows light and dark appearance")
  func dimmingColor() throws {
    let color = LiquidGlass.clearDimming(transparency: 0.75)
    var dark = NSColor.clear
    var light = NSColor.clear
    try #require(NSAppearance(named: .darkAqua)).performAsCurrentDrawingAppearance {
      dark = color.usingColorSpace(.sRGB) ?? .clear
    }
    try #require(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance {
      light = color.usingColorSpace(.sRGB) ?? .clear
    }
    #expect(abs(dark.alphaComponent - 0.11) < 0.001)
    #expect(dark.brightnessComponent == 0)
    #expect(abs(light.alphaComponent - 0.09) < 0.001)
    #expect(light.brightnessComponent == 1)
  }
}
