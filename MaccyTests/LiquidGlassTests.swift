import AppKit
import Defaults
import Testing
@testable import Maccy

@MainActor
@Suite(.serialized)
struct LiquidGlassTests {
  @Test("Glass defaults to the frosted style at the standard transparency")
  func defaults() {
    #expect(Defaults.Keys.glassStyle.defaultValue == .frosted)
    #expect(Defaults.Keys.glassTransparency.defaultValue == LiquidGlass.defaultTransparency)
  }

  @Test("Each style keeps its standard look at the default transparency")
  func standardLook() {
    let middle = LiquidGlass.defaultTransparency
    #expect(LiquidGlass.dimmingAlpha(transparency: middle, dark: true, style: .clear) == 0.22)
    #expect(LiquidGlass.dimmingAlpha(transparency: middle, dark: false, style: .clear) == 0.18)
    #expect(LiquidGlass.dimmingAlpha(transparency: middle, dark: true, style: .frosted) == 0.06)
    #expect(LiquidGlass.dimmingAlpha(transparency: middle, dark: false, style: .frosted) == 0.06)
  }

  @Test("More transparency means less dimming, down to none", arguments: GlassStyle.allCases)
  func mapping(style: GlassStyle) {
    for dark in [true, false] {
      let values = stride(from: 0.0, through: 1.0, by: 0.1).map {
        LiquidGlass.dimmingAlpha(transparency: $0, dark: dark, style: style)
      }
      #expect(zip(values, values.dropFirst()).allSatisfy { $0 > $1 })
      #expect(abs((values.first ?? 0) - 0.6) < 0.0001)
      #expect(values.last == 0)
    }
    #expect(abs(LiquidGlass.dimmingAlpha(transparency: -1, dark: true, style: style) - 0.6) < 0.0001)
    #expect(LiquidGlass.dimmingAlpha(transparency: 2, dark: false, style: style) == 0)
  }

  @available(macOS 26.0, *)
  @Test("Each style maps to the matching glass effect")
  func effectStyle() {
    #expect(LiquidGlass.effectStyle(.frosted) == .regular)
    #expect(LiquidGlass.effectStyle(.clear) == .clear)
  }

  @Test("The dimming color follows light and dark appearance")
  func dimmingColor() throws {
    let color = LiquidGlass.dimming(transparency: 0.75, style: .clear)
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
