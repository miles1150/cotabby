import Foundation

/// File overview:
/// Decides whether Cotabby should wake ("prime") the web-accessibility tree of an Electron app that
/// is *not* on `BrowserAppDetector`'s hand-made allowlist.
///
/// Background: Electron apps keep their accessibility tree asleep until an assistive client sets
/// `AXManualAccessibility`. Waking it costs the app CPU and memory (it then mirrors its whole page
/// structure), which is why upstream only wakes a named list of editors. A named list, though,
/// needs a code change for every new app (the Claude desktop app was missing until 2026-10-19).
///
/// This rule wakes an unlisted Electron app only when it is clearly needed:
/// - the system reports **no focused accessibility element** in the frontmost app (the dormant-tree
///   symptom; a normal app always has some focused element), and
/// - the user **pressed a key very recently**, so they are trying to type, not just reading.
///
/// Pure by design (no AX calls, no file system), so every branch is unit-tested. The caller
/// (`ChromiumAccessibilityEnabler`) supplies the facts and performs the side effect.
enum ElectronAutoWakePolicy {
    /// "Typing right now" window. Long enough to cover the focus poll (50 ms) and a pause between
    /// words; short enough that switching to Slack just to read never wakes it.
    static let recentTypingWindowSeconds: Double = 3

    /// Defaults key: set to YES to turn automatic waking off everywhere (the named allowlist keeps
    /// working). `defaults write com.jacobfu.tabby.dev cotabbyElectronAutoWakeDisabled -bool YES`
    static let disabledDefaultsKey = "cotabbyElectronAutoWakeDisabled"

    /// Defaults key: bundle ids that must never be woken automatically, for an app that misbehaves.
    /// `defaults write com.jacobfu.tabby.dev cotabbyElectronAutoWakeExcludedBundleIDs -array com.example.app`
    static let excludedBundleIDsDefaultsKey = "cotabbyElectronAutoWakeExcludedBundleIDs"

    struct Facts: Equatable {
        let bundleIdentifier: String?
        /// The app bundle ships `Electron Framework.framework`.
        let isElectron: Bool
        /// Already handled by `BrowserAppDetector.needsWebAccessibilityPriming` (named list or a
        /// Chromium browser), so the regular priming path owns it.
        let isOnNamedAllowlist: Bool
        /// The process was already primed, or rejected `AXManualAccessibility` as unsupported.
        let isAlreadyHandled: Bool
        /// Seconds since the last key-down anywhere in the session.
        let secondsSinceLastKeyDown: Double
        let isAutoWakeDisabled: Bool
        let excludedBundleIdentifiers: Set<String>
    }

    static func shouldWake(_ facts: Facts) -> Bool {
        guard !facts.isAutoWakeDisabled,
              facts.isElectron,
              !facts.isOnNamedAllowlist,
              !facts.isAlreadyHandled,
              let bundleIdentifier = facts.bundleIdentifier?.lowercased(),
              !facts.excludedBundleIdentifiers.contains(where: { $0.lowercased() == bundleIdentifier })
        else {
            return false
        }
        // `secondsSinceLastEventType` returns a huge value when no key was ever pressed; anything
        // negative or non-finite is treated as "not typing".
        return facts.secondsSinceLastKeyDown.isFinite
            && facts.secondsSinceLastKeyDown >= 0
            && facts.secondsSinceLastKeyDown <= recentTypingWindowSeconds
    }
}
