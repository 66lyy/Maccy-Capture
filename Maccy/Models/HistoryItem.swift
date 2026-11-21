import AppKit
import CryptoKit
import Defaults
import Sauce
import SwiftData

@Model
class HistoryItem {
  @MainActor
  static var supportedPins: Set<String> {
    // "a" reserved for select all
    // "q" reserved for quit
    // "v" reserved for paste
    // "w" reserved for close window
    // "z" reserved for undo/redo
    // "," reserved for preferences
    // "`" reserved for cycling through windows
    var keys = Set([
      "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l",
      "m", "n", "o", "p", "r", "s", "t", "u", "x", "y",
      "[", "]", ";", "'", ".", "/", "-", "=", "\\"
    ])

    if let deleteKey = KeyChord.deleteKey,
       let character = Sauce.shared.character(for: Int(deleteKey.QWERTYKeyCode), modifiers: .cocoa([])) {
      keys.remove(character)
    }

    if let pinKey = KeyChord.pinKey,
       let character = Sauce.shared.character(for: Int(pinKey.QWERTYKeyCode), modifiers: .cocoa([])) {
      keys.remove(character)
    }
    if let previewKey = KeyChord.previewKey,
       let character = Sauce.shared.character(for: Int(previewKey.QWERTYKeyCode), modifiers: .cocoa([])) {
      keys.remove(character)
    }

    return keys
  }

  // Letters first, then symbols.
  static func sortedPins(_ pins: some Sequence<String>) -> [String] {
    pins.sorted { lhs, rhs in
      let lhsIsLetter = lhs.first?.isLetter ?? false
      let rhsIsLetter = rhs.first?.isLetter ?? false
      return lhsIsLetter == rhsIsLetter ? lhs < rhs : lhsIsLetter
    }
  }

  @MainActor
  static var availablePins: [String] {
    History.shared.availablePins
  }

  @MainActor
  static func availablePins(in items: [HistoryItem]) -> [String] {
    let assignedPins = Set(items.compactMap(\.pin))
    return Array(supportedPins.subtracting(assignedPins))
  }

  @MainActor
  static var randomAvailablePin: String { availablePins.randomElement() ?? "" }

  private static let transientTypes: [String] = [
    NSPasteboard.PasteboardType.modified.rawValue,
    NSPasteboard.PasteboardType.fromMaccy.rawValue,
    NSPasteboard.PasteboardType.linkPresentationMetadata.rawValue,
    NSPasteboard.PasteboardType.customWebKitPasteboardData.rawValue,
    NSPasteboard.PasteboardType.source.rawValue,
    NSPasteboard.PasteboardType.customChromiumWebData.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceUrl.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceToken.rawValue,
    NSPasteboard.PasteboardType.notesRichText.rawValue
  ]
  private static let imageTypes: [NSPasteboard.PasteboardType] = StorageType.images.types

  var application: String?
  var firstCopiedAt: Date = Date.now
  var lastCopiedAt: Date = Date.now
  var numberOfCopies: Int = 1
  var pin: String?
  var title = ""
  var recognizedText: String?

  @Relationship(deleteRule: .cascade, inverse: \HistoryItemContent.item)
  var contents: [HistoryItemContent] = []

  @Transient private var cachedDecodedImage: NSImage?

  init(contents: [HistoryItemContent] = []) {
    self.firstCopiedAt = firstCopiedAt
    self.lastCopiedAt = lastCopiedAt
    self.contents = contents
  }

  func supersedes(_ item: HistoryItem) -> Bool {
    return item.contents
      .filter { content in
        !Self.transientTypes.contains(content.type)
      }
      .allSatisfy { content in
        contents.contains(where: { $0.type == content.type && $0.value == content.value })
      }
  }

  var comparableContentFingerprint: Set<Data> {
    Set(contents.filter { !Self.transientTypes.contains($0.type) }.map(\.fingerprint))
  }

  @MainActor
  func generateTitle() -> String {
    guard textRecognitionInput == nil else {
      return recognizedText?.removingScalarsUnsafeForTitleLayout() ?? ""
    }

    // 1k characters is trade-off for performance
    var title = previewableText
      .shortened(to: 1_000)
      .removingScalarsUnsafeForTitleLayout()

    if Defaults[.showSpecialSymbols] {
      if let range = title.range(of: "^ +", options: .regularExpression) {
        title = title.replacingOccurrences(of: " ", with: "·", range: range)
      }
      if let range = title.range(of: " +$", options: .regularExpression) {
        title = title.replacingOccurrences(of: " ", with: "·", range: range)
      }
      title = title
        .replacingOccurrences(of: "\n", with: "⏎")
        .replacingOccurrences(of: "\t", with: "⇥")
    } else {
      title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return title
  }

  var previewableText: String {
    if !fileURLs.isEmpty {
      fileURLs
        .compactMap { $0.absoluteString.removingPercentEncoding }
        .joined(separator: "\n")
    } else if let text = text, !text.isEmpty {
      text
    } else if let rtf = rtf, !rtf.string.isEmpty {
      rtf.string
    } else if let html = html, !html.string.isEmpty {
      html.string
    } else {
      title
    }
  }

  var fileURLs: [URL] {
    guard !universalClipboardText else {
      return []
    }

    return allContentData([.fileURL])
      .compactMap { URL(dataRepresentation: $0, relativeTo: nil, isAbsolute: true) }
  }

  var htmlData: Data? { contentData([.html]) }
  var html: NSAttributedString? {
    guard let data = htmlData else {
      return nil
    }

    return NSAttributedString(html: data, documentAttributes: nil)
  }

  var imageData: Data? {
    var data: Data?
    data = contentData(Self.imageTypes)
    if data == nil, universalClipboardImage, let url = fileURLs.first {
      data = try? Data(contentsOf: url)
    }

    return data
  }

  var image: NSImage? {
    if let img = cachedDecodedImage {
      return img
    }
    guard let data = imageData else {
      return nil
    }

    cachedDecodedImage = NSImage(data: data)
    return cachedDecodedImage
  }

  var rtfData: Data? { contentData([.rtf]) }
  var rtf: NSAttributedString? {
    guard let data = rtfData else {
      return nil
    }

    return NSAttributedString(rtf: data, documentAttributes: nil)
  }

  func clearDecodedImageCache() {
    cachedDecodedImage?.recache()
    cachedDecodedImage = nil
  }

  var text: String? {
    guard let data = contentData([.string]) else {
      return nil
    }

    return String(data: data, encoding: .utf8)
  }

  var modified: Int? {
    guard let data = contentData([.modified]),
          let modified = String(data: data, encoding: .utf8) else {
      return nil
    }

    return Int(modified)
  }

  var fromMaccy: Bool { contentData([.fromMaccy]) != nil }
  var universalClipboard: Bool { contentData([.universalClipboard]) != nil }

  private var universalClipboardImage: Bool { universalClipboard && fileURLs.first?.pathExtension == "jpeg" }
  private var universalClipboardText: Bool {
    universalClipboard && contentData([.html, .tiff, .png, .jpeg, .rtf, .string, .heic]) != nil
  }

  private func contentData(_ types: [NSPasteboard.PasteboardType]) -> Data? {
    let content = contents.first(where: { content in
      return types.contains(NSPasteboard.PasteboardType(content.type))
    })

    return content?.value
  }

  private func allContentData(_ types: [NSPasteboard.PasteboardType]) -> [Data] {
    return contents
      .filter { types.contains(NSPasteboard.PasteboardType($0.type)) }
      .compactMap { $0.value }
  }

  @MainActor
  var textRecognitionInput: HistoryOCRCoordinator.Input? {
    let data = contentData(Self.imageTypes)
    let fileURL = universalClipboardImage ? fileURLs.first : nil
    guard data != nil || fileURL != nil else { return nil }
    return HistoryOCRCoordinator.Input(data: data, fileURL: fileURL)
  }

}

@MainActor
final class HistoryOCRCoordinator {
  typealias Recognizer = @Sendable (Data?, URL?) throws -> String?

  struct Input: Sendable {
    let data: Data?
    let fileURL: URL?

    var key: String {
      if let data {
        return "data:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      }
      return "url:" + (fileURL?.absoluteString ?? "")
    }
  }

  private struct Job {
    let id = UUID()
    let key: String
    let input: Input
  }

  @MainActor
  private final class Target {
    weak var item: HistoryItem?
    weak var history: History?
    let generation: UUID

    init(item: HistoryItem, history: History, generation: UUID) {
      self.item = item
      self.history = history
      self.generation = generation
    }
  }

  private let maximumPending: Int
  private let recognize: Recognizer
  private var active: Job?
  private var pending: [Job] = []
  private var targets: [ObjectIdentifier: Target] = [:]

  var pendingCount: Int { pending.count }
  var isRunning: Bool { active != nil }

  init(maximumPending: Int = 3, recognize: @escaping Recognizer = TextRecognition.performClipboardRecognition) {
    precondition(maximumPending > 0)
    self.maximumPending = maximumPending
    self.recognize = recognize
  }

  func enqueue(_ item: HistoryItem, in history: History) {
    guard item.recognizedText == nil, let input = item.textRecognitionInput else {
      cancel(item)
      return
    }
    let key = input.key
    let job: Job
    if let existing = ([active].compactMap { $0 } + pending).first(where: { $0.key == key }) {
      job = existing
    } else {
      job = Job(key: key, input: input)
      if pending.count == maximumPending {
        let dropped = pending.removeFirst()
        targets = targets.filter { $0.value.generation != dropped.id }
      }
      pending.append(job)
    }
    targets[ObjectIdentifier(item)] = Target(item: item, history: history, generation: job.id)
    prunePending()
    startNext()
  }

  func replace(_ item: HistoryItem, with replacement: HistoryItem, in history: History) {
    if targets[ObjectIdentifier(item)] != nil {
      enqueue(replacement, in: history)
    }
    cancel(item)
  }

  func cancel(_ item: HistoryItem) {
    targets.removeValue(forKey: ObjectIdentifier(item))
    prunePending()
  }

  func cancelAll() {
    targets.removeAll()
    pending.removeAll()
  }

  private func prunePending() {
    targets = targets.filter { $0.value.item != nil && $0.value.history != nil }
    let generations = Set(targets.values.map(\.generation))
    pending.removeAll { !generations.contains($0.id) }
  }

  private func startNext() {
    guard active == nil, !pending.isEmpty else { return }
    let job = pending.removeFirst()
    active = job
    let input = job.input
    let generation = job.id
    let recognize = recognize
    TextRecognition.clipboardQueue.async { [weak self] in
      let result = Result { try recognize(input.data, input.fileURL) }
      Task { @MainActor [weak self] in
        self?.finish(generation, result: result)
      }
    }
  }

  private func finish(_ generation: UUID, result: Result<String?, any Error>) {
    guard active?.id == generation else { return }
    active = nil
    let completed = targets.filter { $0.value.generation == generation }
    for (identity, target) in completed {
      guard targets[identity]?.generation == generation else { continue }
      targets.removeValue(forKey: identity)
      if case .success(let text?) = result, !text.isEmpty,
         let item = target.item, let history = target.history {
        history.applyRecognizedText(text, to: item)
      }
    }
    prunePending()
    startNext()
  }
}
