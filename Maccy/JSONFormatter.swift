import Foundation

nonisolated enum JSONFormatter {
  enum Style: String, Sendable { case pretty, compact }
  enum Kind: Sendable { case key, string, number, literal, punctuation }
  struct Token: Equatable, Sendable {
    let kind: Kind
    let range: NSRange
  }
  struct Document: Equatable, Sendable {
    let text: String
    let tokens: [Token]
  }
  struct Failure: Error, Equatable, Sendable {
    let message: String
    let line: Int
    let column: Int
  }
  enum Result: Equatable, Sendable {
    case success(Document)
    case failure(Failure)
    case cancelled
  }

  static let automaticLimit = 1_048_576

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    byte == 32 || byte == 9 || byte == 10 || byte == 13
  }

  static func looksLikeContainer(_ text: String) -> Bool {
    let bytes = text.utf8
    guard let first = bytes.first(where: { !isWhitespace($0) }),
      let last = bytes.reversed().first(where: { !isWhitespace($0) }) else { return false }
    return (first == 123 && last == 125) || (first == 91 && last == 93)
  }

  static func isCandidate(_ text: String) -> Bool {
    text.utf8.count < automaticLimit && looksLikeContainer(text)
  }

  private final class Entry: NSObject {
    let result: Result
    init(_ result: Result) { self.result = result }
  }

  private final class Cache: @unchecked Sendable {
    let values = NSCache<NSString, Entry>()
    init() {
      values.countLimit = 32
      values.totalCostLimit = 16 * 1_048_576
    }
  }
  private static let cache = Cache()

  static func format(_ text: String, style: Style = .pretty) -> Result {
    guard !Task.isCancelled else { return .cancelled }
    let key = (style.rawValue + ":" + text) as NSString
    if let entry = cache.values.object(forKey: key) { return entry.result }
    var scanner = Scanner(text: text, style: style)
    let result: Result
    do {
      result = .success(try scanner.scan())
    } catch let failure as Failure {
      result = .failure(failure)
    } catch {
      return .cancelled
    }
    guard !Task.isCancelled else { return .cancelled }
    var cost = text.utf8.count * 2
    if case .success(let document) = result {
      cost += document.text.utf8.count + document.tokens.count * MemoryLayout<Token>.stride
    }
    if cost <= 16 * 1_048_576 {
      cache.values.setObject(Entry(result), forKey: key, cost: cost)
    }
    return result
  }

  static func whitespaceOutsideStringsRemoved(_ text: String) -> String {
    var quoted = false
    var escaped = false
    var output: [UInt8] = []
    for byte in text.utf8 {
      if quoted || !isWhitespace(byte) { output.append(byte) }
      if quoted {
        if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
      } else if byte == 34 { quoted = true }
    }
    return String(decoding: output, as: UTF8.self)
  }

  private struct Scanner {
    enum State { case objectFirst, key, colon, value, arrayFirst, objectNext, arrayNext, done }
    let style: Style
    var bytes: [UInt8]
    var index = 0
    var nextCancellationCheck = 0
    var output = ""
    var offset = 0
    var tokens: [Token] = []
    var states: [State] = [.value]

    init(text: String, style: Style) {
      self.style = style
      self.bytes = Array(text.utf8)
    }

    mutating func advance() throws {
      index += 1
      if index >= nextCancellationCheck {
        try Task.checkCancellation()
        nextCancellationCheck = index + 65_536
      }
    }

    func fail(_ message: String) -> Failure {
      let prefix = String(decoding: bytes[..<index], as: UTF8.self)
      var line = 1
      var column = 1
      for character in prefix {
        if character == "\n" || character == "\r\n" || character == "\r" {
          line += 1
          column = 1
        } else { column += 1 }
      }
      return Failure(message: message, line: line, column: column)
    }

    mutating func append(_ string: String, kind: Kind? = nil) {
      let length = string.utf16.count
      if let kind { tokens.append(Token(kind: kind, range: NSRange(location: offset, length: length))) }
      output += string
      offset += length
    }

    mutating func newline() {
      if style == .pretty { append("\n" + String(repeating: "  ", count: (states.count - 1) / 2)) }
    }

    mutating func punctuation() throws {
      append(String(UnicodeScalar(bytes[index])), kind: .punctuation)
      try advance()
    }

    mutating func string(kind: Kind) throws {
      let start = index
      try advance()
      while index < bytes.count {
        let byte = bytes[index]
        if byte == 34 {
          try advance()
          append(String(decoding: bytes[start..<index], as: UTF8.self), kind: kind)
          return
        }
        if byte < 32 { throw fail("Control character in string") }
        if byte == 92 {
          try advance()
          guard index < bytes.count else { throw fail("Unterminated escape") }
          if bytes[index] == 117 {
            for _ in 0..<4 {
              try advance()
              guard index < bytes.count,
                (48...57).contains(bytes[index]) || (65...70).contains(bytes[index]) || (97...102).contains(bytes[index])
              else { throw fail("Expected four hexadecimal digits") }
            }
          } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(bytes[index]) {
            throw fail("Invalid string escape")
          }
        }
        try advance()
      }
      throw fail("Unterminated string")
    }

    mutating func number() throws {
      let start = index
      if bytes[index] == 45 { try advance() }
      guard index < bytes.count else { throw fail("Expected digit") }
      if bytes[index] == 48 {
        try advance()
      } else {
        guard (49...57).contains(bytes[index]) else { throw fail("Expected digit") }
        try digits()
      }
      if index < bytes.count, bytes[index] == 46 {
        try advance()
        try requiredDigits()
      }
      if index < bytes.count, bytes[index] == 101 || bytes[index] == 69 {
        try advance()
        if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { try advance() }
        try requiredDigits()
      }
      append(String(decoding: bytes[start..<index], as: UTF8.self), kind: .number)
    }

    mutating func digits() throws {
      while index < bytes.count, (48...57).contains(bytes[index]) { try advance() }
    }

    mutating func requiredDigits() throws {
      guard index < bytes.count, (48...57).contains(bytes[index]) else { throw fail("Expected digit") }
      try digits()
    }

    mutating func scan() throws -> Document {
      try Task.checkCancellation()
      while true {
        while index < bytes.count, isWhitespace(bytes[index]) { try advance() }
        let state = states.last!
        if state == .done {
          guard index == bytes.count else { throw fail("Unexpected trailing content") }
          return Document(text: output, tokens: tokens)
        }
        guard index < bytes.count else { throw fail("Unexpected end of JSON") }
        let byte = bytes[index]
        switch state {
        case .objectFirst, .arrayFirst:
          if byte == (state == .objectFirst ? 125 : 93) {
            states.removeLast()
            states.removeLast()
            try punctuation()
          } else {
            states[states.count - 1] = state == .objectFirst ? .key : .value
            newline()
          }
        case .key:
          guard byte == 34 else { throw fail("Expected object key") }
          try string(kind: .key)
          states[states.count - 1] = .colon
        case .colon:
          guard byte == 58 else { throw fail("Expected colon") }
          try punctuation()
          if style == .pretty { append(" ") }
          states[states.count - 1] = .value
        case .objectNext, .arrayNext:
          if byte == (state == .objectNext ? 125 : 93) {
            states.removeLast()
            states.removeLast()
            newline()
            try punctuation()
          } else {
            guard byte == 44 else { throw fail("Expected comma or closing bracket") }
            try punctuation()
            states[states.count - 1] = state == .objectNext ? .key : .value
            newline()
          }
        case .value:
          if states.count == 1 { states[0] = .done } else {
            states[states.count - 1] = states[states.count - 2] == .objectNext ? .objectNext : .arrayNext
          }
          switch byte {
          case 123, 91:
            // The parent continuation identifies the container while reading its children.
            states.append(byte == 123 ? .objectNext : .arrayNext)
            states.append(byte == 123 ? .objectFirst : .arrayFirst)
            try punctuation()
          case 34: try string(kind: .string)
          case 45, 48...57: try number()
          case 116, 102, 110:
            let literal = byte == 116 ? "true" : byte == 102 ? "false" : "null"
            for expected in literal.utf8 {
              guard index < bytes.count, bytes[index] == expected else { throw fail("Invalid literal") }
              try advance()
            }
            append(literal, kind: .literal)
          default: throw fail("Expected JSON value")
          }
        case .done: break
        }
      }
    }
  }
}
