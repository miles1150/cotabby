import AppKit
import ApplicationServices
import Logging

/// File overview:
/// Reads the text the user has selected in whatever app is in front. Two strategies, tried in order:
///
/// 1. **Accessibility** (`kAXSelectedTextAttribute` on the focused element). Instant and invisible,
///    and it works in native text views, Terminal, and many editors.
/// 2. **Copy, then restore the clipboard.** Read-only web content and Electron chat transcripts
///    (for example the Claude desktop app) often do not expose their selection through
///    Accessibility. For those we save the clipboard, ask the app to copy, read the copied text,
///    and put the user's clipboard back. The copy is triggered by pressing the app's own
///    Edit > Copy menu item through Accessibility; only if the app has no such item do we post a
///    synthetic Cmd-C, after waiting for the user to release the hotkey's modifier keys (otherwise
///    the held Option key would merge into it and the app would see Option-Cmd-C).
///
/// Safety rules this type protects:
/// - Password fields are never read, by either strategy.
/// - If the copy does not visibly change the clipboard, there was no selection: we return `nil`
///   instead of whatever was already on the clipboard (which could be anything, even a password).
/// - A clipboard holding concealed data (password managers mark it `org.nspasteboard.ConcealedType`)
///   is never borrowed: restoring it would defeat the manager's timed auto-clear.
/// - Reads never overlap. Two overlapping copy-and-restore cycles could capture each other's
///   temporary clipboard and leave the selection on the user's clipboard, so each read waits for
///   the previous one. The read runs in its own task that the caller's cancellation cannot cut
///   short, so a cancelled read still restores the clipboard.
/// - An app that writes the copy after we stopped waiting still gets its write undone.
@MainActor
final class SelectedTextReader: SelectedTextReading {
    private typealias Source = SelectedText.Source

    /// How long to wait for the app to put the copied text on the pasteboard.
    private static let copyTimeout: Duration = .milliseconds(900)
    /// After the change count moves, how long to wait for the string data itself (an app's copy is
    /// "clear, then write" from another process, so the two steps can be observed separately).
    private static let dataTimeout: Duration = .milliseconds(300)
    /// After a timeout, how long to keep watching for a late copy that must be undone.
    private static let lateCopyGrace: Duration = .seconds(2)
    private static let pollInterval: Duration = .milliseconds(20)
    /// How long to wait for the user to release the hotkey's modifiers before a synthetic Cmd-C.
    private static let modifierReleaseTimeout: Duration = .milliseconds(500)
    /// Accessibility timeout for the selected-text read. Longer than the focus poll's 50 ms because
    /// this runs once per shortcut press, and a busy Electron app can need a little more time.
    private static let selectionReadTimeout: Float = 0.3
    /// `kVK_ANSI_C`.
    private static let cKeyCode: CGKeyCode = 8
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private let suppressionController: InputSuppressionController
    /// The read currently running, so the next one can wait for it.
    private var inFlight: Task<SelectedText?, Never>?
    private var inFlightID = 0

    init(suppressionController: InputSuppressionController) {
        self.suppressionController = suppressionController
    }

    nonisolated deinit {}

    func read() async -> SelectedText? {
        // Main-actor reentrancy: another caller may start a read while we wait, so re-check.
        while let previous = inFlight {
            _ = await previous.value
        }
        inFlightID += 1
        let id = inFlightID
        // Unstructured on purpose: cancelling the caller must not interrupt a copy-and-restore.
        let task = Task { await self.performRead() }
        inFlight = task
        let result = await task.value
        if inFlightID == id {
            inFlight = nil
        }
        return result
    }

    private func performRead() async -> SelectedText? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        let pid = application.processIdentifier

        let focused = AXHelper.focusedElement(forApplicationPID: pid) ?? AXHelper.focusedElement()
        if let focused {
            // Bound every AX call on this element so a hung app cannot freeze Cotabby's main thread.
            AXUIElementSetMessagingTimeout(focused, Self.selectionReadTimeout)
            if Self.isSecureField(focused) {
                CotabbyLogger.app.info("Explain: focused element is a secure field, not reading selection")
                return nil
            }
            if let text = Self.nonEmpty(AXHelper.stringValue(for: kAXSelectedTextAttribute as CFString, on: focused)) {
                return SelectedText(text: text, source: .accessibility)
            }
        }
        return await readByCopying(pid: pid)
    }

    // MARK: - Copy fallback

    private func readByCopying(pid: pid_t) async -> SelectedText? {
        let pasteboard = NSPasteboard.general
        if pasteboard.types?.contains(Self.concealedType) == true {
            CotabbyLogger.app.info("Explain: clipboard holds concealed data, skipping the copy fallback")
            return nil
        }
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        let changeCountBefore = pasteboard.changeCount

        let source: Source
        if let copyItem = AXHelper.copyMenuItem(forApplicationPID: pid),
           AXUIElementPerformAction(copyItem, kAXPressAction as CFString) == .success {
            source = .copyMenu
        } else {
            await waitForModifierRelease()
            guard postSyntheticCopy() else { return nil }
            source = .copyKeystroke
        }

        guard await waitUntil(Self.copyTimeout, { pasteboard.changeCount != changeCountBefore }) else {
            // Nothing was copied yet, so the clipboard still holds the user's own content. If the
            // app copies late, undo that write so the user's clipboard is not replaced.
            CotabbyLogger.app.info("Explain: copy did not change the clipboard (no selection) via \(source.rawValue)")
            undoLateCopy(of: snapshot, changeCountBefore: changeCountBefore, on: pasteboard)
            return nil
        }
        _ = await waitUntil(Self.dataTimeout, { pasteboard.string(forType: .string) != nil })
        let copied = pasteboard.string(forType: .string)
        snapshot.restore(to: pasteboard)
        guard let text = Self.nonEmpty(copied) else { return nil }
        return SelectedText(text: text, source: source)
    }

    /// Keeps watching for a copy that lands after we gave up, and restores the user's clipboard if
    /// one does. It runs beside the next read rather than blocking it, so it restores only when
    /// exactly one write happened since our snapshot: more writes mean the user, another app, or a
    /// newer read changed the clipboard on purpose, and that content must be kept.
    private func undoLateCopy(of snapshot: PasteboardSnapshot, changeCountBefore: Int, on pasteboard: NSPasteboard) {
        Task { @MainActor in
            let changed = await self.waitUntil(Self.lateCopyGrace, { pasteboard.changeCount != changeCountBefore })
            if changed, pasteboard.changeCount == changeCountBefore + 1 {
                snapshot.restore(to: pasteboard)
                CotabbyLogger.app.info("Explain: undid a late copy to keep the user's clipboard")
            }
        }
    }

    /// Polls `condition` until it is true or `timeout` passes. Sleeps are not cut short by
    /// cancellation because reads run in their own uncancelled task.
    private func waitUntil(_ timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return condition()
    }

    private func waitForModifierRelease() async {
        let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
        _ = await waitUntil(Self.modifierReleaseTimeout) {
            CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: modifierMask)
        }
    }

    /// Posts Cmd-C at the annotated session tap with an explicit Command flag, the same path
    /// `SuggestionInserter` uses for its Cmd-V fallback, and marks it synthetic so Cotabby's own
    /// event taps ignore it.
    private func postSyntheticCopy() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.cKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Self.cKeyCode, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        suppressionController.markSynthetic(keyDown)
        suppressionController.markSynthetic(keyUp)
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    // MARK: - Helpers

    private static func isSecureField(_ element: AXUIElement) -> Bool {
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element)
        let subrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element)
        return role == "AXSecureTextField" || subrole == (kAXSecureTextFieldSubrole as String)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
