import XCTest
import Defaults
import SwiftData
@testable import Maccy

@MainActor
class HistoryTests: XCTestCase { // swiftlint:disable:this type_body_length
  let savedSize = Defaults[.size]
  let savedSortBy = Defaults[.sortBy]
  let savedPinTo = Defaults[.pinTo]
  let history = History.shared

  override func setUp() {
    super.setUp()
    history.clearAll()
    Defaults[.size] = 10
    Defaults[.sortBy] = .firstCopiedAt
    Defaults[.pinTo] = .bottom
  }

  override func tearDown() {
    super.tearDown()
    Defaults[.size] = savedSize
    Defaults[.sortBy] = savedSortBy
    Defaults[.pinTo] = savedPinTo
  }

  func testDefaultIsEmpty() {
    XCTAssertEqual(history.items, [])
  }

  func testLoading() async throws {
    let foo = history.add(historyItem("foo"))
    let bar = history.add(historyItem("bar"))
    history.togglePin(bar)
    let baz = history.add(historyItem("baz"))
    try Storage.shared.context.save()

    try await history.load()

    XCTAssertEqual(history.all.map(\.item), Sorter().sort([foo, bar, baz].map(\.item)))
    XCTAssertEqual(history.items, history.all)
    XCTAssertEqual(history.all.map(\.pin), history.all.map(\.item.pin))
    XCTAssertEqual(history.all.map(\.item.contents.count), [1, 1, 1])
    XCTAssertEqual(history.all.map(\.title), history.all.map(\.item.title))
  }

  func testAdding() {
    let first = history.add(historyItem("foo"))
    let second = history.add(historyItem("bar"))
    XCTAssertEqual(history.items, [second, first])
  }

  func testAddingPersistedDuplicate() throws {
    let first = historyItem("foo")
    first.title = "xyz"
    first.application = "iTerm.app"
    history.add(first)
    first.pin = "f"

    let third = historyItem("foo")
    third.application = "Xcode.app"
    let transferredContents = first.contents
    let merged = history.add(third)

    XCTAssertEqual(history.all, [merged])
    XCTAssertEqual(Set(merged.item.contents), Set(transferredContents))
    XCTAssertTrue(merged.item.lastCopiedAt > merged.item.firstCopiedAt)
    XCTAssertEqual(merged.item.numberOfCopies, 2)
    XCTAssertEqual(merged.item.pin, "f")
    XCTAssertEqual(merged.item.title, "xyz")
    XCTAssertEqual(merged.item.application, "iTerm.app")
    try assertStorageCounts(items: 1, contents: 1)
  }

  // A superseded duplicate is deleted from storage and must be released from memory
  // too, including its entry in the session log that maps clipboard change counts.
  func testAddingDuplicateReleasesSupersededItem() throws {
    weak var weakDecorator: HistoryItemDecorator?
    weak var weakItem: HistoryItem?

    try autoreleasepool {
      let first = historyItem("foo")
      weakDecorator = history.add(first)
      weakItem = first
      // A different change count keeps the first item's session log entry
      // alive. Restore it before the run loop spins below, or the clipboard
      // poller sees a change and adds whatever the system clipboard holds.
      let changeCount = Clipboard.shared.changeCount
      Clipboard.shared.changeCount += 1
      history.add(historyItem("foo"))
      Clipboard.shared.changeCount = changeCount
      // The context holds the deleted item until the pending deletion is saved.
      try Storage.shared.context.save()
    }
    // Deferred work scheduled during the add still holds the item for one turn.
    drainMainQueue()

    XCTAssertEqual(history.all.count, 1)
    XCTAssertNil(weakDecorator)
    XCTAssertNil(weakItem)
  }

  private func drainMainQueue() {
    let drained = expectation(description: "main queue drained")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { drained.fulfill() }
    wait(for: [drained], timeout: 2)
  }

  func testAddingUnsavedDuplicate() throws {
    guard #available(macOS 15.0, *) else {
      throw XCTSkip("Incoming history items are inserted before add on macOS 14")
    }

    let first = historyItem("foo")
    first.title = "xyz"
    first.application = "iTerm.app"
    history.add(first)
    first.pin = "f"

    let second = historyItem("foo", persisted: false)
    second.application = "Xcode.app"
    let transferredContents = first.contents
    let merged = history.add(second)

    XCTAssertEqual(history.all, [merged])
    XCTAssertEqual(Set(merged.item.contents), Set(transferredContents))
    XCTAssertTrue(merged.item.lastCopiedAt > merged.item.firstCopiedAt)
    XCTAssertEqual(merged.item.numberOfCopies, 2)
    XCTAssertEqual(merged.item.pin, "f")
    XCTAssertEqual(merged.item.title, "xyz")
    XCTAssertEqual(merged.item.application, "iTerm.app")
    try assertStorageCounts(items: 1, contents: 1)
  }

  // Edits made in the pins settings change an item's contents behind its
  // decorator; the next copy of the edited text still has to be deduplicated.
  func testAddingDuplicateOfEditedItem() throws {
    let edited = history.add(historyItem("foo"))
    edited.item.contents[0].value = "bar".data(using: .utf8)
    history.contentsDidChange(edited.item)

    let merged = history.add(historyItem("bar"))

    XCTAssertEqual(history.all, [merged])
    XCTAssertEqual(merged.item.numberOfCopies, 2)
    try assertStorageCounts(items: 1, contents: 1)
  }

  func testAddingKeepsSorterOrderForLastCopiedAtWithPinsOnTop() {
    Defaults[.sortBy] = .lastCopiedAt
    Defaults[.pinTo] = .top
    assertAddingKeepsSorterOrder()
  }

  func testAddingKeepsSorterOrderForLastCopiedAtWithPinsAtBottom() {
    Defaults[.sortBy] = .lastCopiedAt
    Defaults[.pinTo] = .bottom
    assertAddingKeepsSorterOrder()
  }

  // Interleaves pinned and unpinned items, an item copied at the same instant
  // as another and one with an older timestamp, checking after each add that
  // the new item lands at the index a full sort of `all` plus the item gives.
  private func assertAddingKeepsSorterOrder(file: StaticString = #filePath, line: UInt = #line) {
    let sorter = Sorter()
    let now = Date.now
    func add(_ value: String, lastCopiedAt: TimeInterval, pinned: Bool = false) -> HistoryItemDecorator {
      let item = historyItem(value)
      item.lastCopiedAt = now.addingTimeInterval(lastCopiedAt)
      var expected = history.all
      let expectedIndex = sorter.sort(expected.map(\.item) + [item]).firstIndex(of: item)!
      let decorator = history.add(item)
      expected.insert(decorator, at: expectedIndex)
      XCTAssertEqual(history.all, expected, "\(value) pinTo=\(Defaults[.pinTo])", file: file, line: line)
      if pinned {
        history.togglePin(decorator)
      }
      return decorator
    }

    XCTAssertTrue(history.all.isEmpty, file: file, line: line)
    _ = add("first", lastCopiedAt: -50)
    _ = add("pinned-1", lastCopiedAt: -45, pinned: true)
    _ = add("second", lastCopiedAt: -40)
    _ = add("pinned-2", lastCopiedAt: -35, pinned: true)
    _ = add("third", lastCopiedAt: -30)
    _ = add("same-instant", lastCopiedAt: -30)
    _ = add("older", lastCopiedAt: -60)
    let newest = add("newest", lastCopiedAt: -10)
    XCTAssertEqual(history.unpinnedItems.first, newest, file: file, line: line)
    XCTAssertEqual(history.pinnedItems.count, 2, file: file, line: line)
    XCTAssertEqual(history.unpinnedItems.count, 6, file: file, line: line)

    // Re-copying a pinned item keeps it at its old position rather than the one
    // the sorter would give it. Later unpinned copies still have to land where
    // they always did.
    let readded = historyItem("pinned-1")
    readded.lastCopiedAt = now.addingTimeInterval(-5)
    XCTAssertTrue(history.add(readded).isPinned, file: file, line: line)
    _ = add("after-readd", lastCopiedAt: -1)
    _ = add("after-after-readd", lastCopiedAt: 0)
    XCTAssertEqual(history.pinnedItems.count, 2, file: file, line: line)
    XCTAssertEqual(history.unpinnedItems.count, 8, file: file, line: line)
  }

  func testUnpinnedShortcutsAreOnlyReassignedWhenChanged() {
    var items: [HistoryItemDecorator] = []
    for index in 0...9 {
      items.append(history.add(historyItem(String(index))))
    }
    // Newest first: items[9] has shortcut 1, items[1] has shortcut 9, items[0] has none.
    XCTAssertEqual(history.items.first, items[9])
    XCTAssertEqual(items[0].shortcuts.count, 0)
    let shortcutIds = items.map { $0.shortcuts.map(\.id) }

    // Removing the item without a shortcut leaves every other shortcut untouched.
    history.delete(items[0])
    for index in 1...9 {
      XCTAssertEqual(items[index].shortcuts.map(\.id), shortcutIds[index], "item \(index)")
    }

    // Removing the first item shifts every remaining shortcut.
    history.delete(items[9])
    for index in 1...8 {
      XCTAssertNotEqual(items[index].shortcuts.map(\.id), shortcutIds[index], "item \(index)")
      XCTAssertEqual(items[index].shortcuts.first?.key, KeyShortcut.create(character: String(9 - index)).first?.key)
    }
  }

  func testAddingItemThatIsSupersededByExisting() throws {
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

    XCTAssertEqual(history.items, [second])
    XCTAssertEqual(Set(history.items[0].item.contents), Set(firstContents))
    try assertStorageCounts(items: 1, contents: firstContents.count)
  }

  func testAddingItemWithDifferentModifiedType() {
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

    XCTAssertEqual(history.items, [second])
    XCTAssertEqual(Set(history.items[0].item.contents), Set(firstContents))
  }

  func testAddingItemFromMaccy() {
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

    XCTAssertEqual(history.items, [secondDecorator])
    XCTAssertEqual(history.items[0].item.application, "Xcode.app")
    XCTAssertEqual(Set(history.items[0].item.contents), Set(firstContents))
  }

  func testModifiedAfterCopying() {
    history.add(historyItem("foo"))

    let modifiedItem = historyItem("bar")
    modifiedItem.contents.append(HistoryItemContent(
      type: NSPasteboard.PasteboardType.modified.rawValue,
      value: String(Clipboard.shared.changeCount).data(using: .utf8)
    ))
    let modifiedItemDecorator = history.add(modifiedItem)

    XCTAssertEqual(history.items, [modifiedItemDecorator])
    XCTAssertEqual(history.items[0].text, "bar")
  }

  func testClearingUnpinned() throws {
    let pinned = history.add(historyItem("foo"))
    pinned.togglePin()
    history.add(historyItem("bar"))
    let orphan = HistoryItemContent(
      type: NSPasteboard.PasteboardType.string.rawValue,
      value: "orphan".data(using: .utf8)
    )
    Storage.shared.context.insert(orphan)
    try Storage.shared.context.save()

    history.clear()

    XCTAssertEqual(history.items, [pinned])
    try assertStorageCounts(items: 1, contents: 1)
  }

  func testClearingAll() throws {
    history.add(historyItem("foo"))
    let pinned = history.add(historyItem("bar"))
    pinned.togglePin()
    Storage.shared.context.insert(HistoryItemContent(
      type: NSPasteboard.PasteboardType.string.rawValue,
      value: "orphan".data(using: .utf8)
    ))
    try Storage.shared.context.save()

    history.clearAll()

    XCTAssertEqual(history.items, [])
    try assertStorageCounts(items: 0, contents: 0)
  }

  func testMaxSize() throws {
    var items: [HistoryItemDecorator] = []
    for index in 0...10 {
      items.append(history.add(historyItem(String(index))))
    }

    XCTAssertEqual(history.items.count, 10)
    XCTAssertTrue(history.items.contains(items[10]))
    XCTAssertFalse(history.items.contains(items[0]))
    try assertStorageCounts(items: 10, contents: 10)
  }

  func testMaxSizeIgnoresPinned() {
    var items: [HistoryItemDecorator] = []

    let item = history.add(historyItem("0"))
    items.append(item)
    item.togglePin()

    for index in 1...11 {
      items.append(history.add(historyItem(String(index))))
    }

    XCTAssertEqual(history.items.count, 11)
    XCTAssertTrue(history.items.contains(items[10]))
    XCTAssertTrue(history.items.contains(items[0]))
    XCTAssertFalse(history.items.contains(items[1]))
  }

  func testMaxSizeIsChanged() {
    var items: [HistoryItemDecorator] = []
    for index in 0...10 {
      items.append(history.add(historyItem(String(index))))
    }
    Defaults[.size] = 5
    history.add(historyItem("11"))

    XCTAssertEqual(history.items.count, 5)
    XCTAssertTrue(history.items.contains(items[10]))
    XCTAssertFalse(history.items.contains(items[5]))
  }

  func testReaddingBottomMostPinnedItemAtFullCapacity() {
    // Regression test for a crash when re-copying (invoking) the bottom-most
    // pinned item while history is at full capacity and pins are sorted to the
    // bottom. The stale insert index used to trap with an out-of-bounds insert.
    // Issue link: https://github.com/p0deje/Maccy/issues/1466
    // `pinTo` is restored to its default value(.top) in `tearDown`.
    Defaults[.pinTo] = .bottom

    // Pin an item; `history.togglePin` re-sorts `all`, so with `.bottom` the
    // pinned item ends up as the last element.
    let pinned = history.add(historyItem("pinned"))
    history.togglePin(pinned)

    // Fill unpinned history to full capacity.
    for index in 0..<Defaults[.size] {
      history.add(historyItem(String(index)))
    }

    XCTAssertEqual(history.all.last, pinned)

    // Re-copy the pinned item. It is detected as a duplicate, removed and
    // re-inserted while `limitHistorySize` trims an exceeding unpinned item.
    // Before the fix this inserted at a stale, out-of-bounds index and crashed.
    let readded = history.add(historyItem("pinned"))

    XCTAssertTrue(history.all.contains(readded))
    XCTAssertEqual(history.all.filter(\.isPinned).count, 1)
  }

  func testRemoving() throws {
    let foo = history.add(historyItem("foo"))
    let bar = history.add(historyItem("bar"))
    history.delete(foo)
    XCTAssertEqual(history.items, [bar])
    try assertStorageCounts(items: 1, contents: 1)
  }

  func testCleaningUpOrphanedContents() throws {
    let live = history.add(historyItem("live"))
    let liveContent = live.item.contents[0]
    for value in ["orphan-1", "orphan-2"] {
      Storage.shared.context.insert(HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value.data(using: .utf8)
      ))
    }
    try Storage.shared.context.save()

    XCTAssertEqual(try Storage.shared.cleanupOrphanedContents(), 2)
    XCTAssertEqual(try Storage.shared.cleanupOrphanedContents(), 0)
    XCTAssertEqual(live.item.contents, [liveContent])
    try assertStorageCounts(items: 1, contents: 1)
  }

  // Mirrors the launch sequence: the cleanup runs on the main actor, then the
  // history loads what is left.
  func testCleaningUpOrphanedContentsBeforeLoading() async throws {
    let foo = history.add(historyItem("foo"))
    let bar = history.add(historyItem("bar"))
    for value in ["orphan-1", "orphan-2", "orphan-3"] {
      Storage.shared.context.insert(HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value.data(using: .utf8)
      ))
    }
    try Storage.shared.context.save()
    try assertStorageCounts(items: 2, contents: 5, orphaned: 3)

    XCTAssertEqual(try Storage.shared.cleanupOrphanedContents(), 3)
    try await history.load()

    XCTAssertEqual(Set(history.all.map(\.item)), [foo.item, bar.item])
    XCTAssertEqual(history.all.map(\.item.contents.count), [1, 1])
    try assertStorageCounts(items: 2, contents: 2)
  }

  private func assertStorageCounts(
    items: Int,
    contents: Int,
    orphaned: Int = 0,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let context = Storage.shared.context
    context.processPendingChanges()
    try context.save()
    XCTAssertEqual(
      try context.fetchCount(FetchDescriptor<HistoryItem>()),
      items,
      file: file,
      line: line
    )
    XCTAssertEqual(
      try context.fetchCount(FetchDescriptor<HistoryItemContent>()),
      contents,
      file: file,
      line: line
    )
    XCTAssertEqual(
      try context.fetchCount(FetchDescriptor<HistoryItemContent>(
        predicate: #Predicate { $0.item == nil }
      )),
      orphaned,
      file: file,
      line: line
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
