// swiftlint:disable file_length
import AppKit.NSRunningApplication
import AppKit.NSSound
import Defaults
import Foundation
import Logging
import Observation
import Sauce
import Settings
import SwiftData

@Observable
class History: ItemsContainer { // swiftlint:disable:this type_body_length
  static let shared = History()
  let logger: Logger

  var pasteStack: PasteStack?

  var items: ConcatenatedCollection<HistoryItemDecorator> {
    switch Defaults[.pinTo] {
    case .top:
      ConcatenatedCollection(pinnedItems, unpinnedItems)
    case .bottom:
      ConcatenatedCollection(unpinnedItems, pinnedItems)
    }
  }
  var pinnedItems: [HistoryItemDecorator] {
    searchQuery.isEmpty ? allPinnedItems : filteredPinnedItems
  }
  var unpinnedItems: [HistoryItemDecorator] {
    searchQuery.isEmpty ? allUnpinnedItems : filteredUnpinnedItems
  }
  var availablePins: [String] { pinManager.availablePins }

  var firstPinnedItem: HistoryItemDecorator? { pinnedItems.first }
  var firstUnpinnedItem: HistoryItemDecorator? { unpinnedItems.first }

  var searchQuery: String = "" {
    didSet(previousSearchQuery) {
      guard searchQuery != previousSearchQuery else { return }
      let query = searchQuery
      throttler.throttle { [self] in
        guard query == searchQuery else { return }
        updateSearchResults()

        if searchQuery.isEmpty {
          AppState.shared.navigator.select(item: firstUnpinnedItem)
        } else {
          AppState.shared.navigator.highlightFirst()
        }

        AppState.shared.popup.needsResize = true
      }
    }
  }

  var pressedShortcutItem: HistoryItemDecorator? {
    guard let event = NSApp.currentEvent else {
      return nil
    }

    let modifierFlags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting(.capsLock)

    guard HistoryItemAction(modifierFlags) != .unknown else {
      return nil
    }

    let key = Sauce.shared.key(for: Int(event.keyCode))
    return items.first { $0.shortcuts.contains(where: { $0.key == key }) }
  }

  private let search = Search()
  private let sorter = Sorter()
  private let throttler = Throttler(minimumDelay: 0.2)
  private let pinManager = PinManager()
  private let notifyNewItem: (String, NSSound?) -> Void
  private var allPinnedItems: [HistoryItemDecorator] { pinManager.pinnedItems }
  private var allUnpinnedItems: [HistoryItemDecorator] = []
  private var filteredPinnedItems: [HistoryItemDecorator] = []
  private var filteredUnpinnedItems: [HistoryItemDecorator] = []

  @ObservationIgnored
  private(set) var sessionLog: [Int: HistoryItem] = [:]
  @ObservationIgnored
  let ocrCoordinator: HistoryOCRCoordinator

  private struct IndexedItem {
    let decorator: HistoryItemDecorator
    let contents: [HistoryItemContent]
    let fingerprint: Set<Data>
  }

  @ObservationIgnored private var duplicateIndex: [Data: Set<ObjectIdentifier>] = [:]
  @ObservationIgnored private var indexedItems: [ObjectIdentifier: IndexedItem] = [:]
  @ObservationIgnored private var dirtyIndexedItems: Set<ObjectIdentifier> = []
  @ObservationIgnored private var loadGeneration = 0
  private var unpinnedSortBy = Defaults[.sortBy]

#if DEBUG
  static let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
#endif

  init(
    ocrCoordinator: HistoryOCRCoordinator = HistoryOCRCoordinator(),
    logger: Logger = Logger(label: "org.p0deje.Maccy"),
    notifyNewItem: @escaping (String, NSSound?) -> Void = { title, sound in
      Task { Notifier.notify(body: title, sound: sound) }
    }
  ) {
    self.ocrCoordinator = ocrCoordinator
    self.logger = logger
    self.notifyNewItem = notifyNewItem
    #if DEBUG
    guard !Self.isRunningUnitTests else { return }
    #endif

    Task {
      for await _ in Defaults.updates(.pasteByDefault, initial: false) {
        updateShortcuts()
      }
    }

    Task {
      for await _ in Defaults.updates(.sortBy, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.pinTo, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.showSpecialSymbols, initial: false) {
        updateTitlesForSpecialSymbols()
      }
    }

    Task {
      for await _ in Defaults.updates(.imageMaxHeight, initial: false) {
        for item in items {
          item.cleanupImages()
        }
      }
    }
  }

  @MainActor
  func load(waitForTurn: @MainActor () async -> Void = { await Task.yield() }) async throws {
    try Task.checkCancellation()
    loadGeneration &+= 1
    let generation = loadGeneration
    await waitForTurn()
    try Task.checkCancellation()
    guard generation == loadGeneration else { return }

    let descriptor = FetchDescriptor<HistoryItem>()
    let results = try Storage.shared.context.fetch(descriptor)
    let maxSize = Defaults[.size]
    var unpinnedCount = 0
    var exceedingItems: [HistoryItem] = []
    let retainedItems = sorter.sort(results).filter { item in
      guard item.pin == nil else { return true }
      unpinnedCount += 1
      guard unpinnedCount > maxSize else { return true }
      exceedingItems.append(item)
      return false
    }
    try Task.checkCancellation()
    if !exceedingItems.isEmpty {
      exceedingItems.forEach { deleteFromStorage($0) }
      Storage.shared.context.processPendingChanges()
      saveHistoryChanges(after: "trimming history")
    }
    let decorators = retainedItems.map { HistoryItemDecorator($0) }
    pinManager.load(from: decorators)
    allUnpinnedItems = decorators.filter(\.isUnpinned)
    unpinnedSortBy = Defaults[.sortBy]
    if searchQuery.isEmpty {
      filteredPinnedItems = allPinnedItems
      filteredUnpinnedItems = allUnpinnedItems
    } else {
      updateSearchResults()
    }
    rebuildDuplicateIndex(decorators)

    updateShortcuts()
    // Ensure that panel size is proper *after* loading all items.
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  private func limitHistorySize(to maxSize: Int, saveToStorage: Bool = true) {
    if allUnpinnedItems.count >= maxSize {
      allUnpinnedItems[maxSize...].forEach { delete($0, saveToStorage: saveToStorage) }
    }
  }

  @MainActor
  func insertIntoStorage(_ item: HistoryItem) throws {
    logger.info("Inserting item with id '\(item.title)'")
    if item.modelContext == nil {
      Storage.shared.context.insert(item)
    }
    Storage.shared.context.processPendingChanges()
    try Storage.shared.context.save()
  }

  @discardableResult
  @MainActor
  func add(
    _ item: HistoryItem, saveToStorage: Bool = true, indexImage: Bool = false, playNotificationSound: Bool = true
  ) -> HistoryItemDecorator {
    if item.modelContext == nil {
      Storage.shared.context.insert(item)
    }

    var replacedPinnedItem: HistoryItemDecorator?
    if let existingHistoryItem = findSimilarItem(item) {
      if isModified(item) == nil {
        transferContents(from: existingHistoryItem, to: item)
        item.recognizedText = existingHistoryItem.recognizedText
      }
      item.firstCopiedAt = existingHistoryItem.firstCopiedAt
      item.numberOfCopies += existingHistoryItem.numberOfCopies
      item.pin = existingHistoryItem.pin
      if !existingHistoryItem.title.isEmpty {
        item.title = existingHistoryItem.title
      }
      if !item.fromMaccy {
        item.application = existingHistoryItem.application
      }
      logger.info("Removing duplicate item '\(item.title)'")
      if let existingDecorator = indexedItems[ObjectIdentifier(existingHistoryItem)]?.decorator {
        cleanup(existingDecorator)
        allUnpinnedItems.removeAll { $0 == existingDecorator }
        if existingDecorator.isPinned {
          replacedPinnedItem = existingDecorator
        }
      }
      deleteFromStorage(existingHistoryItem, replacingWith: item)
    } else {
      notifyNewItem(item.title, playNotificationSound ? .write : nil)
    }

    // Remove exceeding items. Do this after the item is added to avoid removing something
    // if a duplicate was found as then the size already stayed the same.
    let reservedSlots = item.pin == nil ? 1 : 0
    let existingItemLimit = max(Defaults[.size], reservedSlots) - reservedSlots
    limitHistorySize(to: existingItemLimit, saveToStorage: false)

    sessionLog[Clipboard.shared.changeCount] = item

    let itemDecorator: HistoryItemDecorator
    if let pin = item.pin {
      itemDecorator = HistoryItemDecorator(item, shortcuts: KeyShortcut.create(character: pin))
      if let replacedPinnedItem {
        pinManager.replace(replacedPinnedItem, with: itemDecorator)
      } else {
        pinManager.add(itemDecorator)
      }
    } else {
      itemDecorator = HistoryItemDecorator(item)
      insertUnpinned(itemDecorator)
    }
    index(itemDecorator)

    if searchQuery.isEmpty {
      updateUnpinnedShortcuts()
    } else {
      updateSearchResults()
    }
    AppState.shared.popup.needsResize = true
    if saveToStorage {
      do {
        try insertIntoStorage(item)
      } catch {
        logger.error("Failed to save history: \(String(reflecting: error))")
      }
    }
    if indexImage || item.title.isEmpty {
      ocrCoordinator.enqueue(item, in: self)
    }
    return itemDecorator
  }

  @MainActor
  private func saveHistoryChanges(after operation: String) {
    do {
      try Storage.shared.context.save()
    } catch {
      logger.error("Failed to save history after \(operation): \(String(reflecting: error))")
    }
  }

  @MainActor
  private func withLogging(_ msg: String, _ block: () -> Void) {
    func dataCounts() -> String {
      let historyItemCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItem>())
      let historyContentCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItemContent>())
      return "HistoryItem=\(historyItemCount ?? 0) HistoryItemContent=\(historyContentCount ?? 0)"
    }

    logger.info("\(msg) Before: \(dataCounts())")
    block()
    logger.info("\(msg) After: \(dataCounts())")
  }

  @MainActor
  func clear() {
    withLogging("Clearing history") {
      allUnpinnedItems.forEach {
        ocrCoordinator.cancel($0.item)
        unindex($0.item)
        cleanup($0)
      }
      allUnpinnedItems.removeAll()
      filteredUnpinnedItems.removeAll()
      updateSessionLog(removing: { $0.pin == nil })

      let context = Storage.shared.context
      do {
        try context.transaction {
          try context.delete(
            model: HistoryItem.self,
            where: #Predicate { $0.pin == nil }
          )
          try context.delete(
            model: HistoryItemContent.self,
            where: #Predicate { $0.item?.pin == nil }
          )
        }
      } catch {
        logger.error("Failed while clearing history: \(String(reflecting: error))")
      }
      context.processPendingChanges()
      saveHistoryChanges(after: "clearing history")
    }

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func clearAll() {
    withLogging("Clearing all history") {
      ocrCoordinator.cancelAll()
      allPinnedItems.forEach(cleanup)
      allUnpinnedItems.forEach(cleanup)
      allUnpinnedItems.removeAll()
      filteredPinnedItems.removeAll()
      filteredUnpinnedItems.removeAll()
      pinManager.removeAll()
      rebuildDuplicateIndex([])
      updateSessionLog(removing: { _ in true })

      do {
        let context = Storage.shared.context
        try context.transaction {
          // Bulk deletion cannot remove children with live inverse relationships.
          try context.delete(
            model: HistoryItemContent.self,
            where: #Predicate { $0.item == nil }
          )
          try context.delete(model: HistoryItem.self)
          try context.delete(model: HistoryItemContent.self)
        }
      } catch {
        logger.error("Failed to clear storage: \(String(reflecting: error))")
      }
      Storage.shared.context.processPendingChanges()
      saveHistoryChanges(after: "clearing all history")
    }

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func delete(_ item: HistoryItemDecorator?, saveToStorage: Bool = true) {
    guard let item else { return }

    cleanup(item)
    withLogging("Removing history item") {
      deleteFromStorage(item.item)
      Storage.shared.context.processPendingChanges()
      if saveToStorage {
        saveHistoryChanges(after: "deleting a history item")
      }
    }

    pinManager.remove(item)
    allUnpinnedItems.removeAll { $0 == item }
    filteredPinnedItems.removeAll { $0 == item }
    filteredUnpinnedItems.removeAll { $0 == item }

    updateUnpinnedShortcuts()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  private func transferContents(from existingItem: HistoryItem, to newItem: HistoryItem) {
    deleteContents(of: newItem)
    newItem.contents = existingItem.contents
    existingItem.contents = []
  }

  @MainActor
  private func deleteFromStorage(_ item: HistoryItem, replacingWith replacement: HistoryItem? = nil) {
    unindex(item)
    if let replacement {
      ocrCoordinator.replace(item, with: replacement, in: self)
    } else {
      ocrCoordinator.cancel(item)
    }
    updateSessionLog(removing: { $0 === item }, replacingWith: replacement)
    deleteContents(of: item)
    Storage.shared.context.delete(item)
  }

  private func updateSessionLog(
    removing predicate: (HistoryItem) -> Bool,
    replacingWith replacement: HistoryItem? = nil
  ) {
    let changeCounts = sessionLog.filter { predicate($0.value) }.map(\.key)
    for changeCount in changeCounts {
      sessionLog[changeCount] = replacement
    }
  }

  @MainActor
  private func deleteContents(of item: HistoryItem) {
    item.contents.forEach(Storage.shared.context.delete)
  }

  @MainActor
  private func cleanup(_ item: HistoryItemDecorator) {
    item.cleanupImages()
  }

  @MainActor
  func select(_ item: HistoryItemDecorator?, flags modifierFlags: NSEvent.ModifierFlags) {
    guard let item else {
      return
    }

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      if Defaults[.pasteByDefault] {
        Clipboard.shared.paste()
      }
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
        Clipboard.shared.paste()
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  @MainActor
  func startPasteStack(selection: inout Selection<HistoryItemDecorator>, flags modifierFlags: NSEvent.ModifierFlags) {
    guard AppState.shared.multiSelectionEnabled else { return }
    guard let item = selection.first else { return }
    PasteStack.initializeIfNeeded()

    let stack = PasteStack(items: selection.items, modifierFlags: modifierFlags)
    pasteStack = stack

    logger.info("Initialising PasteStack with \(stack.items.count) items")
    logger.info("Copying \(item.item.title) from PasteStack")

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  func handlePasteStack() {
    guard let stack = pasteStack else {
      return
    }

    guard let pasted = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("PasteStack pasted \(pasted.item.title)")

    stack.items.removeFirst()

    guard let item = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("Copying \(item.item.title) from PasteStack. \(stack.items.count) items remaining in stack.")

    Task {
      if stack.modifierFlags.isEmpty {
        Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      } else {
        switch HistoryItemAction(stack.modifierFlags) {
        case .copy:
          Clipboard.shared.copy(item.item)
        case .paste:
          Clipboard.shared.copy(item.item)
        case .pasteWithoutFormatting:
          Clipboard.shared.copy(item.item, removeFormatting: true)
        case .unknown:
          return
        }
      }
    }
  }

  func interruptPasteStack() {
    guard pasteStack != nil else {
      return
    }
    logger.info("Interrupting PasteStack")
    pasteStack = nil
  }

  @MainActor
  func togglePin(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    let wasPinned = item.isPinned
    pinManager.toggle(item)
    guard item.isPinned != wasPinned else { return }

    if wasPinned {
      insertUnpinned(item)
    } else {
      allUnpinnedItems.removeAll { $0 == item }
    }

    searchQuery = ""
    updateUnpinnedShortcuts()
    if item.isUnpinned {
      AppState.shared.navigator.scrollTarget = item.id
    }
  }

  @MainActor
  func movePin(from source: IndexSet, to destination: Int) {
    guard searchQuery.isEmpty else { return }
    pinManager.move(from: source, to: destination)
  }

  @MainActor
  func updatePin(_ item: HistoryItem, to pin: String) {
    guard let itemDecorator = firstStoredItem(where: { $0.item.id == item.id }) else { return }

    let wasPinned = itemDecorator.isPinned
    pinManager.updatePin(of: itemDecorator, to: pin)
    if !wasPinned && itemDecorator.isPinned {
      allUnpinnedItems.removeAll { $0 == itemDecorator }
    }
    updateShortcuts()
  }

  @MainActor
  private func findSimilarItem(_ item: HistoryItem) -> HistoryItem? {
    refreshDuplicateIndex()
    let fingerprint = item.comparableContentFingerprint
    var identities: Set<ObjectIdentifier>
    if fingerprint.isEmpty {
      identities = Set(indexedItems.keys)
    } else {
      let buckets = fingerprint.map { duplicateIndex[$0] ?? [] }.sorted { $0.count < $1.count }
      identities = buckets[0]
      for bucket in buckets.dropFirst() {
        identities.formIntersection(bucket)
        if identities.isEmpty { break }
      }
    }
    let candidates = identities.compactMap { indexedItems[$0]?.decorator.item }
      .filter { $0 != item && $0.supersedes(item) }
    if candidates.count == 1 {
      return candidates[0]
    }
    if candidates.count > 1 {
      let matches = Set(candidates.map(ObjectIdentifier.init))
      return firstStoredItem(where: { matches.contains(ObjectIdentifier($0.item)) })?.item
    }

    return isModified(item)
  }

  private func index(_ decorator: HistoryItemDecorator) {
    let identity = ObjectIdentifier(decorator.item)
    unindex(decorator.item)
    let contents = decorator.item.contents
    let fingerprint = withObservationTracking {
      for content in contents {
        _ = content.type
        _ = content.value
      }
      return decorator.item.comparableContentFingerprint
    } onChange: { [weak self] in
      MainActor.assumeIsolated {
        _ = self?.dirtyIndexedItems.insert(identity)
      }
    }
    indexedItems[identity] = IndexedItem(decorator: decorator, contents: contents, fingerprint: fingerprint)
    for content in fingerprint {
      duplicateIndex[content, default: []].insert(identity)
    }
  }

  private func unindex(_ item: HistoryItem) {
    let identity = ObjectIdentifier(item)
    dirtyIndexedItems.remove(identity)
    guard let indexed = indexedItems.removeValue(forKey: identity) else { return }
    for content in indexed.fingerprint {
      duplicateIndex[content]?.remove(identity)
      if duplicateIndex[content]?.isEmpty == true {
        duplicateIndex.removeValue(forKey: content)
      }
    }
  }

  private func refreshDuplicateIndex() {
    let dirty = dirtyIndexedItems
    dirtyIndexedItems.removeAll()
    for identity in dirty {
      if let decorator = indexedItems[identity]?.decorator {
        index(decorator)
      }
    }
  }

  private func rebuildDuplicateIndex(_ decorators: [HistoryItemDecorator]) {
    duplicateIndex.removeAll()
    indexedItems.removeAll()
    dirtyIndexedItems.removeAll()
    decorators.forEach(index)
  }

  private func isModified(_ item: HistoryItem) -> HistoryItem? {
    if let modified = item.modified, sessionLog.keys.contains(modified) {
      return sessionLog[modified]
    }

    return nil
  }

  private func updateSearchResults() {
    filteredPinnedItems = filteredItems(
      from: search.search(string: searchQuery, within: allPinnedItems)
    )
    filteredUnpinnedItems = filteredItems(
      from: search.search(string: searchQuery, within: allUnpinnedItems)
    )

    updateUnpinnedShortcuts()
  }

  private func filteredItems(from results: [Search.SearchResult]) -> [HistoryItemDecorator] {
    results.map { result in
      let item = result.object
      item.highlight(searchQuery, result.ranges)

      return item
    }
  }

  private func firstStoredItem(
    where predicate: (HistoryItemDecorator) -> Bool
  ) -> HistoryItemDecorator? {
    allPinnedItems.first(where: predicate) ?? allUnpinnedItems.first(where: predicate)
  }

  private func insertUnpinned(_ item: HistoryItemDecorator) {
    let by = Defaults[.sortBy]
    if unpinnedSortBy != by {
      allUnpinnedItems.sort { sorter.precedes($0.item, $1.item, by: by) }
      unpinnedSortBy = by
    }
    var lower = 0
    var upper = allUnpinnedItems.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if sorter.precedes(item.item, allUnpinnedItems[middle].item, by: by) {
        upper = middle
      } else {
        lower = middle + 1
      }
    }
    allUnpinnedItems.insert(item, at: lower)
  }

  private func updateShortcuts() {
    for item in pinManager.pinnedItems {
      if let pin = item.item.pin {
        item.shortcuts = KeyShortcut.create(character: pin)
      }
    }

    updateUnpinnedShortcuts()
  }

  @MainActor
  func updateTitlesForSpecialSymbols() {
    for item in items where item.item.imageData == nil {
      updateTitle(item: item, title: item.item.generateTitle())
      if item.item.textRecognitionInput != nil {
        ocrCoordinator.enqueue(item.item, in: self)
      }
    }
  }

  @MainActor
  private func updateTitle(item: HistoryItemDecorator, title: String) {
    item.title = title
    item.item.title = title
  }

  func applyRecognizedText(_ text: String, to item: HistoryItem) {
    guard !item.isDeleted, let context = item.modelContext, item.textRecognitionInput != nil,
          let decorator = firstStoredItem(where: { $0.item === item }) else { return }
    item.recognizedText = text
    if item.title.isEmpty {
      updateTitle(item: decorator, title: text.removingScalarsUnsafeForTitleLayout())
    }
    if !searchQuery.isEmpty {
      let hadResults = !items.isEmpty
      updateSearchResults()
      if !hadResults && !items.isEmpty && self === Self.shared {
        AppState.shared.navigator.highlightFirst()
      }
      AppState.shared.popup.needsResize = true
    }
    do {
      try context.save()
    } catch {
      logger.error("Failed to save recognized image text: \(String(reflecting: error))")
    }
  }

  private func updateUnpinnedShortcuts() {
    let shortcutItems = unpinnedItems.filter(\.isVisible)
    for item in shortcutItems {
      item.shortcuts = []
    }

    var index = 1
    for item in shortcutItems.prefix(9) {
      item.shortcuts = KeyShortcut.create(character: String(index))
      index += 1
    }
  }
}
