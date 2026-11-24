import AppKit
import Testing
import Defaults
import Logging
import SwiftData
import os
@testable import Maccy

extension SharedStateTests {
  @MainActor
  final class HistoryTests { // swiftlint:disable:this type_body_length
    let savedSize = Defaults[.size]
    let savedSortBy = Defaults[.sortBy]
    let savedPinOrder = Defaults[.pinOrder]
    let savedPinTo = Defaults[.pinTo]
    let history = History.shared

    init() {
      History.shared.clearAll()
      Defaults[.size] = 10
      Defaults[.sortBy] = .firstCopiedAt
      Defaults[.pinOrder] = PinOrder()
      Defaults[.pinTo] = .bottom
    }

    deinit {
      Defaults[.size] = savedSize
      Defaults[.sortBy] = savedSortBy
      Defaults[.pinOrder] = savedPinOrder
      Defaults[.pinTo] = savedPinTo
    }

    @Test("Default is empty")
    func defaultIsEmpty() {
      #expect(history.items.toArray() == [])
    }

    @Test("Adding")
    func adding() {
      let first = history.add(historyItem("foo"))
      let second = history.add(historyItem("bar"))
      #expect(history.items.toArray() == [second, first])
    }

    @Test("Loading trims unpinned items before decoration and retains all pins",
          arguments: Sorter.By.allCases, PinsPosition.allCases)
    func loadLimitedHistory(by: Sorter.By, pinTo: PinsPosition) async throws {
      Defaults[.sortBy] = by
      Defaults[.pinTo] = pinTo
      var stored: [HistoryItem] = []
      for index in 0..<5 {
        let item = historyItem("stored \(index)")
        item.firstCopiedAt = Date(timeIntervalSince1970: TimeInterval(index))
        item.lastCopiedAt = Date(timeIntervalSince1970: TimeInterval(5 - index))
        item.numberOfCopies = index + 1
        stored.append(item)
      }
      let pinned = historyItem("pinned")
      pinned.pin = "b"
      try Storage.shared.context.save()
      Defaults[.size] = 2
      let expected = Array(Sorter().sort(stored, by: by).prefix(2)).map(\.title)
      try await history.load()
      #expect(history.unpinnedItems.map(\.title) == expected)
      #expect(history.pinnedItems.map(\.title) == ["pinned"])
      #expect(history.items.allSatisfy { $0.cachedPreviewText == nil })
      try assertStorageCounts(items: 3, contents: 3)
      Defaults[.size] = 0
      try await history.load()
      #expect(history.unpinnedItems.isEmpty)
      #expect(history.pinnedItems.map(\.title) == ["pinned"])
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Binary insertion matches the full stable sort", arguments: Sorter.By.allCases)
    func binaryInsertionMatchesFullSort(by: Sorter.By) {
      Defaults[.sortBy] = by
      let firstCopiedAt: [TimeInterval] = [20, 10, 30, 20, 0]
      let lastCopiedAt: [TimeInterval] = [40, 20, 30, 40, 10]
      let copies = [2, 1, 4, 2, 3]
      for index in firstCopiedAt.indices {
        let item = historyItem("unique \(index)")
        item.firstCopiedAt = Date(timeIntervalSince1970: firstCopiedAt[index])
        item.lastCopiedAt = Date(timeIntervalSince1970: lastCopiedAt[index])
        item.numberOfCopies = copies[index]
        let expected = Sorter().sort(history.unpinnedItems.map(\.item) + [item], by: by)

        history.add(item)

        #expect(history.unpinnedItems.map(\.item) == expected)
      }
    }

    @Test("Reloading after a sort change preserves the latest tag or text filter",
          arguments: ["#image", "#code needle", "plain"])
    func reloadPreservesActiveFilter(query: String) async throws {
      let searchMode = Defaults[.searchMode]
      Defaults[.searchMode] = .exact
      defer {
        Defaults[.searchMode] = searchMode
        history.searchQuery = ""
      }

      let image = ocrItem(0)
      image.title = "image"
      image.pin = "b"
      history.add(image)
      history.add(historyItem("let needle = 1"))
      history.add(historyItem("let other = 2"))
      history.add(historyItem("plain text"))

      let expected = switch query {
      case "#image": ["image"]
      case "#code needle": ["let needle = 1"]
      default: ["plain text"]
      }
      history.searchQuery = "#image"
      history.searchQuery = "#code"
      history.searchQuery = query
      let deadline = ContinuousClock.now + .seconds(2)
      while history.items.map(\.title) != expected && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      try #require(history.items.map(\.title) == expected)

      Defaults[.sortBy] = .numberOfCopies
      try await history.load()

      #expect(history.items.map(\.title) == expected)
    }

    @Test("A cancelled history load neither replaces the list nor trims storage")
    func cancelledLoadLeavesHistoryUntouched() async throws {
      let row = history.add(historyItem("stored"))
      Defaults[.size] = 0
      let load = Task { @MainActor in try await history.load() }
      load.cancel()

      await #expect(throws: CancellationError.self) { try await load.value }
      #expect(history.items.first === row)
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("An older history load cannot overwrite a newer load or trim storage")
    func supersededLoadLeavesLatestHistoryUntouched() async throws {
      history.add(historyItem("stored"))
      let (waiting, continuation) = AsyncStream.makeStream(of: CheckedContinuation<Void, Never>.self)
      let older = Task { @MainActor in
        try await history.load {
          await withCheckedContinuation { _ = continuation.yield($0) }
        }
      }
      var iterator = waiting.makeAsyncIterator()
      let resumeOlder = try #require(await iterator.next())
      let newestRow: HistoryItemDecorator
      do {
        defer { resumeOlder.resume() }
        try await history.load()
        newestRow = try #require(history.firstUnpinnedItem)
        Defaults[.size] = 0
      }

      try await older.value

      #expect(history.firstUnpinnedItem === newestRow)
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Duplicate replacement preserves full-sort ordering", arguments: Sorter.By.allCases)
    func duplicateReplacementOrdering(by: Sorter.By) {
      Defaults[.sortBy] = by
      for index in 0..<3 {
        let item = historyItem("ordered \(index)")
        item.firstCopiedAt = Date(timeIntervalSince1970: TimeInterval(index))
        item.lastCopiedAt = Date(timeIntervalSince1970: TimeInterval(index))
        item.numberOfCopies = index + 1
        history.add(item)
      }
      let previous = history.unpinnedItems.map(\.item).filter { $0.text != "ordered 0" }
      let incoming = historyItem("ordered 0")
      incoming.lastCopiedAt = Date(timeIntervalSince1970: 10)
      incoming.numberOfCopies = 5

      let replacement = history.add(incoming)

      #expect(history.unpinnedItems.map(\.item) == Sorter().sort(previous + [replacement.item], by: by))
      #expect(replacement.item.firstCopiedAt == Date(timeIntervalSince1970: 0))
      #expect(replacement.item.numberOfCopies == 6)
    }

    @Test("Comparable fingerprints ignore transient types")
    func comparableFingerprintsIgnoreTransientTypes() {
      let original = historyItem("same content")
      original.contents.append(HistoryItemContent(type: NSPasteboard.PasteboardType.fromMaccy.rawValue, value: Data()))
      history.add(original)
      let incoming = historyItem("same content")
      incoming.contents.append(HistoryItemContent(type: NSPasteboard.PasteboardType.modified.rawValue,
                                                 value: Data("not a change count".utf8)))

      #expect(original.comparableContentFingerprint == incoming.comparableContentFingerprint)
      let replacement = history.add(incoming)

      #expect(history.items.toArray() == [replacement])
      #expect(replacement.item.numberOfCopies == 2)
    }

    @Test("Indexed subset matches preserve pinned-first priority", arguments: Sorter.By.allCases)
    func indexedSubsetMatchesPreferPinned(by: Sorter.By) {
      Defaults[.sortBy] = by
      let exact = history.add(historyItem("shared"))
      let richer = historyItem("shared")
      richer.contents.append(HistoryItemContent(type: NSPasteboard.PasteboardType.html.rawValue,
                                               value: Data("extra representation".utf8)))
      richer.pin = "f"
      history.add(richer)
      let incoming = historyItem("shared")
      #expect(richer.comparableContentFingerprint != incoming.comparableContentFingerprint)

      let replacement = history.add(incoming)

      #expect(history.pinnedItems == [replacement])
      #expect(history.unpinnedItems == [exact])
      #expect(replacement.item.pin == "f")
      #expect(replacement.item.contents.count == 2)
      #expect(replacement.item.numberOfCopies == 2)
    }

    @Test("Empty comparable contents still match the first stored item")
    func emptyComparableContentsMatchFirstStored() {
      history.add(historyItem("unpinned"))
      let pinned = historyItem("pinned")
      pinned.pin = "f"
      history.add(pinned)

      let replacement = history.add(HistoryItem())

      #expect(replacement.item.pin == "f")
      #expect(replacement.item.text == "pinned")
      #expect(history.items.count == 2)
    }

    @Test("Duplicate index refreshes edited contents synchronously", arguments: ["value", "type", "append", "remove"])
    func duplicateIndexRefreshesEditedContents(edit: String) {
      let original = historyItem("old")
      let htmlType = NSPasteboard.PasteboardType.html.rawValue
      if edit == "remove" {
        original.contents.append(HistoryItemContent(type: htmlType, value: Data("extra".utf8)))
      }
      history.add(original)
      let incoming: HistoryItem
      switch edit {
      case "value":
        original.contents[0].value = Data("new".utf8)
        incoming = historyItem("new")
      case "type":
        original.contents[0].type = htmlType
        incoming = HistoryItem(contents: [HistoryItemContent(type: htmlType, value: Data("old".utf8))])
      default:
        if edit == "append" {
          original.contents.append(HistoryItemContent(type: htmlType, value: Data("extra".utf8)))
        } else {
          original.contents.removeAll { $0.type == htmlType }
        }
        incoming = historyItem("old")
        incoming.contents.append(HistoryItemContent(type: htmlType, value: Data("extra".utf8)))
      }

      #expect(original.supersedes(incoming) == (edit != "remove"))
      #expect(incoming.comparableContentFingerprint.isSubset(of: original.comparableContentFingerprint)
              == (edit != "remove"))
      let added = history.add(incoming)

      #expect(history.items.count == (edit == "remove" ? 2 : 1))
      #expect(added.item.numberOfCopies == (edit == "remove" ? 1 : 2))
    }

    @Test("Comparable fingerprints distinguish nil from empty data")
    func comparableFingerprintsDistinguishNilFromEmpty() {
      let type = NSPasteboard.PasteboardType.string.rawValue
      history.add(HistoryItem(contents: [HistoryItemContent(type: type)]))
      let empty = history.add(HistoryItem(contents: [HistoryItemContent(type: type, value: Data())]))
      #expect(history.items.count == 2)
      #expect(empty.item.numberOfCopies == 1)

      let nilDuplicate = history.add(HistoryItem(contents: [HistoryItemContent(type: type)]))

      #expect(history.items.count == 2)
      #expect(nilDuplicate.item.numberOfCopies == 2)
    }

    @Test("Subset fingerprints do not count repeated content twice")
    func repeatedContentDoesNotChangeSubsetMatching() {
      history.add(historyItem("repeated"))
      let incoming = historyItem("repeated")
      incoming.contents.append(HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue,
                                                 value: Data("repeated".utf8)))

      let replacement = history.add(incoming)

      #expect(history.items.toArray() == [replacement])
      #expect(replacement.item.numberOfCopies == 2)
    }

    @Test("Duplicate index follows history lifecycle", arguments: ["delete", "clear", "clearAll", "evict", "load"])
    func duplicateIndexFollowsLifecycle(path: String) async throws {
      let original = history.add(historyItem("indexed"))
      switch path {
      case "delete": history.delete(original)
      case "clear": history.clear()
      case "clearAll": history.clearAll()
      case "evict":
        Defaults[.size] = 1
        history.add(historyItem("evicting"))
      default: try await history.load()
      }

      let added = history.add(historyItem("indexed"))

      #expect(history.items.toArray() == [added])
      #expect(added.item.numberOfCopies == (path == "load" ? 2 : 1))
    }

    @Test("Adding persisted duplicate")
    func addingPersistedDuplicate() throws {
      let first = historyItem("foo")
      first.title = "xyz"
      first.application = "iTerm.app"
      history.add(first)
      first.pin = "f"

      let third = historyItem("foo")
      third.application = "Xcode.app"
      let transferredContents = first.contents
      let merged = history.add(third)

      #expect(history.items.toArray() == [merged])
      #expect(Set(merged.item.contents) == Set(transferredContents))
      #expect(merged.item.lastCopiedAt > merged.item.firstCopiedAt)
      #expect(merged.item.numberOfCopies == 2)
      #expect(merged.item.pin == "f")
      #expect(merged.item.title == "xyz")
      #expect(merged.item.application == "iTerm.app")
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Adding unsaved duplicate")
    @available(macOS 15.0, *)
    func addingUnsavedDuplicate() throws {
      let first = historyItem("foo")
      first.title = "xyz"
      first.application = "iTerm.app"
      history.add(first)
      first.pin = "f"

      let second = historyItem("foo", persisted: false)
      second.application = "Xcode.app"
      let transferredContents = first.contents
      let merged = history.add(second)

      #expect(history.items.toArray() == [merged])
      #expect(Set(merged.item.contents) == Set(transferredContents))
      #expect(merged.item.lastCopiedAt > merged.item.firstCopiedAt)
      #expect(merged.item.numberOfCopies == 2)
      #expect(merged.item.pin == "f")
      #expect(merged.item.title == "xyz")
      #expect(merged.item.application == "iTerm.app")
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Adding item that is superseded by existing")
    func addingItemThatIsSupersededByExisting() throws {
      let firstContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)!
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.rtf.rawValue,
          value: "two".data(using: .utf8)!
        )
      ]
      let firstItem = HistoryItem()
      Storage.shared.context.insert(firstItem)
      firstItem.application = "Maccy.app"
      firstItem.contents = firstContents
      firstItem.title = firstItem.generateTitle()
      history.add(firstItem)

      let secondContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)!
        )
      ]
      let secondItem = HistoryItem()
      Storage.shared.context.insert(secondItem)
      secondItem.application = "Maccy.app"
      secondItem.contents = secondContents
      secondItem.title = secondItem.generateTitle()
      let second = history.add(secondItem)

      #expect(history.items.toArray() == [second])
      #expect(Set(history.items[0].item.contents) == Set(firstContents))
      try assertStorageCounts(items: 1, contents: firstContents.count)
    }

    @Test("Adding item with different modified type")
    func addingItemWithDifferentModifiedType() {
      let firstContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)!
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.modified.rawValue,
          value: "1".data(using: .utf8)!
        )
      ]
      let firstItem = HistoryItem()
      Storage.shared.context.insert(firstItem)
      firstItem.contents = firstContents
      history.add(firstItem)

      let secondContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)!
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.modified.rawValue,
          value: "2".data(using: .utf8)!
        )
      ]
      let secondItem = HistoryItem()
      Storage.shared.context.insert(secondItem)
      secondItem.contents = secondContents
      let second = history.add(secondItem)

      #expect(history.items.toArray() == [second])
      #expect(Set(history.items[0].item.contents) == Set(firstContents))
    }

    @Test("Adding item from Maccy")
    func addingItemFromMaccy() {
      let firstContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)
        )
      ]
      let first = HistoryItem()
      Storage.shared.context.insert(first)
      first.application = "Xcode.app"
      first.contents = firstContents
      history.add(first)

      let secondContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.fromMaccy.rawValue,
          value: "".data(using: .utf8)
        )
      ]
      let second = HistoryItem()
      Storage.shared.context.insert(second)
      second.application = "Maccy.app"
      second.contents = secondContents
      let secondDecorator = history.add(second)

      #expect(history.items.toArray() == [secondDecorator])
      #expect(history.items[0].item.application == "Xcode.app")
      #expect(Set(history.items[0].item.contents) == Set(firstContents))
    }

    @Test("Modified after copying")
    func modifiedAfterCopying() {
      history.add(historyItem("foo"))

      let modifiedItem = historyItem("bar")
      modifiedItem.contents.append(HistoryItemContent(
        type: NSPasteboard.PasteboardType.modified.rawValue,
        value: String(Clipboard.shared.changeCount).data(using: .utf8)
      ))
      let modifiedItemDecorator = history.add(modifiedItem)

      #expect(history.items.toArray() == [modifiedItemDecorator])
      #expect(history.items[0].text == "bar")
    }

    @Test("Repeated duplicates retain only the live model in the session log")
    func repeatedDuplicatesRetainOnlyLiveModel() throws {
      let savedChangeCount = Clipboard.shared.changeCount
      defer { Clipboard.shared.changeCount = savedChangeCount }
      for changeCount in 1...20 {
        Clipboard.shared.changeCount = changeCount
        let current = history.add(historyItem("foo"))
        #expect(history.items.count == 1)
        #expect(history.sessionLog.count == changeCount)
        #expect(history.sessionLog.values.allSatisfy { $0 === current.item })
        try assertStorageCounts(items: 1, contents: 1)
      }
    }

    @Test("Modification aliases resolve to the live replacement", arguments: [1, 2])
    func modificationAliasesResolveToLiveReplacement(originalChangeCount: Int) throws {
      let savedChangeCount = Clipboard.shared.changeCount
      defer { Clipboard.shared.changeCount = savedChangeCount }
      Clipboard.shared.changeCount = 1
      let original = history.add(historyItem("foo"))
      Clipboard.shared.changeCount = 2
      let replacement = history.add(historyItem("foo"))
      #expect(history.sessionLog[originalChangeCount] === replacement.item)
      #expect(history.sessionLog.values.allSatisfy { $0 !== original.item })

      let modified = historyItem("bar")
      modified.contents.append(HistoryItemContent(
        type: NSPasteboard.PasteboardType.modified.rawValue,
        value: String(originalChangeCount).data(using: .utf8)
      ))
      Clipboard.shared.changeCount = 3
      let current = history.add(modified)

      #expect(history.items.toArray() == [current])
      #expect(current.text == "bar")
      #expect(current.item.numberOfCopies == 3)
      #expect(history.sessionLog.values.allSatisfy { $0 === current.item })
      try assertStorageCounts(items: 1, contents: 2)
    }

    @Test("Deletion prunes all replacement aliases", arguments: ["delete", "clear", "clearAll", "limit"])
    func deletionPrunesAllReplacementAliases(path: String) {
      let savedChangeCount = Clipboard.shared.changeCount
      defer { Clipboard.shared.changeCount = savedChangeCount }
      Clipboard.shared.changeCount = 1
      history.add(historyItem("foo"))
      Clipboard.shared.changeCount = 2
      let replacement = history.add(historyItem("foo"))

      switch path {
      case "delete": history.delete(replacement)
      case "clear": history.clear()
      case "clearAll": history.clearAll()
      default:
        Defaults[.size] = 1
        Clipboard.shared.changeCount = 3
        history.add(historyItem("bar"))
      }

      #expect(history.sessionLog[1] == nil)
      #expect(history.sessionLog[2] == nil)
      #expect(history.sessionLog.values.allSatisfy { $0 !== replacement.item })
      #expect(history.sessionLog.count == (path == "limit" ? 1 : 0))
    }

    @Test("Screenshot insertion saves once after finalizing history", arguments: ["new", "duplicate", "eviction"])
    func screenshotInsertionSavesOnce(scenario: String) throws {
      let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
      ))
      bitmap.setColor(.red, atX: 0, y: 0)
      let data = try #require(bitmap.representation(using: .png, properties: [:]))
      let capture = ScreenshotCapture.shared
      if scenario == "duplicate" {
        try capture.saveInHistory(data)
      } else if scenario == "eviction" {
        Defaults[.size] = 1
        history.add(historyItem("old"))
      }

      let context = Storage.shared.context
      let autosaveEnabled = context.autosaveEnabled
      context.autosaveEnabled = false
      defer { context.autosaveEnabled = autosaveEnabled }
      let counts = SaveCounts()
      let willSave = NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: context, queue: nil) {
        _ in MainActor.assumeIsolated { counts.attempted += 1 }
      }
      let didSave = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: nil) {
        _ in MainActor.assumeIsolated { counts.completed += 1 }
      }
      defer {
        NotificationCenter.default.removeObserver(willSave)
        NotificationCenter.default.removeObserver(didSave)
      }

      try capture.saveInHistory(data)

      #expect(counts.attempted == 1)
      #expect(counts.completed == 1)
      let savedContext = ModelContext(Storage.shared.container)
      let savedItems = try savedContext.fetch(FetchDescriptor<HistoryItem>())
      let saved = try #require(savedItems.first)
      #expect(savedItems.count == 1)
      #expect(saved.title == NSLocalizedString("ScreenshotTitle", tableName: "GeneralSettings", comment: ""))
      #expect(saved.application == Bundle.main.bundleIdentifier)
      #expect(saved.numberOfCopies == (scenario == "duplicate" ? 2 : 1))
      #expect(saved.contents.count == 1)
      #expect(saved.contents.first?.value == data)
      #expect(!context.hasChanges)
    }

    @Test("Screenshot history notifications are silent without silencing ordinary copies")
    func screenshotHistoryNotificationIsSilent() throws {
      var notifications: [(title: String, sound: NSSound?)] = []
      let history = History(notifyNewItem: { notifications.append(($0, $1)) })
      defer { history.clearAll() }

      let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
      ))
      bitmap.setColor(.red, atX: 0, y: 0)
      let data = try #require(bitmap.representation(using: .png, properties: [:]))
      try ScreenshotCapture.shared.saveInHistory(data, history: history)
      history.add(historyItem("ordinary copy"))

      let screenshotTitle = NSLocalizedString("ScreenshotTitle", tableName: "GeneralSettings", comment: "")
      #expect(notifications.map(\.title) == [screenshotTitle, "ordinary copy"])
      #expect(notifications.first?.sound == nil)
      #expect(notifications.last?.sound === NSSound.write)
    }

    @Test("An attached item is saved without being inserted twice")
    func attachedItemIsSavedOnce() throws {
      let item = historyItem("attached")
      let counts = SaveCounts()
      let observer = NotificationCenter.default.addObserver(
        forName: ModelContext.didSave, object: Storage.shared.context, queue: nil
      ) { _ in MainActor.assumeIsolated { counts.completed += 1 } }
      defer { NotificationCenter.default.removeObserver(observer) }

      history.add(item)

      #expect(counts.completed == 1)
      #expect(!Storage.shared.context.hasChanges)
      #expect(try ModelContext(Storage.shared.container).fetchCount(FetchDescriptor<HistoryItem>()) == 1)
    }

    @Test("A storage save error propagates without undoing the screenshot clipboard copy")
    func screenshotStorageSaveFailurePreservesCopy() throws {
      let originalContainer = Storage.shared.container
      let originalChangeCount = Clipboard.shared.changeCount
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let url = directory.appendingPathComponent("History.sqlite")
      do {
        let writable = try ModelContainer(for: HistoryItem.self, configurations: ModelConfiguration(url: url))
        writable.mainContext.insert(HistoryItem())
        try writable.mainContext.save()
      }
      let configuration = ModelConfiguration(url: url, allowsSave: false)
      Storage.shared.container = try ModelContainer(for: HistoryItem.self, configurations: configuration)
      Storage.shared.context.autosaveEnabled = false
      defer {
        Storage.shared.context.rollback()
        Storage.shared.container = originalContainer
        history.clearAll()
        Clipboard.shared.changeCount = originalChangeCount
      }

      let data = Data("screenshot storage failure fixture".utf8)
      var presented = false
      let result = try ScreenshotCapture.deliverScreenshot(
        data, copy: Clipboard.shared.copyScreenshot, saveHistory: ScreenshotCapture.shared.saveInHistory,
        present: { presented = true }
      )

      guard case .failure = result else {
        Issue.record("The storage save error was swallowed")
        return
      }
      #expect(presented)
      #expect(NSPasteboard.general.data(forType: .png) == data)
    }

    @MainActor
    private final class SaveCounts {
      var attempted = 0
      var completed = 0
    }

    @Test("History mutations report a read-only storage failure",
          arguments: ["trimming history", "deleting a history item", "clearing history"])
    func historyStorageSaveFailureIsLogged(operation: String) async throws {
      let storage = Storage.shared
      let originalContainer = storage.container
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let url = directory.appendingPathComponent("History.sqlite")
      do {
        let writable = try ModelContainer(for: HistoryItem.self, configurations: ModelConfiguration(url: url))
        let item = historyItem("stored", persisted: false)
        writable.mainContext.insert(item)
        try writable.mainContext.save()
      }
      storage.container = try ModelContainer(
        for: HistoryItem.self, configurations: ModelConfiguration(url: url, allowsSave: false)
      )
      storage.context.autosaveEnabled = false
      defer {
        storage.context.rollback()
        storage.container = originalContainer
      }

      let log = HistoryErrorLog()
      let history = History(logger: Logging.Logger(label: "HistoryTests") { _ in log })
      if operation == "trimming history" {
        Defaults[.size] = 0
        try await history.load()
      } else {
        try await history.load()
        let row = try #require(history.firstUnpinnedItem)
        if operation == "deleting a history item" {
          history.delete(row)
        } else {
          history.clear()
        }
      }

      #expect(log.errors.withLock { $0.contains { $0.contains(operation) } })
    }

    private struct HistoryErrorLog: LogHandler {
      let errors = OSAllocatedUnfairLock(initialState: [String]())
      var logLevel = Logging.Logger.Level.error
      var metadata: Logging.Logger.Metadata = [:]

      subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
      }

      func log(event: LogEvent) {
        errors.withLock { $0.append(event.message.description) }
      }
    }

    @Test("Vision indexes delivered screenshots without changing their title or clipboard contents",
          arguments: ["Quartz Harbor", "截图历史"])
    func screenshotOCRSearch(keyword: String) async throws {
      defer { history.clearAll() }
      let text = "Maccy Test\n\(keyword)"
      let tiff = try #require(textImage(text).tiffRepresentation)
      let bitmap = try #require(NSBitmapImageRep(data: tiff))
      let data = try #require(bitmap.representation(using: .png, properties: [:]))
      let clipboardBeforeOCR = NSPasteboard.general.changeCount
      var presented = false
      let result = try ScreenshotCapture.deliverScreenshot(
        data, copy: { _ in true }, saveHistory: ScreenshotCapture.shared.saveInHistory,
        present: { presented = true }
      )
      try result.get()
      #expect(presented)
      let row = try #require(history.firstUnpinnedItem)
      try await waitForOCR { !history.ocrCoordinator.isRunning }

      #expect(row.title == NSLocalizedString("ScreenshotTitle", tableName: "GeneralSettings", comment: ""))
      #expect(row.item.recognizedText?.contains(keyword) == true)
      #expect(row.item.imageData == data)
      #expect(row.item.text == nil)
      #expect(NSPasteboard.general.changeCount == clipboardBeforeOCR)
      let saved = try #require(ModelContext(Storage.shared.container).fetch(FetchDescriptor<HistoryItem>()).first)
      let reloaded = HistoryItemDecorator(saved)
      let match = try #require(Search().search(string: keyword, within: [reloaded]).first)
      #expect(match.object == reloaded)
      #expect(match.ranges.isEmpty)

      try ScreenshotCapture.shared.saveInHistory(data)
      #expect(history.firstUnpinnedItem?.item.recognizedText == row.item.recognizedText)
      #expect(!history.ocrCoordinator.isRunning)
    }

    @Test("A search already open gains the matching screenshot when OCR completes", arguments: [false, true])
    func activeSearchUpdatesAfterOCR(pinned: Bool) async throws {
      let recognizer = ControlledHistoryRecognizer()
      let coordinator = HistoryOCRCoordinator(recognize: recognizer.recognize)
      let history = History(ocrCoordinator: coordinator)
      defer {
        recognizer.release(4)
        history.clearAll()
      }
      let item = ocrItem(0)
      item.title = "Screenshot"
      if pinned { item.pin = "b" }
      history.searchQuery = "recognized"
      let row = history.add(item, indexImage: true)
      try await waitForOCR { recognizer.calls.count == 1 }
      #expect(history.items.isEmpty)

      recognizer.release()
      try await waitForOCR { !coordinator.isRunning }
      #expect(history.items.toArray() == [row])
      #expect(row.title == "Screenshot")
      #expect(item.recognizedText == "recognized")
    }

    @Test("Preference title regeneration still schedules file-backed OCR")
    func preferenceTitleRegenerationSchedulesOCR() async throws {
      let recognizer = ControlledHistoryRecognizer()
      let coordinator = HistoryOCRCoordinator(recognize: recognizer.recognize)
      let history = History(ocrCoordinator: coordinator)
      defer {
        recognizer.release(4)
        history.clearAll()
      }
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpeg")
      let item = HistoryItem(contents: [
        HistoryItemContent(type: NSPasteboard.PasteboardType.fileURL.rawValue, value: url.dataRepresentation),
        HistoryItemContent(type: NSPasteboard.PasteboardType.universalClipboard.rawValue, value: Data())
      ])
      item.title = "existing"
      history.add(item)
      #expect(!coordinator.isRunning)

      history.updateTitlesForSpecialSymbols()

      try await waitForOCR { recognizer.calls.count == 1 }
      recognizer.release()
      try await waitForOCR { !coordinator.isRunning }
      #expect(item.title == "recognized")
    }

    @Test("Image OCR burst keeps one active and three newest pending jobs")
    func imageOCRBurstIsBounded() async throws {
      let recognizer = ControlledHistoryRecognizer()
      let coordinator = HistoryOCRCoordinator(recognize: recognizer.recognize)
      let history = History(ocrCoordinator: coordinator)
      defer {
        recognizer.release(8)
        history.clearAll()
      }
      let first = history.add(ocrItem(0))
      try await waitForOCR { recognizer.calls.count == 1 }
      var images = [first]
      for value in UInt8(1)...6 {
        images.append(history.add(ocrItem(value)))
        #expect(coordinator.pendingCount <= 3)
      }
      #expect(coordinator.pendingCount == 3)
      recognizer.release(4)
      try await waitForOCR { !coordinator.isRunning }

      #expect(recognizer.calls == [0, 4, 5, 6].map { Data([UInt8($0)]) })
      #expect(!recognizer.ranOnMainThread)
      #expect(images[1...3].allSatisfy { $0.item.title.isEmpty })
      #expect(images[4...6].allSatisfy { $0.item.title == "recognized" })
    }

    @Test("Deleting queued OCR never sets its title", arguments: ["delete", "clear", "clearAll", "limit"])
    func deletingQueuedOCR(path: String) async throws {
      let recognizer = ControlledHistoryRecognizer()
      let coordinator = HistoryOCRCoordinator(recognize: recognizer.recognize)
      let history = History(ocrCoordinator: coordinator)
      defer {
        recognizer.release(4)
        history.clearAll()
      }
      history.add(ocrItem(0))
      try await waitForOCR { recognizer.calls.count == 1 }
      let queued = history.add(ocrItem(1))
      #expect(coordinator.pendingCount == 1)

      switch path {
      case "delete": history.delete(queued)
      case "clear": history.clear()
      case "clearAll": history.clearAll()
      default:
        Defaults[.size] = 1
        history.add(historyItem("trigger eviction"))
      }
      #expect(coordinator.pendingCount == 0)
      recognizer.release()
      try await waitForOCR { !coordinator.isRunning }
      #expect(recognizer.calls.count == 1)
      #expect(queued.item.title.isEmpty)
      #expect(queued.item.recognizedText == nil)
    }

    @Test("Duplicate images share OCR and update only the live replacement")
    func duplicateImagesShareOCR() async throws {
      let recognizer = ControlledHistoryRecognizer()
      let coordinator = HistoryOCRCoordinator(recognize: recognizer.recognize)
      let history = History(ocrCoordinator: coordinator)
      defer {
        recognizer.release(4)
        history.clearAll()
      }
      let original = history.add(ocrItem(0))
      try await waitForOCR { recognizer.calls.count == 1 }
      let replacement = history.add(ocrItem(0))
      #expect(coordinator.pendingCount == 0)
      recognizer.release()
      try await waitForOCR { !coordinator.isRunning }

      #expect(recognizer.calls.count == 1)
      #expect(original.item.title.isEmpty)
      #expect(replacement.item.title == "recognized")
      #expect(replacement.title == "recognized")
      #expect(history.items.toArray() == [replacement])
    }

    @Test("OCR failure leaves the existing title unchanged")
    func imageOCRFailurePreservesTitle() async throws {
      let recognizer = ControlledHistoryRecognizer(fails: true)
      let coordinator = HistoryOCRCoordinator(recognize: recognizer.recognize)
      let history = History(ocrCoordinator: coordinator)
      defer {
        recognizer.release(4)
        history.clearAll()
      }
      let item = ocrItem(0)
      item.title = "unchanged"
      history.add(item)
      coordinator.enqueue(item, in: history)
      try await waitForOCR { recognizer.calls.count == 1 }
      recognizer.release()
      try await waitForOCR { !coordinator.isRunning }
      #expect(item.title == "unchanged")
    }

    @Test("An obsolete OCR generation cannot overwrite a newer request")
    func obsoleteOCRGenerationIsDiscarded() async throws {
      let recognizer = ControlledHistoryRecognizer()
      let coordinator = HistoryOCRCoordinator(recognize: recognizer.recognize)
      let history = History(ocrCoordinator: coordinator)
      defer {
        recognizer.release(4)
        history.clearAll()
      }
      let item = ocrItem(0)
      history.add(item)
      try await waitForOCR { recognizer.calls.count == 1 }
      item.contents[0].value = Data([1])
      coordinator.enqueue(item, in: history)
      recognizer.release()
      try await waitForOCR { recognizer.calls.count == 2 }
      #expect(item.title.isEmpty)
      recognizer.release()
      try await waitForOCR { !coordinator.isRunning }
      #expect(item.title == "recognized")
    }

    private func ocrItem(_ value: UInt8) -> HistoryItem {
      HistoryItem(contents: [HistoryItemContent(type: NSPasteboard.PasteboardType.png.rawValue, value: Data([value]))])
    }

    private func waitForOCR(_ condition: () -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(5)
      while !condition() && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(condition())
    }

    private final class ControlledHistoryRecognizer: @unchecked Sendable {
      private let lock = NSLock()
      private let gate = DispatchSemaphore(value: 0)
      private let fails: Bool
      private var recordedCalls: [Data] = []
      private var recordedMainThread = false

      init(fails: Bool = false) {
        self.fails = fails
      }

      var calls: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
      }

      var ranOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordedMainThread
      }

      func recognize(data: Data?, fileURL: URL?) throws -> String? {
        lock.lock()
        recordedCalls.append(data ?? Data())
        recordedMainThread = recordedMainThread || Thread.isMainThread
        lock.unlock()
        gate.wait()
        if fails { throw CocoaError(.fileReadCorruptFile) }
        return "recognized"
      }

      func release(_ count: Int = 1) {
        for _ in 0..<count { gate.signal() }
      }
    }

    @Test("Clearing unpinned")
    func clearingUnpinned() throws {
      let pinned = history.add(historyItem("foo"))
      history.togglePin(pinned)
      history.add(historyItem("bar"))
      let orphan = HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "orphan".data(using: .utf8)
      )
      Storage.shared.context.insert(orphan)
      try Storage.shared.context.save()

      history.clear()

      #expect(history.items.toArray() == [pinned])
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Clearing all")
    func clearingAll() throws {
      history.add(historyItem("foo"))
      let pinned = history.add(historyItem("bar"))
      history.togglePin(pinned)
      Storage.shared.context.insert(HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "orphan".data(using: .utf8)
      ))
      try Storage.shared.context.save()

      history.clearAll()

      #expect(history.items.toArray() == [])
      try assertStorageCounts(items: 0, contents: 0)
    }

    @Test("Max size")
    func maxSize() throws {
      var items: [HistoryItemDecorator] = []
      for index in 0...10 {
        items.append(history.add(historyItem(String(index))))
      }

      #expect(history.items.count == 10)
      #expect(history.items.contains(items[10]))
      #expect(!history.items.contains(items[0]))
      try assertStorageCounts(items: 10, contents: 10)
    }

    @Test("Max size ignores pinned")
    func maxSizeIgnoresPinned() {
      var items: [HistoryItemDecorator] = []

      let item = history.add(historyItem("0"))
      items.append(item)
      history.togglePin(item)

      for index in 1...11 {
        items.append(history.add(historyItem(String(index))))
      }

      #expect(history.items.count == 11)
      #expect(history.items.contains(items[10]))
      #expect(history.items.contains(items[0]))
      #expect(!history.items.contains(items[1]))
    }

    @Test("Pinning updates pin order")
    func pinningUpdatesPinOrder() {
      let item = history.add(historyItem("foo"))
      history.togglePin(item)

      #expect(history.pinnedItems == [item])
      #expect(Defaults[.pinOrder].pins == [item.item.pin].compactMap { $0 })
    }

    @Test("Pins without a free key get no shortcuts")
    func noShortcutsForPinWithoutKey() {
      #expect(KeyShortcut.create(character: "").isEmpty)
      #expect(KeyShortcut.create(character: "b").count == 3)
    }

    @Test("Pinning after all shortcuts are assigned")
    func pinningAfterAllShortcutsAreAssigned() async throws {
      let supportedPins = HistoryItem.supportedPins
      for index in 0..<supportedPins.count {
        let item = history.add(historyItem("keyed \(index)"))
        history.togglePin(item)
      }

      #expect(history.availablePins.isEmpty)
      #expect(Set(history.pinnedItems.compactMap(\.item.pin)) == supportedPins)

      let first = history.add(historyItem("first without shortcut"))
      history.togglePin(first)
      let second = history.add(historyItem("second without shortcut"))
      history.togglePin(second)

      #expect(first.item.pin == "")
      #expect(second.item.pin == "")
      #expect(history.pinnedItems.suffix(2) == [first, second])
      #expect(history.unpinnedItems.isEmpty)

      for index in 0...Defaults[.size] {
        history.add(historyItem("unpinned \(index)"))
      }

      let expectedCount = supportedPins.count + 2
      #expect(history.pinnedItems.count == expectedCount)
      try assertStorageCounts(
        items: expectedCount + Defaults[.size],
        contents: expectedCount + Defaults[.size]
      )

      try await history.load()
      #expect(history.pinnedItems.count == expectedCount)
      #expect(
        Set(history.pinnedItems.filter { $0.item.pin == "" }.map(\.title)) ==
        ["first without shortcut", "second without shortcut"]
      )
    }

    @Test("Unpinning updates pin order")
    func unpinningUpdatesPinOrder() {
      let item = history.add(historyItem("foo"))
      history.togglePin(item)
      history.togglePin(item)

      #expect(history.pinnedItems == [])
      #expect(Defaults[.pinOrder].pins == [])
    }

    @Test("Moving pins updates pin order")
    func movingPinsUpdatesPinOrder() {
      let first = history.add(historyItem("foo"))
      let second = history.add(historyItem("bar"))
      history.togglePin(first)
      history.togglePin(second)

      history.movePin(from: IndexSet(integer: 0), to: 2)

      #expect(history.pinnedItems == [second, first])
      #expect(Defaults[.pinOrder].pins == [second.item.pin, first.item.pin].compactMap { $0 })
    }

    @Test("Max size is changed")
    func maxSizeIsChanged() {
      var items: [HistoryItemDecorator] = []
      for index in 0...10 {
        items.append(history.add(historyItem(String(index))))
      }
      Defaults[.size] = 5
      history.add(historyItem("11"))

      #expect(history.items.count == 5)
      #expect(history.items.contains(items[10]))
      #expect(!history.items.contains(items[5]))
    }

    @Test("Re-adding bottom-most pinned item at full capacity")
    func readdingBottomMostPinnedItemAtFullCapacity() {
      // Regression test for a crash when re-copying (invoking) the bottom-most
      // pinned item while history is at full capacity and pins are sorted to the
      // bottom. The stale insert index used to trap with an out-of-bounds insert.
      // Issue link: https://github.com/p0deje/Maccy/issues/1466
      // `pinTo` is restored to its default value(.top) in `deinit`.
      Defaults[.pinTo] = .bottom

      // Pin an item; `history.togglePin` re-sorts `all`, so with `.bottom` the
      // pinned item ends up as the last element.
      let pinned = history.add(historyItem("pinned"))
      history.togglePin(pinned)

      // Fill unpinned history to full capacity.
      for index in 0..<Defaults[.size] {
        history.add(historyItem(String(index)))
      }

      #expect(history.items.last == pinned)

      // Re-copy the pinned item. It is detected as a duplicate, removed and
      // re-inserted while `limitHistorySize` trims an exceeding unpinned item.
      // Before the fix this inserted at a stale, out-of-bounds index and crashed.
      let readded = history.add(historyItem("pinned"))

      #expect(history.items.contains(readded))
      #expect(history.items.filter(\.isPinned).count == 1)
    }

    @Test("Removing")
    func removing() throws {
      let foo = history.add(historyItem("foo"))
      let bar = history.add(historyItem("bar"))
      history.delete(foo)
      #expect(history.items.toArray() == [bar])
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Cleaning up orphaned contents")
    func cleaningUpOrphanedContents() throws {
      let live = history.add(historyItem("live"))
      let liveContent = live.item.contents[0]
      for value in ["orphan-1", "orphan-2"] {
        Storage.shared.context.insert(HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value.data(using: .utf8)
        ))
      }
      try Storage.shared.context.save()

      #expect(try Storage.shared.cleanupOrphanedContents() == 2)
      #expect(try Storage.shared.cleanupOrphanedContents() == 0)
      #expect(live.item.contents == [liveContent])
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Removing unpersistable contents")
    func removingUnpersistableContents() throws {
      let live = history.add(historyItem("live"))
      live.item.contents.append(HistoryItemContent(
        type: NSPasteboard.PasteboardType.safariWebArchve.rawValue,
        value: Data(repeating: 0x61, count: 1024)
      ))
      try Storage.shared.context.save()

      #expect(try Storage.shared.removeUnpersistableContents() == 1)
      #expect(try Storage.shared.removeUnpersistableContents() == 0)
      #expect(live.item.contents.map(\.type) == [NSPasteboard.PasteboardType.string.rawValue])
      try assertStorageCounts(items: 1, contents: 1)
    }

    private func assertStorageCounts(
      items: Int,
      contents: Int,
      orphaned: Int = 0,
      fileID: String = #fileID,
      filePath: String = #filePath,
      line: Int = #line,
      column: Int = #column
    ) throws {
      let sourceLocation = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
      let context = Storage.shared.context
      context.processPendingChanges()
      try context.save()
      #expect(
        try context.fetchCount(FetchDescriptor<HistoryItem>()) == items,
        sourceLocation: sourceLocation
      )
      #expect(
        try context.fetchCount(FetchDescriptor<HistoryItemContent>()) == contents,
        sourceLocation: sourceLocation
      )
      #expect(
        try context.fetchCount(FetchDescriptor<HistoryItemContent>(
          predicate: #Predicate { $0.item == nil }
        )) == orphaned,
        sourceLocation: sourceLocation
      )
    }

    private func historyItem(_ value: String, persisted: Bool = true) -> HistoryItem {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value.data(using: .utf8)
        )
      ]
      let item = HistoryItem()
      if persisted {
        Storage.shared.context.insert(item)
      }
      item.contents = contents
      item.numberOfCopies = 1
      item.title = item.generateTitle()

      return item
    }
  }
}
