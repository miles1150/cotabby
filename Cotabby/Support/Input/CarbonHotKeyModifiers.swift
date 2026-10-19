import Carbon.HIToolbox

/// File overview:
/// Translates Cotabby's `ShortcutModifierMask` into the Carbon modifier bits that
/// `RegisterEventHotKey` expects. Carbon is an old C API, but its hot-key registration is still
/// the standard way for a macOS app to own a global shortcut: the system delivers the key to us,
/// consumes it so the focused app never sees it, and needs no Input Monitoring or Accessibility
/// permission (unlike a `CGEventTap`). Kept as a pure function so the bit mapping is unit-tested.
/// Main-actor isolated (the module default) because `ShortcutModifierMask`'s option-set
/// conformance is; every caller is UI or hot-key code on the main actor anyway.
enum CarbonHotKeyModifiers {
    static func carbonFlags(for mask: ShortcutModifierMask) -> UInt32 {
        var flags: UInt32 = 0
        if mask.contains(.command) { flags |= UInt32(cmdKey) }
        if mask.contains(.shift) { flags |= UInt32(shiftKey) }
        if mask.contains(.option) { flags |= UInt32(optionKey) }
        if mask.contains(.control) { flags |= UInt32(controlKey) }
        return flags
    }

    /// Human-readable symbols in the macOS menu order (⌃⌥⇧⌘), used for default shortcut labels.
    static func symbols(for mask: ShortcutModifierMask) -> String {
        var symbols = ""
        if mask.contains(.control) { symbols += "⌃" }
        if mask.contains(.option) { symbols += "⌥" }
        if mask.contains(.shift) { symbols += "⇧" }
        if mask.contains(.command) { symbols += "⌘" }
        return symbols
    }
}
