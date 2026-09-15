import AppKit

struct Accessibility {
  private static var allowed: Bool { AXIsProcessTrustedWithOptions(nil) }

  // Pasting posts a synthetic ⌘V, which macOS drops silently unless the app is
  // trusted under Accessibility. Asking here registers this exact bundle in the
  // Accessibility list, so the user is not left toggling a stale entry.
  static func check() {
    guard !allowed else {
      return
    }

    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
  }
}
