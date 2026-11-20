import AppKit
import Defaults
import KeyboardShortcuts
import SwiftUI

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
        Button { Clipboard.shared.copyInMaccy(document.text) } label: {
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

  @ViewBuilder
  func previewImage(content: () -> some View) -> some View {
    content()
      .aspectRatio(contentMode: .fit)
      .clipShape(.rect(cornerRadius: 5))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if item.hasImage {
        AsyncView<NSImage?, _, _>(id: item.id) {
          return await item.asyncGetPreviewImage()
        } content: { image in
          if let image = image {
            previewImage {
              Image(nsImage: image)
                .resizable()
            }
          } else {
            previewImage {
              ZStack {
                Color.gray.opacity(0.3)
                  .frame(
                    idealWidth: HistoryItemDecorator.previewImageSize.width,
                    idealHeight: HistoryItemDecorator.previewImageSize.height
                  )
                Image(systemName: "photo.badge.exclamationmark")
                  .symbolRenderingMode(.multicolor)
                  .frame(alignment: .center)
              }
            }
          }
        } placeholder: {
          previewImage {
            ZStack {
              Color.gray.opacity(0.3)
                .frame(
                  idealWidth: HistoryItemDecorator.previewImageSize.width,
                  idealHeight: HistoryItemDecorator.previewImageSize.height
                )
              ProgressView()
                .frame(alignment: .center)
            }
          }
        }
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

  func makeNSView(context: Context) -> NSScrollView {
    LargeTextView.makeScrollView(text: "")
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard context.coordinator.lastText != document.text || context.coordinator.lastStyle != style else { return }
    guard let textView = scrollView.documentView as? NSTextView else { return }
    let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    let attributed = NSMutableAttributedString(string: document.text, attributes: [
      .font: font, .foregroundColor: NSColor.labelColor
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
      attributed.addAttribute(.foregroundColor, value: color, range: token.range)
    }
    textView.isSelectable = true
    textView.textStorage?.setAttributedString(attributed)
    context.coordinator.lastText = document.text
    context.coordinator.lastStyle = style
  }
}
