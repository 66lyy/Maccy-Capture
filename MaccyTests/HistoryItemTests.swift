import AppKit
import Testing
import Defaults
import SwiftData
@testable import Maccy

// Match the on-disk schema immediately before recognizedText was added.
private enum HistoryBeforeOCRIndex {
  @Model
  final class HistoryItem {
    var application: String?
    var firstCopiedAt: Date = Date.now
    var lastCopiedAt: Date = Date.now
    var numberOfCopies: Int = 1
    var pin: String?
    var title = ""

    @Relationship(deleteRule: .cascade, inverse: \HistoryItemContent.item)
    var contents: [HistoryItemContent] = []

    init(title: String, pin: String? = nil, contents: [HistoryItemContent]) {
      self.title = title
      self.pin = pin
      self.contents = contents
    }
  }

  @Model
  final class HistoryItemContent {
    var type: String = ""
    var value: Data?
    @Relationship var item: HistoryItem?

    init(type: NSPasteboard.PasteboardType, value: Data) {
      self.type = type.rawValue
      self.value = value
    }
  }
}

func textImage(_ text: String) -> NSImage {
  let string = NSAttributedString(string: text, attributes: [
    .font: NSFont.boldSystemFont(ofSize: 48),
    .foregroundColor: NSColor.black
  ])
  let size = NSSize(width: string.size().width + 40, height: string.size().height + 40)
  return NSImage(size: size, flipped: false) { rect in
    NSColor.white.setFill()
    rect.fill()
    string.draw(at: NSPoint(x: 20, y: 20))
    return true
  }
}

private let stringTitleCases: [(input: String, title: String)] = [
  ("foo", "foo"),
  ("   foo bar   ", "···foo bar···"),
  ("\nfoo\nbar\n", "⏎foo⏎bar⏎"),
  ("\tfoo\tbar\t", "⇥foo⇥bar⇥")
]

private let objectReplacementTitleCases: [(input: String, title: String)] = [
  ("\u{FFFC}foo\u{FFFC}bar\u{FFFC}", "foobar"),
  ("\u{FFFC}\u{FFFC}", "")
]

extension SharedStateTests {
  @MainActor
  struct HistoryItemTests {
    @Test("History image export preserves PNG data and the original color image dimensions")
    func historyImageExport() throws {
      let image = textImage("History image export")
      let tiff = try #require(image.tiffRepresentation)
      let original = try #require(NSBitmapImageRep(data: tiff))
      let png = try #require(HistoryImagePreview.pngData(from: tiff))
      let exported = try #require(NSBitmapImageRep(data: png))
      #expect(exported.pixelsWide == original.pixelsWide)
      #expect(exported.pixelsHigh == original.pixelsHigh)
      #expect(HistoryImagePreview.pngData(from: png) == png)
      #expect(HistoryImagePreview.pngData(from: Data([1])) == nil)
    }

    @Test("Pre-index history migrates and remains searchable by title")
    func preIndexHistoryMigration() throws {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let configuration = ModelConfiguration(url: directory.appendingPathComponent("History.sqlite"))
      let imageData = try #require(textImage("Image Content").tiffRepresentation)
      let textData = Data("Clipboard note".utf8)
      try writePreIndexHistory(to: configuration, imageData: imageData, textData: textData)

      let migrated = try ModelContainer(for: HistoryItem.self, configurations: configuration)
      let context = ModelContext(migrated)
      let entries = try context.fetch(FetchDescriptor<HistoryItem>())
      try #require(entries.count == 2)
      #expect(entries.allSatisfy { $0.recognizedText == nil })

      let rows = entries.map { HistoryItemDecorator($0) }
      let originalSearchMode = Defaults[.searchMode]
      defer { Defaults[.searchMode] = originalSearchMode }
      let search = Search()
      for mode in Search.Mode.allCases {
        Defaults[.searchMode] = mode
        let screenshot = try #require(search.search(string: "Screenshot", within: rows).first?.object)
        #expect(screenshot.item.imageData == imageData)
        #expect(screenshot.item.pin == "b")
        let note = try #require(search.search(string: "Clipboard note", within: rows).first?.object)
        #expect(note.item.text == "Clipboard note")
      }
      Defaults[.searchMode] = .exact
      #expect(search.search(string: "Image Content", within: rows).isEmpty)
    }

    private func writePreIndexHistory(to configuration: ModelConfiguration, imageData: Data, textData: Data) throws {
      let legacy = try ModelContainer(for: HistoryBeforeOCRIndex.HistoryItem.self, configurations: configuration)
      let context = ModelContext(legacy)
      context.insert(HistoryBeforeOCRIndex.HistoryItem(
        title: "Screenshot", pin: "b", contents: [.init(type: .tiff, value: imageData)]
      ))
      context.insert(HistoryBeforeOCRIndex.HistoryItem(
        title: "Clipboard note", contents: [.init(type: .string, value: textData)]
      ))
      try context.save()
    }

    @Test("Sorted pins place letters before symbols")
    func sortedPinsPlacesLettersBeforeSymbols() {
      #expect(
        HistoryItem.sortedPins(["/", "c", "[", "b", "-", "\\", "y"]) ==
        ["b", "c", "y", "-", "/", "[", "\\"]
      )
    }

    @Test("Title for string", arguments: stringTitleCases)
    func titleForString(input: String, title: String) {
      #expect(historyItem(input).title == title)
    }

    // U+FFFC arrives from rich text with inline attachments and hangs CoreText
    // on macOS 26. See https://github.com/p0deje/Maccy/issues/1520.
    @Test("Title without object replacement characters", arguments: objectReplacementTitleCases)
    func titleWithObjectReplacementCharacters(input: String, title: String) {
      #expect(historyItem(input).title == title)
    }

    @Test("Title for RTF")
    func titleWithRTF() {
      let rtf = NSAttributedString(string: "foo").rtf(
        from: NSRange(0...2),
        documentAttributes: [:]
      )
      #expect(historyItem(rtf, .rtf).title == "foo")
    }

    @Test("Title for HTML")
    func titleWithHTML() {
      let html = "<a href='#'>foo</a>".data(using: .utf8)
      #expect(historyItem(html, .html).title == "foo")
    }

    @Test("Image has an empty title")
    func image() throws {
      let image = try #require(NSImage(named: "NSBluetoothTemplate"))
      #expect(historyItem(image).title == "")
    }

    @Test("HTML extracts visible text and ignores resource references")
    func offlineHTML() {
      let html = "<head><title>Hidden</title></head><p>合成 &amp; text<img src='https://fixture.invalid/a'></p><style>hidden</style><script>hidden</script><div>next<br>end</div>"
      #expect(ClipboardHTML.text(Data(html.utf8)) == "合成 & text\nnext\nend")
    }

    @Test("Non-local file representations never become preview or OCR inputs",
          arguments: ["https://fixture.invalid/image.jpeg", "file://fixture.invalid/image.jpeg"])
    func nonLocalFile(value: String) throws {
      let url = try #require(URL(string: value))
      let item = HistoryItem(contents: [
        HistoryItemContent(type: NSPasteboard.PasteboardType.fileURL.rawValue, value: url.dataRepresentation),
        HistoryItemContent(type: NSPasteboard.PasteboardType.universalClipboard.rawValue, value: Data())
      ])
      #expect(!url.isLocalClipboardFile)
      #expect(item.fileURLs.isEmpty && item.textRecognitionInput == nil && item.imageData == nil)
    }

    @Test("Image title becomes the recognized text")
    func imageTitleBecomesRecognizedText() async throws {
      let item = historyItem(textImage("Hello Maccy"))
      let decorator = History.shared.add(item)
      defer { History.shared.delete(decorator) }
      let deadline = ContinuousClock.now + .seconds(10)
      while item.title.isEmpty && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(100))
      }
      #expect(item.title == "Hello Maccy")
    }

    @Test("Clipboard OCR recognizes both image data and a local image file")
    func clipboardRecognitionInputs() async throws {
      let data = try #require(textImage("Hello Maccy").tiffRepresentation)
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("tiff")
      defer { try? FileManager.default.removeItem(at: url) }
      try data.write(to: url)

      let dataResult = await TextRecognition.recognizeClipboardImage(imageData: data, fileURL: nil)
      let fileResult = await TextRecognition.recognizeClipboardImage(imageData: nil, fileURL: url)
      #expect(dataResult == "Hello Maccy")
      #expect(fileResult == dataResult)
    }

    @Test("Concurrent screenshot and clipboard OCR return only their own text")
    func concurrentScreenshotAndClipboardRecognition() async throws {
      let screenshotImage = textImage("Quartz Harbor")
      let screenshot = try #require(screenshotImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
      let clipboard = try #require(textImage("Copper Lantern").tiffRepresentation)

      async let screenshotResult = TextRecognition.recognizeScreenshot(
        render: { screenshot }, operation: TextRecognition.recognizeScreenshot
      )
      async let clipboardResult = TextRecognition.recognizeClipboardImage(imageData: clipboard, fileURL: nil)
      let (screenshotText, clipboardText) = try await (screenshotResult, clipboardResult)

      #expect(screenshotText == "Quartz Harbor")
      #expect(clipboardText == "Copper Lantern")
    }

    @Test("Title for file", arguments: ["/tmp/foo.bar", "/tmp/产品培训/产品培训.txt"])
    func file(path: String) {
      let url = URL(fileURLWithPath: path)
      #expect(historyItem(url).title == "file://\(path)")
    }

    @Test("Text from Universal Clipboard")
    func textFromUniversalClipboard() {
      let url = URL(fileURLWithPath: "/tmp/foo.bar")
      let fileURLContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: url.dataRepresentation
      )
      let textContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: url.lastPathComponent.data(using: .utf8)
      )
      let universalClipboardContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
        value: "".data(using: .utf8)
      )
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [fileURLContent, textContent, universalClipboardContent]
      item.title = item.generateTitle()
      #expect(item.title == "foo.bar")
    }

    @Test("Image from Universal Clipboard")
    func imageFromUniversalClipboard() throws {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpeg")
      let bitmap = try #require(textImage("Fixture").tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
      try #require(bitmap.representation(using: .jpeg, properties: [:])).write(to: url)
      defer { try? FileManager.default.removeItem(at: url) }
      let fileURLContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: url.dataRepresentation
      )
      let universalClipboardContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
        value: "".data(using: .utf8)
      )
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [fileURLContent, universalClipboardContent]
      let image = try #require(item.image)
      let expected = try #require(NSImage(data: try Data(contentsOf: url)))
      #expect(image.tiffRepresentation == expected.tiffRepresentation)
    }

    @Test("File from Universal Clipboard")
    func fileFromUniversalClipboard() {
      let url = URL(fileURLWithPath: "/tmp/foo.bar")
      let fileURLContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: url.dataRepresentation
      )
      let universalClipboardContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
        value: "".data(using: .utf8)
      )
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [fileURLContent, universalClipboardContent]
      item.title = item.generateTitle()
      #expect(item.title == "file:///tmp/foo.bar")
    }

    @Test("Item without data has an empty title")
    func itemWithoutData() {
      #expect(historyItem(nil).title == "")
    }

    @Test("Several items can have an empty pin")
    func severalItemsCanHaveEmptyPin() {
      let item1 = historyItem("foo")
      item1.pin = ""
      let item2 = historyItem("bar")
      item2.pin = ""
      #expect(throws: Never.self) {
        try Storage.shared.context.save()
      }
      #expect(item1.pin == "")
      #expect(item2.pin == "")
    }

    private func historyItem(_ value: String?) -> HistoryItem {
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

      return item
    }

    private func historyItem(_ data: Data?, _ type: NSPasteboard.PasteboardType) -> HistoryItem {
      let contents = [
        HistoryItemContent(
          type: type.rawValue,
          value: data
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()

      return item
    }

    private func historyItem(_ value: NSImage) -> HistoryItem {
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

      return item
    }

    private func historyItem(_ value: URL) -> HistoryItem {
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

      return item
    }
  }
}
