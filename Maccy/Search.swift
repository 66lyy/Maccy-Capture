import AppKit
import Defaults
import Fuse

class Search {
  enum Mode: String, CaseIterable, Identifiable, CustomStringConvertible, Defaults.Serializable {
    case exact
    case fuzzy
    case regexp
    case mixed

    var id: Self { self }

    var description: String {
      switch self {
      case .exact:
        return NSLocalizedString("Exact", tableName: "GeneralSettings", comment: "")
      case .fuzzy:
        return NSLocalizedString("Fuzzy", tableName: "GeneralSettings", comment: "")
      case .regexp:
        return NSLocalizedString("Regex", tableName: "GeneralSettings", comment: "")
      case .mixed:
        return NSLocalizedString("Mixed", tableName: "GeneralSettings", comment: "")
      }
    }
  }

  struct SearchResult: Equatable {
    var score: Double?
    var object: Searchable
    var ranges: [Range<String.Index>] = []
  }

  typealias Searchable = HistoryItemDecorator

  enum Tag: String, CaseIterable {
    case image
    case code

    private static let codePattern = [
      #"^\s*(?:func|def|function|fn)\s+\w+\s*\("#,
      #"^\s*(?:const|let|var|val)\s+\w+[^\n=]*="#,
      #"^\s*(?:class|struct|enum)\s+\w+[^\n]*[{:]"#,
      #"^\s*#include\s*[<"]"#,
      #"^\s*<(?:\?xml|!DOCTYPE|html\b)"#,
      #"^\s*select\b[^\n]+\bfrom\b"#
    ].joined(separator: "|")

    func matches(_ item: Searchable) -> Bool {
      switch self {
      case .image:
        return item.item.textRecognitionInput != nil
      case .code:
        guard let text = item.item.text else { return false }
        return Self.looksLikeCode(text)
      }
    }

    private static func looksLikeCode(_ text: String) -> Bool {
      let sample = String(text.prefix(4096)).trimmingCharacters(in: .whitespacesAndNewlines)
      if sample.hasPrefix("```") || sample.hasPrefix("#!") { return true }
      if JSONFormatter.looksLikeContainer(sample),
         (try? JSONSerialization.jsonObject(with: Data(sample.utf8))) != nil { return true }
      return sample.range(
        of: "(?im)" + codePattern,
        options: .regularExpression
      ) != nil
    }
  }

  struct Query {
    let tag: Tag?
    let text: String

    init(_ query: String) {
      if let token = query.split(maxSplits: 1, whereSeparator: \.isWhitespace).first,
         token.first == "#", let filter = Tag(rawValue: token.dropFirst().lowercased()) {
        tag = filter
        text = String(query[token.endIndex...].drop(while: \.isWhitespace))
      } else {
        tag = nil
        text = query
      }
    }

    var cyclingTag: String {
      let tags = Tag.allCases
      let nextIndex = tag.flatMap { tags.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
      guard nextIndex < tags.count else { return text }
      return "#\(tags[nextIndex].rawValue) \(text)"
    }
  }

  private let fuse = Fuse(threshold: 0.7, isCaseSensitive: true) // threshold found by trial-and-error
  private let fuzzySearchLimit = 5_000

  func search(string: String, within: [Searchable]) -> [SearchResult] {
    let query = Query(string)
    let string = query.text
    let within = query.tag.map { tag in within.filter(tag.matches) } ?? within
    guard !string.isEmpty else {
      return within.map { SearchResult(object: $0) }
    }

    switch Defaults[.searchMode] {
    case .mixed:
      return mixedSearch(string: string, within: within)
    case .regexp:
      return simpleSearch(string: string, within: within, options: .regularExpression)
    case .fuzzy:
      return fuzzySearch(string: string, within: within)
    default:
      return simpleSearch(string: string, within: within, options: .caseInsensitive)
    }
  }

  private func fuzzySearch(string: String, within: [Searchable]) -> [SearchResult] {
    let patternText = string.lowercased()
    guard patternText.count <= Int.bitWidth else {
      return simpleSearch(string: string, within: within, options: .caseInsensitive)
    }
    guard let pattern = fuse.createPattern(from: patternText) else { return [] }
    let searchResults: [SearchResult] = within.compactMap { item in
      let titleMatch = fuzzySearch(for: pattern, in: item.title, of: item)
      guard let text = item.item.recognizedText, text != item.title,
            let imageMatch = fuzzySearch(for: pattern, in: text, of: item, highlight: false) else { return titleMatch }
      guard let titleMatch else { return imageMatch }
      return (imageMatch.score ?? 0) < (titleMatch.score ?? 0) ? imageMatch : titleMatch
    }
    let sortedResults = searchResults.sorted(by: { ($0.score ?? 0) < ($1.score ?? 0) })
    return sortedResults
  }

  private func fuzzySearch(
    for pattern: Fuse.Pattern,
    in searchString: String,
    of item: Searchable,
    highlight: Bool = true
  ) -> SearchResult? {
    var searchString = searchString
    if searchString.count > fuzzySearchLimit {
      // shortcut to avoid slow search
      let stopIndex = searchString.index(searchString.startIndex, offsetBy: fuzzySearchLimit)
      searchString = "\(searchString[...stopIndex])"
    }

    let normalized = searchString.lowercased()
    // A literal match in this suffix would make Fuse's Character-indexed match mask overrun.
    if normalized.suffix(pattern.len - 1).range(of: pattern.text, options: .literal) != nil {
      return SearchResult(score: 0, object: item)
    }

    if let fuzzyResult = fuse.search(pattern, in: normalized) {
      return SearchResult(
        score: fuzzyResult.score,
        object: item,
        ranges: highlight ? fuzzyResult.ranges.map {
          let startIndex = searchString.startIndex
          let lowerBound = searchString.index(startIndex, offsetBy: $0.lowerBound)
          let upperBound = searchString.index(startIndex, offsetBy: $0.upperBound + 1)

          return lowerBound..<upperBound
        } : []
      )
    } else {
      return nil
    }
  }

  private func simpleSearch(
    string: String,
    within: [Searchable],
    options: NSString.CompareOptions
  ) -> [SearchResult] {
    return within.compactMap { simpleSearch(for: string, in: $0.title, of: $0, options: options) }
  }

  private func simpleSearch(
    for string: String,
    in searchString: String,
    of item: Searchable,
    options: NSString.CompareOptions
  ) -> SearchResult? {
    if let range = searchString.range(of: string, options: options, range: nil, locale: nil) {
      return SearchResult(object: item, ranges: [range])
    } else if let text = item.item.recognizedText, text != searchString,
              text.range(of: string, options: options, range: nil, locale: nil) != nil {
      return SearchResult(object: item)
    } else {
      return nil
    }
  }

  private func mixedSearch(string: String, within: [Searchable]) -> [SearchResult] {
    var results = simpleSearch(string: string, within: within, options: .caseInsensitive)
    guard results.isEmpty else {
      return results
    }

    results = simpleSearch(string: string, within: within, options: .regularExpression)
    guard results.isEmpty else {
      return results
    }

    results = fuzzySearch(string: string, within: within)
    guard results.isEmpty else {
      return results
    }

    return []
  }
}
