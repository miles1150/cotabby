import Combine
import Foundation
import Logging

/// File overview:
/// Orchestrates Explain & Translate. It is the only object that knows the whole flow:
///
///   shortcut → read selection → classify (word / sentence / paragraph) → show "loading" panel →
///   pick API key → ask DeepSeek → show the answer (or a clear error)
///
/// and, for speaking: shortcut or 🔊 button → read the selection (or the panel's text) aloud.
///
/// Every step is delegated to a narrow collaborator — `GlobalHotKeyCenter` (keys),
/// `SelectedTextReader` (selection), `ExplainModeClassifier` (rules), `ExplainGenerating`
/// (network), `ExplainPanelController` (window), `SpeechService` (voice) — so this type only holds
/// orchestration state: the current request's generation number and the registered shortcuts.
///
/// Concurrency: everything runs on the main actor except the network call, which suspends inside
/// `ExplainGenerating`. "Latest wins": each shortcut press bumps `generation` and cancels the
/// previous task, and every await is followed by a generation check, so a slow old answer can
/// never overwrite a newer one.
@MainActor
final class ExplainCoordinator {
    private let settings: ExplainSettingsModel
    private let hotKeys: HotKeyRegistering
    private let reader: SelectedTextReading
    private let client: ExplainGenerating
    private let panel: ExplainPanelPresenting
    private let speech: SpeechPerforming
    private let environment: () -> [String: String]
    private let endpointAPIKey: () -> String?
    private let endpointBaseURL: () -> String?

    private var explainToken: HotKeyToken?
    private var speakToken: HotKeyToken?
    private var escapeToken: HotKeyToken?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var cancellables = Set<AnyCancellable>()

    /// `kVK_Escape`.
    private static let escapeKeyCode: UInt32 = 53

    init(
        settings: ExplainSettingsModel,
        hotKeys: HotKeyRegistering,
        reader: SelectedTextReading,
        client: ExplainGenerating,
        panel: ExplainPanelPresenting,
        speech: SpeechPerforming,
        environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
        endpointAPIKey: @escaping () -> String?,
        endpointBaseURL: @escaping () -> String?
    ) {
        self.settings = settings
        self.hotKeys = hotKeys
        self.reader = reader
        self.client = client
        self.panel = panel
        self.speech = speech
        self.environment = environment
        self.endpointAPIKey = endpointAPIKey
        self.endpointBaseURL = endpointBaseURL

        panel.onSpeak = { [weak self] in self?.togglePanelSpeech() }
        panel.onClose = { [weak self] in self?.dismiss() }
        panel.onClickOutside = { [weak self] in self?.dismiss() }
    }

    nonisolated deinit {}

    /// Which key source is active right now, for the Settings page. `nil` means no key anywhere.
    var activeKeySource: ExplainAPIKeyResolver.Source? {
        resolveKey()?.source
    }

    func start() {
        // Re-register whenever the feature is switched or a shortcut is re-recorded. `@Published`
        // replays the current value on subscribe, so this also performs the first registration.
        Publishers.CombineLatest3(settings.$isEnabled, settings.$explainShortcut, settings.$speakShortcut)
            .sink { [weak self] enabled, explain, speak in
                self?.registerShortcuts(enabled: enabled, explain: explain, speak: speak)
            }
            .store(in: &cancellables)

        speech.isSpeakingPublisher
            .removeDuplicates()
            .sink { [weak self] isSpeaking in self?.panel.setSpeaking(isSpeaking) }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        task?.cancel()
        hotKeys.unregister(explainToken)
        hotKeys.unregister(speakToken)
        explainToken = nil
        speakToken = nil
        speech.stop()
        dismiss()
    }

    // MARK: - Shortcuts

    private func registerShortcuts(enabled: Bool, explain: ExplainShortcut, speak: ExplainShortcut) {
        hotKeys.unregister(explainToken)
        hotKeys.unregister(speakToken)
        explainToken = nil
        speakToken = nil
        guard enabled else {
            dismiss()
            return
        }
        if explain.isBound {
            explainToken = hotKeys.register(keyCode: UInt32(explain.keyCode), modifiers: explain.modifiers) { [weak self] in
                self?.explainSelection()
            }
        }
        if speak.isBound {
            speakToken = hotKeys.register(keyCode: UInt32(speak.keyCode), modifiers: speak.modifiers) { [weak self] in
                self?.speakSelection()
            }
        }
    }

    // MARK: - Explain

    func explainSelection() {
        task?.cancel()
        generation += 1
        let current = generation
        task = Task { [weak self] in
            await self?.runExplain(generation: current)
        }
    }

    private func runExplain(generation current: Int) async {
        let selection = await reader.read()
        guard current == generation else { return }
        guard let selection, let input = ExplainModeClassifier.classify(selection.text) else {
            present(.failed(.noSelection, input: nil))
            return
        }
        CotabbyLogger.app.info("Explain: \(input.mode.rawValue) selection (\(input.text.count) chars) via \(selection.source.rawValue)")
        // A new run re-anchors at the pointer, even when an older answer is still on screen.
        present(.loading(input), reanchor: true)

        guard let key = resolveKey() else {
            present(.failed(.missingAPIKey, input: input))
            return
        }
        do {
            let started = ContinuousClock.now
            let result = try await client.explain(input, apiKey: key.apiKey, model: settings.modelName, baseURL: settings.baseURL)
            guard current == generation, !Task.isCancelled else { return }
            present(.loaded(input, result))
            // Mode and timing only: the selected text and the answer are never written to logs.
            let elapsed = (ContinuousClock.now - started).components
            let milliseconds = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
            CotabbyLogger.app.info("Explain: answer shown (\(input.mode.rawValue), \(milliseconds) ms)")
        } catch is CancellationError {
            return
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            let failure = error as? ExplainFailure ?? .network(error.localizedDescription)
            CotabbyLogger.app.warning("Explain failed: \(failure.userMessage)")
            present(.failed(failure, input: input))
        }
    }

    /// Opens (or, with `reanchor`, moves) the panel at the pointer; later states of the same run
    /// update it in place so it does not jump while the answer loads.
    private func present(_ state: ExplainPanelState, reanchor: Bool = false) {
        if panel.isVisible, !reanchor {
            panel.update(state)
        } else {
            panel.show(state)
        }
        registerEscape()
    }

    private func dismiss() {
        task?.cancel()
        generation += 1
        hotKeys.unregister(escapeToken)
        escapeToken = nil
        panel.hide()
    }

    /// Esc closes the panel. Registered only while the panel is visible so Esc keeps working
    /// normally everywhere else.
    private func registerEscape() {
        guard escapeToken == nil else { return }
        escapeToken = hotKeys.register(keyCode: Self.escapeKeyCode, modifiers: []) { [weak self] in
            self?.dismiss()
        }
    }

    // MARK: - Speak

    /// Shortcut: stop if already reading; otherwise read the current selection, falling back to the
    /// text in the open panel when nothing is selected.
    func speakSelection() {
        if speech.isSpeaking {
            speech.stop()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let selection = await reader.read()
            let text = selection?.text ?? panelText
            guard let text else { return }
            speak(text)
        }
    }

    private func togglePanelSpeech() {
        if speech.isSpeaking {
            speech.stop()
        } else if let text = panelText {
            speak(text)
        }
    }

    private var panelText: String? {
        // The panel only shows text it explained, so its input is exactly what to read.
        lastPresentedInput?.text
    }

    private var lastPresentedInput: ExplainInput? {
        panel.currentState?.input
    }

    private func speak(_ text: String) {
        speech.speak(text, preferredVoiceIdentifier: settings.voiceIdentifier, rate: settings.speechRate)
    }

    // MARK: - Key

    private func resolveKey() -> ExplainAPIKeyResolver.Resolution? {
        ExplainAPIKeyResolver.resolve(
            environment: environment(),
            explainKey: settings.readSavedAPIKey(),
            endpointKey: endpointAPIKey(),
            endpointBaseURL: endpointBaseURL(),
            explainBaseURL: settings.baseURL
        )
    }
}
