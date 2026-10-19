import AppKit
import ApplicationServices
import Foundation
import Logging

/// Wakes the dormant web-accessibility tree of Chromium-family browsers and allowlisted Electron
/// editors so their web text becomes readable.
///
/// Chromium and Electron build their web accessibility tree lazily: it stays asleep until an
/// assistive-technology client signals interest by setting `AXManualAccessibility` on the
/// application. Without this, a Chrome renderer reports itself AX-unaware and the system-wide
/// focus query keeps returning the omnibox (or nil) no matter where the user clicks in the page.
///
/// Priming is set on the **browser process** element, never on renderer subprocesses (which have
/// no OS-level AX element); the browser owns the composed tree and fans the request out to
/// renderers over IPC. New tabs/renderers spawned after Cotabby launches are covered because the
/// browser rebuilds the tree on demand once primed.
///
/// `@MainActor` because all AX calls must run on the main thread, matching `FocusTracker`.
@MainActor
final class ChromiumAccessibilityEnabler {
    /// Browser PIDs already primed successfully. Throttles priming to once per process so the
    /// per-tick call is a cheap set lookup.
    private var primedPIDs: Set<pid_t> = []

    /// Browser PIDs that rejected `AXManualAccessibility` as unsupported (some Electron builds do
    /// not advertise it). Recorded so we stop retrying a doomed call every tick.
    private var unsupportedPIDs: Set<pid_t> = []

    /// Recognizes Electron apps that are not on the named allowlist (see `primeAfterFocusFailure`).
    private let electronDetector: ElectronBundleDetector
    private let defaults: UserDefaults
    /// Reads seconds since the last key-down anywhere in the session. Injectable for tests; the
    /// default asks the window server, which needs no extra permission.
    private let secondsSinceLastKeyDown: () -> Double

    init(
        // Optional rather than a default value: default arguments are evaluated outside the main
        // actor, so the main-actor detector is created inside the (main-actor) initializer instead.
        electronDetector: ElectronBundleDetector? = nil,
        defaults: UserDefaults = .standard,
        secondsSinceLastKeyDown: @escaping () -> Double = {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        }
    ) {
        self.electronDetector = electronDetector ?? ElectronBundleDetector()
        self.defaults = defaults
        self.secondsSinceLastKeyDown = secondsSinceLastKeyDown
    }

    // Xcode 26.0–26.3 can miscompile the implicit isolated deinitializer of a main-actor class that
    // stores closures, freeing memory twice ("pointer being freed was not allocated"). An explicit
    // nonisolated deinit avoids it, the same workaround `SuggestionSettingsModel` uses.
    nonisolated deinit {}

    /// The frontmost PID seen on the previous poll tick, used to detect activation edges. Updated on
    /// every call (including for apps we never prime) so a switch away and back is always an edge.
    private var lastFrontmostPID: pid_t?

    /// Primes the application if it is a Chromium/Electron surface we cover and has not been primed
    /// (or marked unsupported) yet. Safe to call every poll tick.
    ///
    /// Electron editors are additionally re-primed on every activation edge (each time the app
    /// becomes frontmost), not just once per PID. Observed on VS Code: the first
    /// `AXManualAccessibility` write returns success while the app is long-running, yet the web-AX
    /// tree stays dormant for minutes; a later re-assert wakes it promptly. One extra AX write per
    /// app switch is negligible, and Chromium browsers keep the once-per-PID behavior that already
    /// works for them.
    func primeIfNeeded(application: NSRunningApplication) {
        let pid = application.processIdentifier
        let isActivationEdge = pid != lastFrontmostPID
        lastFrontmostPID = pid

        guard BrowserAppDetector.needsWebAccessibilityPriming(
            bundleIdentifier: application.bundleIdentifier)
        else {
            return
        }

        guard pid > 0, !unsupportedPIDs.contains(pid) else {
            return
        }

        let reassertForElectronEditor = isActivationEdge
            && BrowserAppDetector.isElectronEditor(bundleIdentifier: application.bundleIdentifier)
        guard !primedPIDs.contains(pid) || reassertForElectronEditor else {
            return
        }

        switch AXHelper.setManualAccessibility(true, forApplicationPID: pid) {
        case .success:
            primedPIDs.insert(pid)
            CotabbyLogger.focus.debug(
                "CHROME-PRIME enabled web accessibility for \(application.localizedName ?? "?")")
        case .attributeUnsupported:
            // `AXManualAccessibility` is an Electron addition; Chrome itself rejects it. Chrome's
            // full accessibility mode (the one that computes inline text boxes, so character bounds
            // and font attributes exist) is switched on by the VoiceOver signal instead. Without it
            // Chrome answers caret markers but never character bounds or fonts, and the ghost can
            // only guess the host's typeface. Measured 2026-09: all four test fields returned empty
            // bounds and an empty font dictionary until this flag was set.
            if BrowserAppDetector.isChromiumBrowser(bundleIdentifier: application.bundleIdentifier),
               !Self.isEnhancedUserInterfaceDisabled {
                if AXHelper.setEnhancedUserInterface(true, forApplicationPID: pid) {
                    primedPIDs.insert(pid)
                    CotabbyLogger.focus.debug(
                        "CHROME-PRIME enabled enhanced accessibility for \(application.localizedName ?? "?")")
                    return
                }
            }
            // Codex embeds Chromium in a native shell that rejects AXManualAccessibility.
            // Its native AXEnhancedUserInterface switch exposes the composed web tree instead.
            // Keep this fallback specific to Codex: changing it globally can affect window managers.
            if application.bundleIdentifier?.lowercased() == "com.openai.codex" {
                let root = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(root, 0.05)
                _ = AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                // This shell can report notImplemented even after applying the value; read back
                // the state rather than treating that return code as proof that priming failed.
                if AXHelper.boolValue(for: "AXEnhancedUserInterface" as CFString, on: root) == true {
                    primedPIDs.insert(pid)
                    return
                }
            }
            // Electron build that does not expose AXManualAccessibility; stop retrying.
            unsupportedPIDs.insert(pid)
        default:
            // Transient (app still launching, busy): leave it unmarked so the next tick retries.
            break
        }
    }

    /// Automatic wake for Electron apps that are not on the named allowlist. Called by the focus
    /// poll only when the frontmost app reported **no focused accessibility element** — the dormant
    /// web-tree symptom. `ElectronAutoWakePolicy` additionally requires that the user pressed a key
    /// in the last few seconds, so an Electron app the user is only reading is never woken.
    ///
    /// Shares `primedPIDs` / `unsupportedPIDs` with `primeIfNeeded`, so each process is woken at
    /// most once and an app that rejects the attribute is never asked again.
    /// Returns true when it woke the app (the next poll tick should then find the focused field).
    @discardableResult
    func primeAfterFocusFailure(application: NSRunningApplication) -> Bool {
        let pid = application.processIdentifier
        guard pid > 0 else { return false }
        let facts = ElectronAutoWakePolicy.Facts(
            bundleIdentifier: application.bundleIdentifier,
            isElectron: electronDetector.isElectron(bundleURL: application.bundleURL),
            isOnNamedAllowlist: BrowserAppDetector.needsWebAccessibilityPriming(
                bundleIdentifier: application.bundleIdentifier),
            isAlreadyHandled: primedPIDs.contains(pid) || unsupportedPIDs.contains(pid),
            secondsSinceLastKeyDown: secondsSinceLastKeyDown(),
            isAutoWakeDisabled: defaults.bool(forKey: ElectronAutoWakePolicy.disabledDefaultsKey),
            excludedBundleIdentifiers: Set(
                defaults.stringArray(forKey: ElectronAutoWakePolicy.excludedBundleIDsDefaultsKey) ?? [])
        )
        guard ElectronAutoWakePolicy.shouldWake(facts) else { return false }

        switch AXHelper.setManualAccessibility(true, forApplicationPID: pid) {
        case .success:
            primedPIDs.insert(pid)
            let name = application.localizedName ?? "?"
            let bundle = application.bundleIdentifier ?? "?"
            CotabbyLogger.focus.info("ELECTRON-AUTOWAKE enabled web accessibility for \(name) (\(bundle))")
            return true
        case .attributeUnsupported:
            unsupportedPIDs.insert(pid)
            CotabbyLogger.focus.info(
                "ELECTRON-AUTOWAKE unsupported by \(application.localizedName ?? "?"); not retrying")
            return false
        default:
            // Transient (app busy or launching): the next failed tick retries.
            return false
        }
    }

    /// Kill switch for the Chromium enhanced-accessibility fallback. Some window managers misplace
    /// windows of apps that have `AXEnhancedUserInterface` set; a user who hits that can turn the
    /// fallback off and keep the caret-marker geometry (with font matching by size only).
    static let enhancedUserInterfaceDisabledDefaultsKey = "cotabbyChromiumEnhancedAccessibilityDisabled"

    private static var isEnhancedUserInterfaceDisabled: Bool {
        UserDefaults.standard.bool(forKey: enhancedUserInterfaceDisabledDefaultsKey)
    }
}
