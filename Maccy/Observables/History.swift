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
  @ObservationIgnored private var loadTask: Task<Void, Error>?
  private var unpinnedSortBy = Defaults[.sortBy]

#if DEBUG
  nonisolated static let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
#endif

  init(
    ocrCoordinator: HistoryOCRCoordinator = HistoryOCRCoordinator(),
    logger: Logger = Logger(label: "org.p0deje.Maccy"),
    notifyNewItem: @escaping (String, NSSound?) -> Void = { title, sound in
      Notifier.notify(body: title, sound: sound)
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
  func load(waitForTurn: @escaping @MainActor () async -> Void = {}) async throws {
    try Task.checkCancellation()
    loadGeneration &+= 1
    let generation = loadGeneration
    loadTask?.cancel()
    let task = Task {
      try checkLoad(generation: generation)
      await waitForTurn()
      try checkLoad(generation: generation)
    }
    loadTask = task
    defer {
      if generation == loadGeneration {
        loadTask = nil
      }
    }

    do {
      try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      try runLoad(generation: generation)
    } catch is CancellationError where generation != loadGeneration {
      try Task.checkCancellation()
    }
  }

  private func checkLoad(generation: Int) throws {
    try Task.checkCancellation()
    guard generation == loadGeneration else { throw CancellationError() }
  }

  private func runLoad(generation: Int) throws {
    try checkLoad(generation: generation)

    let descriptor = FetchDescriptor<HistoryItem>()
    let results = try Storage.shared.context.fetch(descriptor)
    try checkLoad(generation: generation)
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
    try checkLoad(generation: generation)
    let decorators = try retainedItems.map {
      try Task.checkCancellation()
      return HistoryItemDecorator($0)
    }
    try checkLoad(generation: generation)
    if !exceedingItems.isEmpty {
      try persistDeletion(operation: "trimming history") { context in exceedingItems.forEach(context.delete) }
      exceedingItems.forEach { forget($0) }
    }
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
  private func limitHistorySize(to maxSize: Int) {
    for row in allUnpinnedItems.dropFirst(maxSize) {
      deleteFromStorage(row.item)
      removeRow(row, pin: nil)
    }
  }

  @MainActor
  func insertIntoStorage(_ item: HistoryItem) throws {
    logger.info("Saving history item")
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
      logger.info("Removing duplicate history item")
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
    limitHistorySize(to: existingItemLimit)

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
        logger.error("Failed to save history")
      }
    }
    if indexImage || item.title.isEmpty {
      ocrCoordinator.enqueue(item, in: self)
    }
    return itemDecorator
  }

  @MainActor
  private func persistDeletion(operation: String, _ stage: (ModelContext) throws -> Void) throws {
    let context = Storage.shared.context
    do {
      if context.hasChanges { try context.save() }
      do {
        try context.transaction {
          try stage(context)
          try context.save()
        }
      } catch {
        context.rollback()
        throw error
      }
    } catch {
      logger.error("Failed while \(operation)")
      throw error
    }
  }

  @MainActor
  @discardableResult
  func clear(includingPinned: Bool = false) -> Bool {
    do {
      try clearPersisted(includingPinned: includingPinned)
      return true
    } catch {
      return false
    }
  }

  @MainActor
  func clearAll() {
    clear(includingPinned: true)
  }

  @MainActor
  func clearPersisted(includingPinned: Bool) throws {
    let removed = includingPinned ? allPinnedItems + allUnpinnedItems : allUnpinnedItems
    let removedAliases = sessionLog.compactMap { includingPinned || $0.value.pin == nil ? $0.key : nil }
    let orphaned = FetchDescriptor<HistoryItemContent>(predicate: #Predicate { $0.item == nil })
    let descriptor = includingPinned ? FetchDescriptor<HistoryItem>()
      : FetchDescriptor(predicate: #Predicate<HistoryItem> { $0.pin == nil })
    try persistDeletion(operation: includingPinned ? "clearing all history" : "clearing history") { context in
      for orphan in try context.fetch(orphaned) { context.delete(orphan) }
      for item in try context.fetch(descriptor) { context.delete(item) }
    }

    for row in removed {
      ocrCoordinator.cancel(row.item)
      unindex(row.item)
      cleanup(row)
    }
    for key in removedAliases { sessionLog.removeValue(forKey: key) }
    allUnpinnedItems.removeAll()
    filteredUnpinnedItems.removeAll()
    if includingPinned {
      pinManager.removeAll()
      filteredPinnedItems.removeAll()
    }
    interruptPasteStack()
    if self === Self.shared { AppState.shared.navigator.select() }
    Clipboard.shared.clear()
    AppState.shared.popup.close()
    AppState.shared.popup.needsResize = true
  }

  @MainActor
  func delete(_ item: HistoryItemDecorator?) {
    guard let item else { return }
    do { try deletePersisted([item]) } catch { reportDeleteFailure() }
  }

  func reportDeleteFailure() {
    let alert = NSAlert()
    alert.messageText = NSLocalizedString("history_delete_failed", comment: "")
    alert.runModal()
  }

  func deletePersisted(_ rows: [HistoryItemDecorator]) throws {
    let removed = rows.map { ($0, $0.item.pin) }
    try persistDeletion(operation: "deleting a history item") { context in rows.forEach { context.delete($0.item) } }
    for (row, pin) in removed {
      forget(row.item)
      removeRow(row, pin: pin)
    }
    if let stack = pasteStack, rows.contains(where: stack.items.contains) { interruptPasteStack() }
    if self === Self.shared && rows.contains(where: AppState.shared.navigator.selection.items.contains) {
      AppState.shared.navigator.select()
    }
    updateUnpinnedShortcuts()
    AppState.shared.popup.needsResize = true
  }

  private func removeRow(_ item: HistoryItemDecorator, pin: String?) {
    cleanup(item)
    pinManager.remove(item, pin: pin)
    allUnpinnedItems.removeAll { $0 == item }
    filteredPinnedItems.removeAll { $0 == item }
    filteredUnpinnedItems.removeAll { $0 == item }
  }

  @MainActor
  private func transferContents(from existingItem: HistoryItem, to newItem: HistoryItem) {
    deleteContents(of: newItem)
    newItem.contents = existingItem.contents
    existingItem.contents = []
  }

  @MainActor
  private func deleteFromStorage(_ item: HistoryItem, replacingWith replacement: HistoryItem? = nil) {
    forget(item, replacingWith: replacement)
    deleteContents(of: item)
    Storage.shared.context.delete(item)
  }

  private func forget(_ item: HistoryItem, replacingWith replacement: HistoryItem? = nil) {
    unindex(item)
    if let replacement {
      ocrCoordinator.replace(item, with: replacement, in: self)
    } else {
      ocrCoordinator.cancel(item)
    }
    updateSessionLog(removing: { $0 === item }, replacingWith: replacement)
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

    guard !stack.items.isEmpty else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    stack.items.removeFirst()

    guard let item = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("Copying from PasteStack. \(stack.items.count) items remaining.")

    Task {
      guard self.pasteStack === stack else { return }
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
      logger.error("Failed to save recognized image text")
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
