import AppKit
import Defaults
import ImageIO
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

struct PreviewItemView: View {
  private static let largeTextThreshold = 1_000

  var item: HistoryItemDecorator

  @State private var jsonStyle: JSONFormatter.Style = .pretty
  @State private var jsonResult: JSONFormatter.Result?
  @State private var validateJSON = false
  @Default(.formatJSON) private var formatJSON

  private var fullText: String { item.item.text ?? item.previewText.string }
  private var jsonTaskID: String { "\(item.id)-\(jsonStyle.rawValue)-\(validateJSON)-\(formatJSON)" }

  @ViewBuilder
  private var plainText: some View {
    if item.previewText.byteCount >= Self.largeTextThreshold {
      LargeTextView(text: item.previewText.string)
        .id("textpreview-\(item.id)")
    } else {
      ScrollView {
        Text(item.previewText.string)
          .font(.body)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity)
    }
  }

  @ViewBuilder
  private var textPreview: some View {
    if !formatJSON {
      plainText
    } else if case .success(let document) = jsonResult {
      HStack {
        Picker(selection: $jsonStyle) {
          Text("JSONPretty", tableName: "PreviewItemView").tag(JSONFormatter.Style.pretty)
          Text("JSONCompact", tableName: "PreviewItemView").tag(JSONFormatter.Style.compact)
        } label: { Text("JSONStyle", tableName: "PreviewItemView") }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(maxWidth: 180)
        Button { Clipboard.shared.copyInMaccy(document.text, rtf: JSONTextView.rtf(for: document)) } label: {
          Text("CopyFormattedJSON", tableName: "PreviewItemView")
        }
        .glassButtonStyle()
        Text("ValidJSON", tableName: "PreviewItemView").foregroundStyle(.secondary)
      }
      .padding(.bottom, 6)
      JSONTextView(document: document, style: jsonStyle)
    } else {
      plainText
      if case .failure(let error) = jsonResult {
        Text(String(format: NSLocalizedString("JSONError", tableName: "PreviewItemView", comment: ""),
                    error.message, error.line, error.column))
          .font(.caption).foregroundStyle(.secondary)
      } else if fullText.utf8.count >= JSONFormatter.automaticLimit,
        JSONFormatter.looksLikeContainer(fullText), !validateJSON {
        Button { validateJSON = true } label: {
          Text("ValidateJSON", tableName: "PreviewItemView")
        }
        .glassButtonStyle()
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if item.hasImage {
        HistoryImagePreview(item: item)
          .id(item.id)
      } else {
        textPreview
          .task(id: jsonTaskID) {
            jsonResult = nil
            guard formatJSON else { return }
            let text = fullText
            guard JSONFormatter.isCandidate(text) || validateJSON else { return }
            let style = jsonStyle
            let worker = Task.detached(priority: .userInitiated) {
              JSONFormatter.format(text, style: style)
            }
            let result = await withTaskCancellationHandler {
              await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            jsonResult = result
          }
          .onChange(of: item.id) {
            jsonResult = nil
            validateJSON = false
          }
          .onChange(of: formatJSON) {
            jsonResult = nil
            validateJSON = false
          }
      }

      Spacer(minLength: 0)

      Divider()
        .padding(.bottom)

      if let application = item.application {
        HStack(spacing: 3) {
          Text("Application", tableName: "PreviewItemView")
          AppImageView(
            appImage: item.applicationImage,
            size: NSSize(width: 11, height: 11)
          )
          Text(application)
        }
      }

      if item.hasImage, let image = item.item.image {
        HStack(spacing: 3) {
          Text("Dimensions", tableName: "PreviewItemView")
          Text("\(Int(image.pixelSize.width))×\(Int(image.pixelSize.height))")
        }
      }

      if item.hasImage, let size = item.imageSize {
        HStack(spacing: 3) {
          Text("Size", tableName: "PreviewItemView")
          Text(size)
        }
      }

      HStack(spacing: 3) {
        Text("FirstCopyTime", tableName: "PreviewItemView")
        Text(item.item.firstCopiedAt, style: .date)
        Text(item.item.firstCopiedAt, style: .time)
      }

      HStack(spacing: 3) {
        Text("LastCopyTime", tableName: "PreviewItemView")
        Text(item.item.lastCopiedAt, style: .date)
        Text(item.item.lastCopiedAt, style: .time)
      }

      HStack(spacing: 3) {
        Text("NumberOfCopies", tableName: "PreviewItemView")
        Text(String(item.item.numberOfCopies))
      }
    }
    .controlSize(.small)
  }
}

struct HistoryImagePreview: View {
  let item: HistoryItemDecorator

  @Environment(AppState.self) private var appState
  @State private var ocrTask: Task<Void, Never>?
  @State private var status: String?
  @State private var isSaving = false

  var body: some View {
    AsyncView<NSImage?, _, _>(id: item.id) {
      await item.asyncGetPreviewImage()
    } content: { image in
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .overlay(alignment: .bottomTrailing) {
            actions.padding(8)
          }
      } else {
        Image(systemName: "photo.badge.exclamationmark")
          .symbolRenderingMode(.multicolor)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } placeholder: {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    .clipShape(.rect(cornerRadius: 10))
    .padding(.bottom, 6)
    .onDisappear { ocrTask?.cancel() }
  }

  private var actions: some View {
    VStack(alignment: .trailing, spacing: 4) {
      if let status {
        Text(status)
          .font(.caption)
          .padding(.vertical, 4)
          .padding(.horizontal, 8)
          .background(.regularMaterial, in: .capsule)
      }

      HStack(spacing: 2) {
        action("HistoryImageCopyOCR", symbol: "text.viewfinder", perform: copyText)
          .disabled(ocrTask != nil)
        action("HistoryImageRepin", symbol: "pin", perform: pin)
        action("HistoryImageSaveFile", symbol: "square.and.arrow.down", perform: save)
          .disabled(isSaving)
      }
      .padding(3)
      .background(.regularMaterial, in: .capsule)
      .shadow(color: .black.opacity(0.20), radius: 4, y: 2)
    }
  }

  private func localized(_ key: String) -> String {
    NSLocalizedString(key, tableName: "GeneralSettings", comment: "")
  }

  private func action(_ key: String, symbol: String, perform: @escaping () -> Void) -> some View {
    let title = localized(key)
    return Button(action: perform) {
      Image(systemName: symbol)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .help(title)
    .accessibilityLabel(title)
  }

  private func copyText() {
    guard let input = item.item.textRecognitionInput else { return }
    status = nil
    ocrTask = Task {
      defer { ocrTask = nil }
      var text = item.item.recognizedText
      if text == nil {
        text = await TextRecognition.recognizeClipboardImage(imageData: input.data, fileURL: input.fileURL)
      }
      guard !Task.isCancelled else { return }
      guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        status = localized("AnnotationNoText")
        return
      }
      Clipboard.shared.copyInMaccy(text)
      status = localized("AnnotationTextCopied")
    }
  }

  private func pin() {
    guard let image = item.item.image, image.isValid else { return }
    ScreenshotCapture.shared.pinImage(image)
  }

  private func save() {
    guard let window = appState.preview.nswindow, window.attachedSheet == nil,
          let input = item.item.textRecognitionInput else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "Screenshot.png"
    panel.level = max(panel.level, window.level)
    isSaving = true
    status = nil
    appState.isSavingHistoryImage = true
    panel.beginSheetModal(for: window) { response in
      appState.isSavingHistoryImage = false
      guard response == .OK, let url = panel.url else {
        isSaving = false
        return
      }
      Task {
        let saved = await Task.detached(priority: .userInitiated) {
          do {
            guard let source = input.data ?? input.fileURL.flatMap({ try? Data(contentsOf: $0) }),
                  let png = Self.pngData(from: source) else { return false }
            try png.write(to: url, options: .atomic)
            return true
          } catch {
            return false
          }
        }.value
        isSaving = false
        if !saved { status = localized("AnnotationOutputFailedShort") }
      }
    }
  }

  nonisolated static func pngData(from data: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    if CGImageSourceGetType(source) as String? == UTType.png.identifier { return data }
    return ScreenshotAnnotationDocument.RenderSnapshot.pngData(image)
  }
}

private struct JSONTextView: NSViewRepresentable {
  let document: JSONFormatter.Document
  let style: JSONFormatter.Style

  final class Coordinator {
    var lastText: String?
    var lastStyle: JSONFormatter.Style?
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  static func attributedString(
    for document: JSONFormatter.Document, font: NSFont, color resolve: (NSColor) -> NSColor
  ) -> NSMutableAttributedString {
    let attributed = NSMutableAttributedString(string: document.text, attributes: [
      .font: font, .foregroundColor: resolve(.labelColor)
    ])
    let prefix = document.text.utf8.prefix(200 * 1024)
    let colorLimit = String(decoding: prefix, as: UTF8.self).utf16.count
    for token in document.tokens {
      guard NSMaxRange(token.range) <= colorLimit else { break }
      let color: NSColor
      switch token.kind {
      case .key: color = .systemBlue
      case .string: color = .systemRed
      case .number: color = .systemOrange
      case .literal: color = .systemPurple
      case .punctuation: color = .labelColor
      }
      attributed.addAttribute(.foregroundColor, value: resolve(color), range: token.range)
    }
    return attributed
  }

  // RTF keeps the indentation monospaced in rich-text apps; it needs a named font and static colors.
  static func rtf(for document: JSONFormatter.Document) -> Data? {
    let font = NSFont(name: "Menlo", size: NSFont.systemFontSize)
      ?? NSFont.userFixedPitchFont(ofSize: NSFont.systemFontSize)
      ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    let appearance = NSAppearance(named: .aqua)
    let attributed = attributedString(for: document, font: font) { color in
      var resolved = color
      appearance?.performAsCurrentDrawingAppearance {
        resolved = color.usingColorSpace(.sRGB) ?? color
      }
      return resolved
    }
    return attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:])
  }

  func makeNSView(context: Context) -> NSScrollView {
    LargeTextView.makeScrollView(text: "")
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard context.coordinator.lastText != document.text || context.coordinator.lastStyle != style else { return }
    guard let textView = scrollView.documentView as? NSTextView else { return }
    let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    let attributed = Self.attributedString(for: document, font: font) { $0 }
    textView.isSelectable = true
    textView.textStorage?.setAttributedString(attributed)
    context.coordinator.lastText = document.text
    context.coordinator.lastStyle = style
  }
}
