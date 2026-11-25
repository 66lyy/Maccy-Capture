import Testing
@testable import Maccy

@MainActor
struct CollectionSurroundingTests {
  @Test("Shortcut positions are one-based and reject integer extremes")
  func shortcutPositions() {
    let values = ConcatenatedCollection(["first"], ["last"])
    for number in [Int.min, -1, 0, 3, Int.max] { #expect(values.element(atOneBased: number) == nil) }
    #expect(values.element(atOneBased: 1) == "first")
    #expect(values.element(atOneBased: 2) == "last")
    #expect(ConcatenatedCollection<Int>([], []).element(atOneBased: 1) == nil)
  }

  let items = ["pin1", "pin2", "recent1", "recent2", "recent3"]

  @Test("Nearest item other than itself", arguments: [
    ("recent1", "recent2"),
    ("recent2", "recent3"),
    ("recent3", "recent2")
  ])
  func nearestItemOtherThanItself(current: String, expected: String) {
    #expect(items.nearest(to: current) { $0 != current } == expected)
  }

  @Test("Nearest is nil when nothing matches")
  func nearestIsNilWhenNothingMatches() {
    #expect(items.nearest(to: "recent1") { _ in false } == nil)
  }

  @Test("Nearest is nil for a missing item")
  func nearestIsNilForMissingItem() {
    #expect(items.nearest(to: "missing") { _ in true } == nil)
  }

  @Test("Nearest skips multiple excluded leading items")
  func testNearestWithMultipleLeadingMatchesExcluded() {
    let excluded: Set<String> = ["a", "b", "recent1"]
    let items = ["a", "b", "recent1", "recent2", "recent3"]
    #expect(items.nearest(to: "recent1") { !excluded.contains($0) } == "recent2")
  }
}
