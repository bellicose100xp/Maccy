import AppKit
import Defaults

// swiftlint:disable identifier_name
// swiftlint:disable type_name
class Sorter {
  enum By: String, CaseIterable, Identifiable, CustomStringConvertible, Defaults.Serializable {
    case lastCopiedAt
    case firstCopiedAt
    case numberOfCopies

    var id: Self { self }

    var description: String {
      switch self {
      case .lastCopiedAt:
        return NSLocalizedString("LastCopiedAt", tableName: "StorageSettings", comment: "")
      case .firstCopiedAt:
        return NSLocalizedString("FirstCopiedAt", tableName: "StorageSettings", comment: "")
      case .numberOfCopies:
        return NSLocalizedString("NumberOfCopies", tableName: "StorageSettings", comment: "")
      }
    }
  }

  func sort(_ items: [HistoryItem], by: By = Defaults[.sortBy]) -> [HistoryItem] {
    return sort(items, by: by, item: { $0 }, pin: \.pin)
  }

  // Decorators mirror their item's pin, which spares a SwiftData read per comparison.
  func sort(_ items: [HistoryItemDecorator], by: By = Defaults[.sortBy]) -> [HistoryItemDecorator] {
    return sort(items, by: by, item: \.item, pin: \.pin)
  }

  private func sort<T>(_ items: [T], by: By, item: (T) -> HistoryItem, pin: (T) -> String?) -> [T] {
    let pinTo = Defaults[.pinTo]
    return items
      .sorted(by: { return bySortingAlgorithm(item($0), item($1), by) })
      .sorted(by: { return byPinned(pin($0), pin($1), pinTo) })
  }

  private func bySortingAlgorithm(_ lhs: HistoryItem, _ rhs: HistoryItem, _ by: By) -> Bool {
    switch by {
    case .firstCopiedAt:
      return lhs.firstCopiedAt > rhs.firstCopiedAt
    case .numberOfCopies:
      return lhs.numberOfCopies > rhs.numberOfCopies
    default:
      return lhs.lastCopiedAt > rhs.lastCopiedAt
    }
  }

  private func byPinned(_ lhs: String?, _ rhs: String?, _ pinTo: PinsPosition) -> Bool {
    if pinTo == .bottom {
      return (lhs == nil) && (rhs != nil)
    } else {
      return (lhs != nil) && (rhs == nil)
    }
  }
}
// swiftlint:enable identifier_name
// swiftlint:enable type_name
