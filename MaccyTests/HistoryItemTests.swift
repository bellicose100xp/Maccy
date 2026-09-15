import XCTest
import Defaults
@testable import Maccy

// swiftlint:disable force_try
@MainActor
class HistoryItemTests: XCTestCase {
  func testTitleForString() {
    let title = "foo"
    let item = historyItem(title)
    XCTAssertEqual(item.title, title)
  }

  func testTitleWithWhitespaces() {
    let title = "   foo bar   "
    let item = historyItem(title)
    XCTAssertEqual(item.title, "···foo bar···")
  }

  func testTitleWithNewlines() {
    let title = "\nfoo\nbar\n"
    let item = historyItem(title)
    XCTAssertEqual(item.title, "⏎foo⏎bar⏎")
  }

  func testTitleWithTabs() {
    let title = "\tfoo\tbar\t"
    let item = historyItem(title)
    XCTAssertEqual(item.title, "⇥foo⇥bar⇥")
  }

  // U+FFFC arrives from rich text with inline attachments and hangs CoreText
  // on macOS 26. See https://github.com/p0deje/Maccy/issues/1520.
  func testTitleWithObjectReplacementCharacters() {
    let item = historyItem("\u{FFFC}foo\u{FFFC}bar\u{FFFC}")
    XCTAssertEqual(item.title, "foobar")
  }

  func testTitleWithOnlyObjectReplacementCharacters() {
    let item = historyItem("\u{FFFC}\u{FFFC}")
    XCTAssertEqual(item.title, "")
  }

  func testTitleWithRTF() {
    let rtf = NSAttributedString(string: "foo").rtf(
      from: NSRange(0...2),
      documentAttributes: [:]
    )
    let item = historyItem(rtf, .rtf)
    XCTAssertEqual(item.title, "foo")
  }

  func testTitleWithHTML() {
    let html = "<a href='#'>foo</a>".data(using: .utf8)
    let item = historyItem(html, .html)
    XCTAssertEqual(item.title, "foo")
  }

  func testImage() {
    let image = NSImage(named: "NSBluetoothTemplate")!
    let item = historyItem(image)
    XCTAssertEqual(item.title, "")
  }

  func testFile() {
    let url = URL(fileURLWithPath: "/tmp/foo.bar")
    let item = historyItem(url)
    XCTAssertEqual(item.title, "file:///tmp/foo.bar")
  }

  func testFileWithEscapedChars() {
    let url = URL(fileURLWithPath: "/tmp/产品培训/产品培训.txt")
    let item = historyItem(url)
    XCTAssertEqual(item.title, "file:///tmp/产品培训/产品培训.txt")
  }

  func testTextFromUniversalClipboard() {
    let url = URL(fileURLWithPath: "/tmp/foo.bar")
    let fileURLContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.fileURL.rawValue,
      value: url.dataRepresentation
    )
    let textContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.string.rawValue,
      value: url.lastPathComponent.data(using: .utf8)
    )
    let universalClipboardContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
      value: "".data(using: .utf8)
    )
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = [fileURLContent, textContent, universalClipboardContent]
    item.title = item.generateTitle()
    XCTAssertEqual(item.title, "foo.bar")
  }

  func testImageFromUniversalClipboard() {
    let url = Bundle(for: type(of: self)).url(forResource: "guy", withExtension: "jpeg")!
    let fileURLContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.fileURL.rawValue,
      value: url.dataRepresentation
    )
    let universalClipboardContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
      value: "".data(using: .utf8)
    )
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = [fileURLContent, universalClipboardContent]
    XCTAssertEqual(item.image!.tiffRepresentation, NSImage(data: try! Data(contentsOf: url))!.tiffRepresentation)
  }

  func testFileFromUniversalClipboard() {
    let url = URL(fileURLWithPath: "/tmp/foo.bar")
    let fileURLContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.fileURL.rawValue,
      value: url.dataRepresentation
    )
    let universalClipboardContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
      value: "".data(using: .utf8)
    )
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = [fileURLContent, universalClipboardContent]
    item.title = item.generateTitle()
    XCTAssertEqual(item.title, "file:///tmp/foo.bar")
  }

  func testItemWithoutData() {
    let item = historyItem(nil)
    XCTAssertEqual(item.title, "")
  }

  // The fingerprint subset check is a precondition of `supersedes`: whenever
  // `supersedes` is true the fingerprints must agree, and for distinct data
  // they must disagree so the full comparison can be skipped.
  func testContentFingerprintsAgreeWithSupersedes() {
    let string = NSPasteboard.PasteboardType.string.rawValue
    let rtf = NSPasteboard.PasteboardType.rtf.rawValue
    let modified = NSPasteboard.PasteboardType.modified.rawValue

    let full = historyItem([(string, "one"), (rtf, "two")])
    let textOnly = historyItem([(string, "one")])
    let otherText = historyItem([(string, "two")])
    let sameTypeOtherValue = historyItem([(string, "one"), (rtf, "three")])
    let withTransient = historyItem([(string, "one"), (modified, "1")])
    let otherTransient = historyItem([(string, "one"), (modified, "2")])
    let empty = historyItem([])

    let pairs = [
      (full, textOnly), (textOnly, full), (full, otherText), (otherText, full),
      (full, sameTypeOtherValue), (sameTypeOtherValue, full),
      (withTransient, otherTransient), (otherTransient, withTransient),
      (textOnly, withTransient), (withTransient, textOnly),
      (full, empty), (empty, full), (full, full)
    ]
    for (lhs, rhs) in pairs {
      let supersedes = lhs.supersedes(rhs)
      let fingerprintsMatch = rhs.nonTransientContentFingerprints.isSubset(of: lhs.contentFingerprints)
      XCTAssertEqual(supersedes, fingerprintsMatch, "\(lhs.contents.map(\.type)) vs \(rhs.contents.map(\.type))")
    }

    XCTAssertTrue(full.supersedes(textOnly))
    XCTAssertFalse(textOnly.supersedes(full))
    XCTAssertTrue(withTransient.supersedes(otherTransient))
    XCTAssertTrue(full.supersedes(empty))
    XCTAssertFalse(empty.supersedes(full))
  }

  func testContentFingerprintsFollowContentChanges() {
    let item = historyItem("foo")
    let before = item.contentFingerprints
    item.contents[0].value = "bar".data(using: .utf8)
    XCTAssertNotEqual(item.contentFingerprints, before)
    XCTAssertEqual(item.contentFingerprints, historyItem("bar").contentFingerprints)
  }

  func testSeveralItemsCanHaveEmptyPin() {
    let item1 = historyItem("foo")
    item1.pin = ""
    let item2 = historyItem("bar")
    item2.pin = ""
    XCTAssertNoThrow(try Storage.shared.context.save())
    XCTAssertEqual(item1.pin, "")
    XCTAssertEqual(item2.pin, "")
  }

  private func historyItem(_ value: String?) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value?.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.title = item.generateTitle()

    return item
  }

  private func historyItem(_ contents: [(type: String, value: String)]) -> HistoryItem {
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents.map { HistoryItemContent(type: $0.type, value: $0.value.data(using: .utf8)) }
    item.title = item.generateTitle()

    return item
  }

  private func historyItem(_ data: Data?, _ type: NSPasteboard.PasteboardType) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: type.rawValue,
        value: data
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.title = item.generateTitle()

    return item
  }

  private func historyItem(_ value: NSImage) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.tiff.rawValue,
        value: value.tiffRepresentation!
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.title = item.generateTitle()

    return item
  }

  private func historyItem(_ value: URL) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: value.dataRepresentation
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value.lastPathComponent.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.title = item.generateTitle()

    return item
  }
}
// swiftlint:enable force_try
