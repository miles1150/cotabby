import Combine
import Foundation

/// File overview:
/// Narrow protocols `ExplainCoordinator` depends on instead of concrete services. Same idea as
/// `SuggestionSubsystemContracts.swift`: the coordinator only needs a few behaviors from each
/// collaborator, and naming exactly those lets unit tests drive the whole explain flow with fakes
/// (no real hot keys, Accessibility, windows, speech, or network).

/// Registers and removes global shortcuts. Implemented by `GlobalHotKeyCenter`.
@MainActor
protocol HotKeyRegistering: AnyObject {
    func register(keyCode: UInt32, modifiers: ShortcutModifierMask, handler: @escaping () -> Void) -> HotKeyToken?
    func unregister(_ token: HotKeyToken?)
}

/// Opaque handle for one registered shortcut.
nonisolated struct HotKeyToken: Hashable, Sendable {
    let id: UInt32
}

/// Text the user selected and how it was obtained.
nonisolated struct SelectedText: Equatable, Sendable {
    enum Source: String, Sendable {
        case accessibility
        case copyMenu
        case copyKeystroke
    }

    let text: String
    let source: Source
}

/// Reads the current selection in the frontmost app. Implemented by `SelectedTextReader`.
@MainActor
protocol SelectedTextReading: AnyObject {
    func read() async -> SelectedText?
}

/// Shows the floating answer panel. Implemented by `ExplainPanelController`.
@MainActor
protocol ExplainPanelPresenting: AnyObject {
    var onSpeak: (() -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    var onClickOutside: (() -> Void)? { get set }
    var isVisible: Bool { get }
    var currentState: ExplainPanelState? { get }
    func show(_ state: ExplainPanelState)
    func update(_ state: ExplainPanelState)
    func setSpeaking(_ isSpeaking: Bool)
    func hide()
}

/// Reads text aloud. Implemented by `SpeechService`.
@MainActor
protocol SpeechPerforming: AnyObject {
    var isSpeaking: Bool { get }
    var isSpeakingPublisher: AnyPublisher<Bool, Never> { get }
    func speak(_ text: String, preferredVoiceIdentifier: String?, rate: Double)
    func stop()
}
