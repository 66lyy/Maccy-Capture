import Foundation
import XCTest
@testable import Maccy

final class JSONFormatterTests: XCTestCase {
  func document(_ text: String, _ style: JSONFormatter.Style = .pretty) throws -> JSONFormatter.Document {
    guard case .success(let document) = JSONFormatter.format(text, style: style) else {
      XCTFail("Expected valid JSON: \(text)")
      throw NSError(domain: "JSONFormatterTests", code: 1)
    }
    return document
  }

  func testCandidates() {
    for text in ["{}", " \n\t[1]\r ", "{invalid}"] { XCTAssertTrue(JSONFormatter.isCandidate(text)) }
    for text in ["", "true", " {]", "text {}", "{} trailing"] { XCTAssertFalse(JSONFormatter.isCandidate(text)) }
    XCTAssertTrue(JSONFormatter.isCandidate("[" + String(repeating: " ", count: 1_048_573) + "]"))
    XCTAssertFalse(JSONFormatter.isCandidate("[" + String(repeating: " ", count: 1_048_574) + "]"))
    XCTAssertFalse(JSONFormatter.isCandidate("[\"" + String(repeating: "中", count: 350_000) + "\"]"))
  }

  func testFormattingAndTokenPreservation() throws {
    let source = #" { "z" : 1.0, "中文": "中\u6587\n\"", "a": [true,false,null, -2.30e+04] } "#
    let compact = #"{"z":1.0,"中文":"中\u6587\n\"","a":[true,false,null,-2.30e+04]}"#
    let pretty = "{\n  \"z\": 1.0,\n  \"中文\": \"中\\u6587\\n\\\"\",\n  \"a\": [\n    true,\n    false,\n    null,\n    -2.30e+04\n  ]\n}"
    XCTAssertEqual(try document(source, .compact).text, compact)
    XCTAssertEqual(try document(source).text, pretty)
  }

  func testEmptyAndNestedContainers() throws {
    XCTAssertEqual(try document(" { } ").text, "{}")
    XCTAssertEqual(try document("[ ]").text, "[]")
    XCTAssertEqual(try document("[[],{},[1,[2]]]").text,
                   "[\n  [],\n  {},\n  [\n    1,\n    [\n      2\n    ]\n  ]\n]")
    XCTAssertEqual(try document("{\"a\":{\"b\":[]}}").text,
                   "{\n  \"a\": {\n    \"b\": []\n  }\n}")
  }

  func testErrorLocations() {
    let cases: [(String, Int, Int)] = [
      ("[1,]", 1, 4), (#"{"a": "\q"}"#, 1, 9),
      ("[\"abc", 1, 6), ("{\n  \"中👩‍💻\" 1}", 2, 8),
      ("{} x", 1, 4), ("[01]", 1, 3), ("[1e+]", 1, 5),
      (#"["\u12x4"]"#, 1, 7), ("[\"a\nb\"]", 1, 4),
      ("{\r\n\"a\":1,\r\n}", 3, 1), ("", 1, 1)
    ]
    for (text, line, column) in cases {
      guard case .failure(let error) = JSONFormatter.format(text) else {
        XCTFail("Expected invalid JSON: \(text)"); continue
      }
      XCTAssertFalse(error.message.isEmpty)
      XCTAssertEqual(error.line, line, text)
      XCTAssertEqual(error.column, column, text)
    }
  }

  func testLargeDocumentEquality() throws {
    let source = "[\n" + Array(repeating: #" {"b":1.0,"a":["中文", "space and \"escape\"",null]} "#,
                                   count: 4000).joined(separator: ",\n") + "\n]"
    for style in [JSONFormatter.Style.pretty, .compact] {
      let formatted = try document(source, style).text
      XCTAssertEqual(JSONFormatter.whitespaceOutsideStringsRemoved(formatted),
                     JSONFormatter.whitespaceOutsideStringsRemoved(source))
    }
  }

  func testTokenSpansAndCache() throws {
    let source = #"{"中文":"😀","n":1.0,"b":true,"x":null}"#
    let result = try document(source, .compact)
    let text = result.text as NSString
    let pieces = result.tokens.map { text.substring(with: $0.range) }
    XCTAssertEqual(pieces, ["{", "\"中文\"", ":", "\"😀\"", ",", "\"n\"", ":", "1.0", ",",
                            "\"b\"", ":", "true", ",", "\"x\"", ":", "null", "}"])
    XCTAssertEqual(result.tokens[1].kind, .key)
    XCTAssertEqual(result.tokens[3].kind, .string)
    XCTAssertEqual(result.tokens[7].kind, .number)
    XCTAssertEqual(result.tokens[11].kind, .literal)
    XCTAssertEqual(result.tokens[0].kind, .punctuation)
    XCTAssertEqual(JSONFormatter.format(source, style: .compact), .success(result))
    XCTAssertEqual(JSONFormatter.format(source), JSONFormatter.format(source))
    XCTAssertEqual(JSONFormatter.format("[1,]"), JSONFormatter.format("[1,]"))
  }

  func testDeepNestingAndStrictGrammar() throws {
    let nested = String(repeating: "[", count: 10_000) + "0" + String(repeating: "]", count: 10_000)
    XCTAssertEqual(try document(nested, .compact).text, nested)
    for invalid in ["[+1]", "[.1]", "[1.]", "[NaN]", "[TRUE]", "[falsex]", "{a:1}", "[1 2]", "[1,]", "{\"a\":1,}", "[\u{00a0}]"] {
      guard case .failure = JSONFormatter.format(invalid) else { XCTFail(invalid); continue }
    }
  }
}
