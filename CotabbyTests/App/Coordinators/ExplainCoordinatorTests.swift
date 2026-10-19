import Combine
import XCTest
@testable import Cotabby

/// Drives the whole Explain & Translate flow with fakes: shortcut registration, selection →
/// loading → answer, every failure path, Esc handling, latest-wins, and read-aloud.
@MainActor
final class ExplainCoordinatorTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var settings: ExplainSettingsModel!
    private var hotKeys: FakeHotKeys!
    private var reader: FakeReader!
    private var client: FakeClient!
    private var panel: FakePanel!
    private var speech: FakeSpeech!
    private var environment: [String: String] = [:]
    private var coordinator: ExplainCoordinator!

    private let sampleResult = ExplainResult(
        explanation: "a small difference", chinese: "细微差别", ipa: nil, partOfSpeech: nil, example: nil, hardWords: []
    )

    override func setUp() {
        super.setUp()
        suiteName = "ExplainCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = ExplainSettingsModel(defaults: defaults, credentialStore: InMemoryOpenAICompatibleCredentialStore())
        hotKeys = FakeHotKeys()
        reader = FakeReader()
        client = FakeClient()
        panel = FakePanel()
        speech = FakeSpeech()
        environment = ["DEEPSEEK_API_KEY": "sk-env"]
        coordinator = ExplainCoordinator(
            settings: settings, hotKeys: hotKeys, reader: reader, client: client, panel: panel, speech: speech,
            environment: { [unowned self] in self.environment },
            endpointAPIKey: { nil }, endpointBaseURL: { nil }
        )
        coordinator.start()
    }

    override func tearDown() {
        coordinator.stop()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Lets queued tasks (the explain task on the main actor, the nonisolated fake client) run to
    /// completion. A short real sleep is more robust than counting `Task.yield()`s, because the
    /// client hops off the main actor and back.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(60))
    }

    // MARK: - Shortcut registration

    func test_startRegistersBothDefaultShortcuts() {
        XCTAssertEqual(hotKeys.registeredKeys, [14, 1])
    }

    func test_disablingUnregistersShortcuts() {
        settings.setEnabled(false)
        XCTAssertTrue(hotKeys.registeredKeys.isEmpty)
        settings.setEnabled(true)
        XCTAssertEqual(hotKeys.registeredKeys, [14, 1])
    }

    func test_unboundShortcutIsNotRegistered() {
        settings.setSpeakShortcut(.unbound)
        XCTAssertEqual(hotKeys.registeredKeys, [14])
    }

    // MARK: - Explain flow

    func test_explain_showsLoadingThenResult() async {
        reader.selection = SelectedText(text: "nuance", source: .accessibility)
        client.result = .success(sampleResult)

        hotKeys.press(14)
        await settle()

        let input = ExplainInput(text: "nuance", mode: .word, wasTruncated: false)
        XCTAssertEqual(panel.history, [.loading(input), .loaded(input, sampleResult)])
        XCTAssertEqual(client.calls.first?.apiKey, "sk-env")
        XCTAssertEqual(client.calls.first?.model, "deepseek-flash")
        XCTAssertTrue(hotKeys.registeredKeys.contains(53), "Esc is registered while the panel is open")
    }

    func test_explain_noSelectionShowsFailure() async {
        reader.selection = nil
        hotKeys.press(14)
        await settle()
        XCTAssertEqual(panel.history, [.failed(.noSelection, input: nil)])
        XCTAssertTrue(client.calls.isEmpty)
    }

    func test_explain_missingKeyShowsFailureWithoutNetwork() async {
        environment = [:]
        reader.selection = SelectedText(text: "nuance", source: .accessibility)
        hotKeys.press(14)
        await settle()
        XCTAssertEqual(panel.history.last, .failed(.missingAPIKey, input: ExplainInput(text: "nuance", mode: .word, wasTruncated: false)))
        XCTAssertTrue(client.calls.isEmpty)
    }

    func test_explain_clientFailureIsShown() async {
        reader.selection = SelectedText(text: "nuance", source: .copyMenu)
        client.result = .failure(ExplainFailure.unauthorized)
        hotKeys.press(14)
        await settle()
        XCTAssertEqual(panel.history.last, .failed(.unauthorized, input: ExplainInput(text: "nuance", mode: .word, wasTruncated: false)))
    }

    func test_explain_unknownErrorBecomesNetworkFailure() async {
        reader.selection = SelectedText(text: "nuance", source: .accessibility)
        client.result = .failure(URLError(.notConnectedToInternet))
        hotKeys.press(14)
        await settle()
        guard case .failed(.network, _)? = panel.history.last else {
            return XCTFail("expected a network failure, got \(String(describing: panel.history.last))")
        }
    }

    func test_escapeClosesPanelAndUnregistersItself() async {
        reader.selection = SelectedText(text: "nuance", source: .accessibility)
        client.result = .success(sampleResult)
        hotKeys.press(14)
        await settle()

        hotKeys.press(53)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(hotKeys.registeredKeys.contains(53))
    }

    func test_clickOutsideClosesPanel() async {
        reader.selection = SelectedText(text: "nuance", source: .accessibility)
        client.result = .success(sampleResult)
        hotKeys.press(14)
        await settle()
        panel.onClickOutside?()
        XCTAssertFalse(panel.isVisible)
    }

    /// A slow first answer must never replace the answer to a newer press.
    func test_latestPressWins() async {
        client.delayFirstCall = true
        reader.selection = SelectedText(text: "first", source: .accessibility)
        client.result = .success(sampleResult)
        hotKeys.press(14)
        await settle()

        reader.selection = SelectedText(text: "second", source: .accessibility)
        let newer = ExplainResult(explanation: "newer", chinese: "新", ipa: nil, partOfSpeech: nil, example: nil, hardWords: [])
        client.result = .success(newer)
        hotKeys.press(14)
        await settle()
        client.releaseFirstCall(with: .success(sampleResult))
        await settle()

        XCTAssertEqual(panel.currentState, .loaded(ExplainInput(text: "second", mode: .word, wasTruncated: false), newer))
    }

    // MARK: - Speak

    func test_speakShortcutReadsSelectionWithSettingsVoice() async {
        settings.setVoiceIdentifier("voice-id")
        settings.setSpeechRate(0.5)
        reader.selection = SelectedText(text: "Hello there", source: .accessibility)

        hotKeys.press(1)
        await settle()

        XCTAssertEqual(speech.spoken.first?.text, "Hello there")
        XCTAssertEqual(speech.spoken.first?.voice, "voice-id")
        XCTAssertEqual(speech.spoken.first?.rate, 0.5)
    }

    func test_speakShortcutStopsWhileSpeaking() {
        speech.isSpeaking = true
        hotKeys.press(1)
        XCTAssertEqual(speech.stopCount, 1)
        XCTAssertTrue(speech.spoken.isEmpty)
    }

    func test_panelSpeakButtonReadsPanelText() async {
        reader.selection = SelectedText(text: "nuance", source: .accessibility)
        client.result = .success(sampleResult)
        hotKeys.press(14)
        await settle()

        panel.onSpeak?()
        XCTAssertEqual(speech.spoken.last?.text, "nuance")
    }

    func test_speakingStateIsForwardedToPanel() async {
        speech.isSpeakingSubject.send(true)
        await settle()
        XCTAssertEqual(panel.speaking, true)
    }

    func test_activeKeySource() {
        XCTAssertEqual(coordinator.activeKeySource, .environment)
        environment = [:]
        XCTAssertNil(coordinator.activeKeySource)
        settings.saveAPIKey("sk-saved")
        XCTAssertEqual(coordinator.activeKeySource, .explainKeychain)
    }
}

// MARK: - Fakes

@MainActor
private final class FakeHotKeys: HotKeyRegistering {
    private var nextID: UInt32 = 1
    private var entries: [UInt32: (keyCode: UInt32, handler: () -> Void)] = [:]

    var registeredKeys: [UInt32] {
        entries.sorted { $0.key < $1.key }.map(\.value.keyCode)
    }

    func register(keyCode: UInt32, modifiers: ShortcutModifierMask, handler: @escaping () -> Void) -> HotKeyToken? {
        let id = nextID
        nextID += 1
        entries[id] = (keyCode, handler)
        return HotKeyToken(id: id)
    }

    func unregister(_ token: HotKeyToken?) {
        guard let token else { return }
        entries.removeValue(forKey: token.id)
    }

    func press(_ keyCode: UInt32) {
        entries.values.first { $0.keyCode == keyCode }?.handler()
    }
}

@MainActor
private final class FakeReader: SelectedTextReading {
    var selection: SelectedText?
    func read() async -> SelectedText? { selection }
}

private final class FakeClient: ExplainGenerating, @unchecked Sendable {
    struct Call { let input: ExplainInput; let apiKey: String; let model: String }

    var result: Result<ExplainResult, Error> = .failure(ExplainFailure.malformedResponse)
    var calls: [Call] = []
    var delayFirstCall = false
    private var firstCallContinuation: CheckedContinuation<Result<ExplainResult, Error>, Never>?

    func explain(_ input: ExplainInput, apiKey: String, model: String, baseURL: String) async throws -> ExplainResult {
        calls.append(Call(input: input, apiKey: apiKey, model: model))
        if delayFirstCall, calls.count == 1 {
            let delayed = await withCheckedContinuation { firstCallContinuation = $0 }
            return try delayed.get()
        }
        return try result.get()
    }

    func releaseFirstCall(with result: Result<ExplainResult, Error>) {
        firstCallContinuation?.resume(returning: result)
        firstCallContinuation = nil
    }
}

@MainActor
private final class FakePanel: ExplainPanelPresenting {
    var onSpeak: (() -> Void)?
    var onClose: (() -> Void)?
    var onClickOutside: (() -> Void)?
    private(set) var isVisible = false
    private(set) var currentState: ExplainPanelState?
    private(set) var history: [ExplainPanelState] = []
    private(set) var speaking: Bool?

    func show(_ state: ExplainPanelState) {
        isVisible = true
        currentState = state
        history.append(state)
    }

    func update(_ state: ExplainPanelState) {
        currentState = state
        history.append(state)
    }

    func setSpeaking(_ isSpeaking: Bool) { speaking = isSpeaking }

    func hide() {
        isVisible = false
        currentState = nil
    }
}

@MainActor
private final class FakeSpeech: SpeechPerforming {
    struct Spoken { let text: String; let voice: String?; let rate: Double }

    var isSpeaking = false
    let isSpeakingSubject = PassthroughSubject<Bool, Never>()
    var isSpeakingPublisher: AnyPublisher<Bool, Never> { isSpeakingSubject.eraseToAnyPublisher() }
    private(set) var spoken: [Spoken] = []
    private(set) var stopCount = 0

    func speak(_ text: String, preferredVoiceIdentifier: String?, rate: Double) {
        spoken.append(Spoken(text: text, voice: preferredVoiceIdentifier, rate: rate))
    }

    func stop() { stopCount += 1 }
}
