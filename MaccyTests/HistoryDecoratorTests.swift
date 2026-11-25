import AppKit
import Testing
import Defaults
@testable import Maccy

extension SharedStateTests {
  @MainActor
  final class HistoryItemDecoratorTests {
    let savedHighlightMatch = Defaults[.highlightMatch]
    let savedImageMaxHeight = Defaults[.imageMaxHeight]

    let firstCopiedAt = Date(timeIntervalSince1970: 1_594_384_294)
    var lastCopiedAt: Date { firstCopiedAt.addingTimeInterval(600) }

    init() {
      Defaults[.highlightMatch] = .bold
      Defaults[.imageMaxHeight] = 40
    }

    deinit {
      Defaults[.imageMaxHeight] = savedImageMaxHeight
      Defaults[.highlightMatch] = savedHighlightMatch
    }

    @Test("String")
    func string() {
      let title = "foo"
      let itemDecorator = historyItemDecorator(title)
      #expect(itemDecorator.title == title)
      #expect(itemDecorator.previewImage == nil)
      #expect(itemDecorator.thumbnailImage == nil)
    }

    @Test("RTF")
    func rtf() {
      let rtf = NSAttributedString(string: "foo").rtf(
        from: NSRange(0...2),
        documentAttributes: [:]
      )
      let itemDecorator = historyItemDecorator(rtf, .rtf)
      #expect(itemDecorator.cachedPreviewText == nil)
      #expect(itemDecorator.hasRichText)
      #expect(itemDecorator.previewText.string == "foo")
      #expect(itemDecorator.title == "foo")
      #expect(itemDecorator.previewImage == nil)
      #expect(itemDecorator.thumbnailImage == nil)
    }

    @Test("HTML")
    func html() {
      let html = "<a href='#'>foo</a>".data(using: .utf8)
      let itemDecorator = historyItemDecorator(html, .html)
      #expect(itemDecorator.cachedPreviewText == nil)
      #expect(itemDecorator.hasRichText)
      #expect(itemDecorator.previewText.string == "foo")
      #expect(itemDecorator.title == "foo")
      #expect(itemDecorator.previewImage == nil)
      #expect(itemDecorator.thumbnailImage == nil)
    }

    @Test("Preview text is lazy, cached and invalidated without eagerly rebuilding")
    func lazyPreviewText() async {
      let decorator = historyItemDecorator("first")
      #expect(decorator.cachedPreviewText == nil)
      #expect(decorator.previewText.string == "first")
      #expect(decorator.cachedPreviewText?.string == "first")
      #expect(decorator.previewText.string == "first")
      decorator.item.contents[0].value = Data("second".utf8)
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
      #expect(decorator.cachedPreviewText == nil)
      #expect(decorator.previewText.string == "second")
    }

    @Test("Empty previews lazily follow fallback title changes")
    func lazyEmptyPreviewText() async {
      let decorator = historyItemDecorator(nil)
      #expect(decorator.cachedPreviewText == nil)
      #expect(decorator.previewText.string.isEmpty)
      decorator.item.title = "Recognized text"
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
      #expect(decorator.cachedPreviewText == nil)
      #expect(decorator.previewText.string == "Recognized text")
    }

    @Test("Search reads titles without materializing preview text")
    func searchDoesNotBuildPreviewText() {
      let savedSearchMode = Defaults[.searchMode]
      defer { Defaults[.searchMode] = savedSearchMode }
      let decorator = historyItemDecorator("foo")
      decorator.item.contents[0].value = Data("unrelated preview".utf8)
      for mode in Search.Mode.allCases {
        Defaults[.searchMode] = mode
        #expect(Search().search(string: "foo", within: [decorator]).first?.object === decorator)
        #expect(decorator.cachedPreviewText == nil)
      }
    }

    @Test("Image")
    func image() throws {
      let image = try #require(NSImage(named: "StatusBarMenuImage"))
      let itemDecorator = historyItemDecorator(image)
      itemDecorator.sizeImages()
      #expect(itemDecorator.title == "")
      #expect(try #require(itemDecorator.previewImage).size == image.size)
      #expect(try #require(itemDecorator.thumbnailImage).size == image.size)
    }

    // We also need to add test for image with width bigger than max width.
    @Test("Image with height bigger than max height")
    func imageWithHeightBiggerThanMaxHeight() throws {
      let image = try #require(NSImage(named: "NSApplicationIcon"))
      let itemDecorator = historyItemDecorator(image)
      itemDecorator.sizeImages()
      #expect(try #require(itemDecorator.thumbnailImage).size == NSSize(width: 40, height: 40))
    }

    @Test("Rich text capability uses data presence", arguments: [NSPasteboard.PasteboardType.rtf, .html])
    func richTextPresence(type: NSPasteboard.PasteboardType) {
      let decorator = historyItemDecorator("foo")
      #expect(!decorator.hasRichText)
      let content = HistoryItemContent(type: type.rawValue)
      decorator.item.contents.append(content)
      #expect(!decorator.hasRichText)
      content.value = Data([0xFF])
      #expect(decorator.hasRichText)
      content.value = Data()
      #expect(decorator.hasRichText)
    }

    @Test("File", arguments: ["/tmp/foo.bar", "/tmp/产品培训/产品培训.txt"])
    func file(path: String) {
      let url = URL(fileURLWithPath: path)
      let itemDecorator = historyItemDecorator(url)
      #expect(itemDecorator.title == "file://\(path)")
      #expect(itemDecorator.previewImage == nil)
      #expect(itemDecorator.thumbnailImage == nil)
    }

    @Test("Item without data")
    func itemWithoutData() {
      let itemDecorator = historyItemDecorator(nil)
      #expect(itemDecorator.title == "")
      #expect(itemDecorator.previewImage == nil)
      #expect(itemDecorator.thumbnailImage == nil)
    }

    @Test("Unpinned by default")
    func unpinnedByDefault() {
      let itemDecorator = historyItemDecorator("foo")
      #expect(itemDecorator.item.pin == nil)
      #expect(!itemDecorator.isPinned)
    }

    @Test("Deallocates when no longer referenced")
    func deallocatesWhenNoLongerReferenced() {
      weak var weakDecorator: HistoryItemDecorator?

      autoreleasepool {
        let itemDecorator = historyItemDecorator("foo")
        weakDecorator = itemDecorator
        #expect(weakDecorator != nil)
      }

      #expect(weakDecorator == nil)
    }

    @Test("Highlight")
    func highlight() throws {
      let itemDecorator = historyItemDecorator("foo bar baz")
      itemDecorator.highlight("random", [
        range(from: 1, to: 2, in: itemDecorator),
        range(from: 8, to: 10, in: itemDecorator)
      ])
      var expectedTitle = AttributedString("foo bar baz")
      expectedTitle[try #require(expectedTitle.range(of: "oo"))].font = .bold(.body)()
      expectedTitle[try #require(expectedTitle.range(of: "baz"))].font = .bold(.body)()
      #expect(itemDecorator.attributedTitle == expectedTitle)
      itemDecorator.highlight("", [])
      #expect(itemDecorator.attributedTitle == nil)
    }

    private func historyItemDecorator(
      _ value: String?,
      application: String? = "com.apple.finder"
    ) -> HistoryItemDecorator {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value?.data(using: .utf8)
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()
      item.application = application
      item.firstCopiedAt = firstCopiedAt
      item.lastCopiedAt = lastCopiedAt

      return HistoryItemDecorator(item)
    }

    private func historyItemDecorator(
      _ value: Data?,
      _ type: NSPasteboard.PasteboardType
    ) -> HistoryItemDecorator {
      let contents = [
        HistoryItemContent(
          type: type.rawValue,
          value: value
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()
      item.application = "com.apple.finder"
      item.firstCopiedAt = firstCopiedAt
      item.lastCopiedAt = lastCopiedAt
      item.numberOfCopies = 2

      return HistoryItemDecorator(item)
    }

    private func historyItemDecorator(_ value: NSImage) -> HistoryItemDecorator {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.tiff.rawValue,
          value: value.tiffRepresentation
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()
      item.application = "com.apple.finder"
      item.firstCopiedAt = firstCopiedAt
      item.lastCopiedAt = lastCopiedAt
      item.numberOfCopies = 2

      return HistoryItemDecorator(item)
    }

    private func historyItemDecorator(_ value: URL) -> HistoryItemDecorator {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.fileURL.rawValue,
          value: value.dataRepresentation
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value.lastPathComponent.data(using: .utf8)
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()
      item.application = "com.apple.finder"
      item.firstCopiedAt = firstCopiedAt
      item.lastCopiedAt = lastCopiedAt
      item.numberOfCopies = 2

      return HistoryItemDecorator(item)
    }

    // swiftlint:disable:next identifier_name
    private func range(from: Int, to: Int, in item: HistoryItemDecorator) -> Range<String.Index> {
      let startIndex = item.title.startIndex
      let lowerBound = item.title.index(startIndex, offsetBy: from)
      let upperBound = item.title.index(startIndex, offsetBy: to + 1)

      return lowerBound..<upperBound
    }
  }
}
