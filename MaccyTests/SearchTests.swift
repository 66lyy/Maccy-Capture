import AppKit
import Testing
import Defaults
@testable import Maccy

extension SharedStateTests {
  @MainActor
  final class SearchTests {
    let savedSearchMode = Defaults[.searchMode]
    let items: [Search.Searchable]

    init() {
      items = [
        HistoryItemDecorator(Self.historyItemWithTitle("foo bar baz")),
        HistoryItemDecorator(Self.historyItemWithTitle("foo bar zaz")),
        HistoryItemDecorator(Self.historyItemWithTitle("xxx yyy zzz"))
      ]
    }

    deinit {
      Defaults[.searchMode] = savedSearchMode
    }

    @Test("Image text matches without producing highlight ranges for an unrelated title",
          arguments: Search.Mode.allCases)
    func imageTextSearch(mode: Search.Mode) throws {
      Defaults[.searchMode] = mode
      let item = Self.historyItemWithTitle("Screenshot")
      item.recognizedText = "The second line reads:\nQuartz Harbor"
      let screenshot = HistoryItemDecorator(item)
      let query = mode == .regexp ? "Quartz Harb.r$" : "Quartz Harbor"
      let result = try #require(Search().search(string: query, within: items + [screenshot]).first)
      #expect(result.object == screenshot)
      #expect(result.ranges.isEmpty)
    }

    @Test("Image tags restrict all search modes while keeping OCR matches", arguments: Search.Mode.allCases)
    func imageTag(mode: Search.Mode) {
      Defaults[.searchMode] = mode
      let item = HistoryItem(contents: [HistoryItemContent(type: NSPasteboard.PasteboardType.png.rawValue,
                                                           value: Data([1]))])
      item.title = "Screenshot"
      item.recognizedText = "Quartz Harbor"
      let screenshot = HistoryItemDecorator(item)
      let candidates = [HistoryItemDecorator(Self.historyItemWithTitle("Quartz Harbor")), screenshot]
      let search = Search()
      #expect(search.search(string: "#IMAGE", within: candidates).map(\.object) == [screenshot])
      let result = search.search(string: " #image  Quartz Harbor", within: candidates)
      #expect(result.map(\.object) == [screenshot])
      #expect(result.first?.ranges.isEmpty == true)
      #expect(search.search(string: "#image no-match", within: candidates).isEmpty)
    }

    @Test("Code tags narrow text results and leave unknown tags literal")
    func codeTag() {
      Defaults[.searchMode] = .exact
      let code = HistoryItemDecorator(Self.historyItemWithTitle("func greet() {}"))
      let prose = HistoryItemDecorator(Self.historyItemWithTitle("Please greet the team"))
      let literal = HistoryItemDecorator(Self.historyItemWithTitle("#imageable"))
      let candidates = [prose, code, literal]
      let search = Search()
      #expect(search.search(string: "#code greet", within: candidates).map(\.object) == [code])
      #expect(search.search(string: "#imageable", within: candidates).map(\.object) == [literal])
      #expect(search.search(string: "greet", within: candidates).map(\.object) == [prose, code])
    }

    @Test("Code tag validates the complete JSON document, not its prefix")
    func longJSON() {
      let text = "[\"" + String(repeating: "x", count: 8192) + "\"]"
      let valid = HistoryItemDecorator(Self.historyItemWithTitle(text))
      let invalid = HistoryItemDecorator(Self.historyItemWithTitle(text + "invalid"))
      #expect(Search().search(string: "#code", within: [invalid, valid]).map(\.object) == [valid])
    }

    @Test("Cycling filters preserves the text query")
    func cycleTags() {
      let imageQuery = Search.Query("harbor  view ").cyclingTag
      #expect(imageQuery == "#image harbor  view ")
      let codeQuery = Search.Query(imageQuery).cyclingTag
      #expect(codeQuery == "#code harbor  view ")
      #expect(Search.Query(codeQuery).cyclingTag == "harbor  view ")
      #expect(Search.Query("").cyclingTag == "#image ")
    }

    @Test("Simple search")
    func simpleSearch() { // swiftlint:disable:this function_body_length
      Defaults[.searchMode] = Search.Mode.exact
      #expect(search("") == [
        Search.SearchResult(score: nil, object: items[0], ranges: []),
        Search.SearchResult(score: nil, object: items[1], ranges: []),
        Search.SearchResult(score: nil, object: items[2], ranges: [])
      ])
      #expect(search("z") == [
        Search.SearchResult(
          score: nil,
          object: items[0],
          ranges: [range(from: 10, to: 10, in: items[0])]
        ),
        Search.SearchResult(
          score: nil,
          object: items[1],
          ranges: [range(from: 8, to: 8, in: items[1])]
        ),
        Search.SearchResult(
          score: nil,
          object: items[2],
          ranges: [range(from: 8, to: 8, in: items[2])]
        )
      ])
      #expect(search("foo") == [
        Search.SearchResult(
          score: nil,
          object: items[0],
          ranges: [range(from: 0, to: 2, in: items[0])]
        ),
        Search.SearchResult(
          score: nil,
          object: items[1],
          ranges: [range(from: 0, to: 2, in: items[1])]
        )
      ])
      #expect(search("za") == [
        Search.SearchResult(
          score: nil,
          object: items[1],
          ranges: [range(from: 8, to: 9, in: items[1])]
        )
      ])
      #expect(search("yyy") == [
        Search.SearchResult(
          score: nil,
          object: items[2],
          ranges: [range(from: 4, to: 6, in: items[2])]
        )
      ])
      #expect(search("fbb") == [])
      #expect(search("m") == [])
    }

    @Test("Fuzzy search")
    func fuzzySearch() { // swiftlint:disable:this function_body_length
      Defaults[.searchMode] = Search.Mode.fuzzy
      #expect(search("") == [
        Search.SearchResult(score: nil, object: items[0], ranges: []),
        Search.SearchResult(score: nil, object: items[1], ranges: []),
        Search.SearchResult(score: nil, object: items[2], ranges: [])
      ])
      #expect(search("z") == [
        Search.SearchResult(
          score: 0.08,
          object: items[1],
          ranges: [range(from: 8, to: 8, in: items[1]), range(from: 10, to: 10, in: items[1])]
        ),
        Search.SearchResult(
          score: 0.08,
          object: items[2],
          ranges: [range(from: 8, to: 10, in: items[2])]
        ),
        Search.SearchResult(
          score: 0.1,
          object: items[0],
          ranges: [range(from: 10, to: 10, in: items[0])]
        )
      ])
      #expect(search("foo") == [
        Search.SearchResult(
          score: 0.0,
          object: items[0],
          ranges: [range(from: 0, to: 2, in: items[0])]
        ),
        Search.SearchResult(
          score: 0.0,
          object: items[1],
          ranges: [range(from: 0, to: 2, in: items[1])]
        )
      ])
      #expect(search("za") == [
        Search.SearchResult(
          score: 0.08,
          object: items[1],
          ranges: [range(from: 5, to: 5, in: items[1]), range(from: 8, to: 9, in: items[1])]
        ),
        Search.SearchResult(
          score: 0.54,
          object: items[0],
          ranges: [range(from: 5, to: 5, in: items[0]), range(from: 9, to: 10, in: items[0])]
        ),
        Search.SearchResult(
          score: 0.58,
          object: items[2],
          ranges: [range(from: 8, to: 10, in: items[2])]
        )
      ])
      #expect(search("yyy") == [
        Search.SearchResult(
          score: 0.04,
          object: items[2],
          ranges: [range(from: 4, to: 6, in: items[2])]
        )
      ])
      #expect(search("fbb") == [
        Search.SearchResult(
          score: 0.6666666666666666,
          object: items[0],
          ranges: [
            range(from: 0, to: 0, in: items[0]),
            range(from: 4, to: 4, in: items[0]),
            range(from: 8, to: 8, in: items[0])
          ]
        ),
        Search.SearchResult(
          score: 0.6666666666666666,
          object: items[1],
          ranges: [range(from: 0, to: 0, in: items[1]), range(from: 4, to: 4, in: items[1])])
      ])
      #expect(search("m") == [])
    }

    @Test("Regexp search")
    func regexpSearch() { // swiftlint:disable:this function_body_length
      Defaults[.searchMode] = Search.Mode.regexp
      #expect(search("") == [
        Search.SearchResult(score: nil, object: items[0], ranges: []),
        Search.SearchResult(score: nil, object: items[1], ranges: []),
        Search.SearchResult(score: nil, object: items[2], ranges: [])
      ])
      #expect(search("z+") == [
        Search.SearchResult(
          score: nil,
          object: items[0],
          ranges: [range(from: 10, to: 10, in: items[0])]
        ),
        Search.SearchResult(
          score: nil,
          object: items[1],
          ranges: [range(from: 8, to: 8, in: items[1])]
        ),
        Search.SearchResult(
          score: nil,
          object: items[2],
          ranges: [range(from: 8, to: 10, in: items[2])]
        )
      ])
      #expect(search("z*") == [
        Search.SearchResult(
          score: nil,
          object: items[0],
          ranges: [range(from: 0, to: -1, in: items[0])]
        ),
        Search.SearchResult(
          score: nil,
          object: items[1],
          ranges: [range(from: 0, to: -1, in: items[1])]
        ),
        Search.SearchResult(
          score: nil,
          object: items[2],
          ranges: [range(from: 0, to: -1, in: items[2])]
        )
      ])
      #expect(search("^foo") == [
        Search.SearchResult(
          score: nil,
          object: items[0], ranges: [range(from: 0, to: 2, in: items[0])]
        ),
        Search.SearchResult(
          score: nil,
          object: items[1], ranges: [range(from: 0, to: 2, in: items[1])]
        )
      ])
      #expect(search(" za") == [
        Search.SearchResult(
          score: nil,
          object: items[1],
          ranges: [range(from: 7, to: 9, in: items[1])]
        )
      ])
      #expect(search("[y]+") == [
        Search.SearchResult(
          score: nil,
          object: items[2],
          ranges: [range(from: 4, to: 6, in: items[2])]
        )
      ])
      #expect(search("fbb") == [])
      #expect(search("m") == [])
    }

    private func search(_ string: String) -> [Search.SearchResult] {
      return Search().search(string: string, within: items)
    }

    // swiftlint:disable:next identifier_name
    private func range(from: Int, to: Int, in item: HistoryItemDecorator) -> Range<String.Index> {
      let startIndex = item.title.startIndex
      let lowerBound = item.title.index(startIndex, offsetBy: from)
      let upperBound = item.title.index(startIndex, offsetBy: to + 1)

      return lowerBound..<upperBound
    }

    private static func historyItemWithTitle(_ value: String?) -> HistoryItem {
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
  }
}
