import AppKit
import SwiftUI

/// File overview:
/// Owns the floating window that shows Explain & Translate results. It follows the same recipe as
/// `EmojiPickerPanelController`: a borderless, non-activating `NSPanel` above normal windows that
/// joins every Space and full-screen app, never becomes key (so the app the user is reading keeps
/// keyboard focus), but still receives mouse clicks for its buttons.
///
/// The controller is a thin AppKit shell. It decides *where* the panel goes (via the pure
/// `ExplainPanelLayout`) and *when* it is on screen; `ExplainCoordinator` decides *what* it shows.
@MainActor
final class ExplainPanelController: ExplainPanelPresenting {
    var onSpeak: (() -> Void)?
    var onClose: (() -> Void)?
    /// Fired for a click anywhere outside the panel.
    var onClickOutside: (() -> Void)?

    private(set) var isVisible = false

    /// The state on screen, read by the coordinator to know what the 🔊 button should read.
    var currentState: ExplainPanelState? { model.state }

    private let model = ExplainPanelViewModel()
    /// Where the panel hangs from, in AppKit screen coordinates. Kept while visible so a state
    /// change (loading → loaded) resizes the panel in place instead of jumping to the mouse.
    private var anchor: CGPoint = .zero
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    private lazy var panel: ExplainPanel = {
        let panel = ExplainPanel(
            contentRect: CGRect(x: 0, y: 0, width: ExplainPanelView.width, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        return panel
    }()

    private lazy var hostingView: NSHostingView<ExplainPanelView> = {
        NSHostingView(rootView: ExplainPanelView(
            model: model,
            onSpeak: { [weak self] in self?.onSpeak?() },
            onClose: { [weak self] in self?.onClose?() }
        ))
    }()

    nonisolated deinit {}

    /// Shows the panel at the mouse pointer (the end of the text the user just selected). Called
    /// again while visible, it moves the panel to the pointer's new position.
    func show(_ state: ExplainPanelState) {
        anchor = NSEvent.mouseLocation
        model.state = state
        layoutAndOrderFront()
        if !isVisible {
            isVisible = true
            installClickMonitors()
        }
    }

    /// Replaces the content of a visible panel, keeping its anchor.
    func update(_ state: ExplainPanelState) {
        guard isVisible else { return }
        model.state = state
        layoutAndOrderFront()
    }

    func setSpeaking(_ isSpeaking: Bool) {
        model.isSpeaking = isSpeaking
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        removeClickMonitors()
        panel.orderOut(nil)
        model.state = nil
    }

    // MARK: - Layout

    private func layoutAndOrderFront() {
        if panel.contentView !== hostingView {
            panel.contentView = hostingView
        }
        // Let SwiftUI measure the new content at the fixed width, then place the panel.
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let size = CGSize(width: ExplainPanelView.width, height: max(fitting.height, 60))
        let frame = ExplainPanelLayout.frame(anchor: anchor, size: size, visibleFrame: visibleFrame(for: anchor))
        panel.setFrame(frame.integral, display: true)
        panel.orderFrontRegardless()
        remeasureOnNextTurn(expectedHeight: size.height)
    }

    /// SwiftUI can finish laying out a new state one run-loop turn after `fittingSize` was read,
    /// which would leave a loaded answer clipped to the loading state's height. Measure once more
    /// on the next turn and resize only if the height really changed.
    private func remeasureOnNextTurn(expectedHeight: CGFloat) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            let height = max(self.hostingView.fittingSize.height, 60)
            guard abs(height - expectedHeight) > 0.5 else { return }
            let size = CGSize(width: ExplainPanelView.width, height: height)
            let frame = ExplainPanelLayout.frame(anchor: self.anchor, size: size, visibleFrame: self.visibleFrame(for: self.anchor))
            self.panel.setFrame(frame.integral, display: true)
        }
    }

    private func visibleFrame(for point: CGPoint) -> CGRect {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
    }

    // MARK: - Click-away dismissal

    private func installClickMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // A click in another application is, by definition, outside the panel.
            self?.onClickOutside?()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window !== self.panel {
                self.onClickOutside?()
            }
            return event
        }
    }

    private func removeClickMonitors() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }
}

/// Non-activating panel: clicking its buttons must never pull keyboard focus away from the app
/// the user is reading.
private final class ExplainPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
