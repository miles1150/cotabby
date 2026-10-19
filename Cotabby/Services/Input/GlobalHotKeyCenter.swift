import Carbon.HIToolbox
import Logging

/// File overview:
/// Registers system-wide keyboard shortcuts with Carbon's `RegisterEventHotKey`. Explain &
/// Translate uses it for ⌥E (explain), ⌥S (speak), and Esc (close the panel, registered only while
/// the panel is visible).
///
/// Why Carbon hot keys instead of another `CGEventTap` like `InputMonitor`'s toggle tap:
/// - The system consumes the key for us; the focused app never sees it.
/// - No Input Monitoring or Accessibility permission is involved, and the shortcut keeps working
///   in apps where autocomplete is off (terminals, per-app disabled apps) — which is exactly where
///   the user reads agent output.
/// - No per-keystroke callback runs for unrelated keys.
///
/// Lifetime: one instance per app, owned by `CotabbyAppEnvironment`. Carbon calls back through a C
/// function pointer that cannot capture Swift context, so `self` travels as an unretained raw
/// pointer (`userData`). That is safe because this object outlives every registration: `deinit`
/// never runs while the app is alive.
@MainActor
final class GlobalHotKeyCenter: HotKeyRegistering {
    /// Four-character signature that tags our hot keys ("CTBY"), so the shared event handler can
    /// ignore hot-key events that belong to other code in the process.
    private static let signature: OSType = 0x4354_4259

    private var handlers: [UInt32: () -> Void] = [:]
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    nonisolated deinit {}

    /// Registers `keyCode` + `modifiers`. Returns `nil` when the system refuses, typically because
    /// another app already owns that exact shortcut.
    func register(keyCode: UInt32, modifiers: ShortcutModifierMask, handler: @escaping () -> Void) -> HotKeyToken? {
        installEventHandlerIfNeeded()
        let id = nextID
        nextID += 1

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            CarbonHotKeyModifiers.carbonFlags(for: modifiers),
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            CotabbyLogger.app.warning("RegisterEventHotKey failed keyCode=\(keyCode) status=\(status)")
            return nil
        }
        references[id] = reference
        handlers[id] = handler
        return HotKeyToken(id: id)
    }

    func unregister(_ token: HotKeyToken?) {
        guard let token, let reference = references.removeValue(forKey: token.id) else { return }
        UnregisterEventHotKey(reference)
        handlers.removeValue(forKey: token.id)
    }

    // MARK: - Carbon event plumbing

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // A C function pointer: no captures allowed, so the instance comes back through `userData`.
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == GlobalHotKeyCenter.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let center = Unmanaged<GlobalHotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            // Carbon delivers application events on the main thread, so assuming main-actor
            // isolation here is sound and lets us call the stored handlers directly.
            MainActor.assumeIsolated {
                // Copy the handler out first: the Esc handler unregisters itself, and calling it
                // while still reading from `handlers` would overlap a read and a write.
                let handler = center.handlers[id]
                handler?()
            }
            return noErr
        }
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        if status != noErr {
            CotabbyLogger.app.warning("InstallEventHandler for hot keys failed status=\(status)")
        }
    }
}
