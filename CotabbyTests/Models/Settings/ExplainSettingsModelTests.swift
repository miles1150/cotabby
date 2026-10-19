import XCTest
@testable import Cotabby

/// Persistence tests for the Explain & Translate settings, against an isolated defaults suite and
/// an in-memory credential store so nothing touches the real app domain or Keychain.
@MainActor
final class ExplainSettingsModelTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ExplainSettingsModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeModel(apiKey: String? = nil) -> ExplainSettingsModel {
        ExplainSettingsModel(defaults: defaults, credentialStore: InMemoryOpenAICompatibleCredentialStore(apiKey: apiKey))
    }

    func test_defaults() {
        let model = makeModel()
        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(model.explainShortcut, ExplainSettingsModel.defaultExplainShortcut)
        XCTAssertEqual(model.speakShortcut, ExplainSettingsModel.defaultSpeakShortcut)
        XCTAssertEqual(model.modelName, "deepseek-flash")
        XCTAssertEqual(model.baseURL, "https://api.deepseek.com")
        XCTAssertNil(model.voiceIdentifier)
        XCTAssertEqual(model.speechRate, ExplainSettingsModel.defaultSpeechRate)
        XCTAssertFalse(model.hasSavedAPIKey)
    }

    func test_valuesPersistAcrossInstances() {
        let first = makeModel()
        first.setEnabled(false)
        first.setExplainShortcut(ExplainShortcut(keyCode: 2, modifiers: [.control, .option], label: "⌃⌥D"))
        first.setSpeakShortcut(.unbound)
        first.setModelName("deepseek-v4-pro")
        first.setBaseURL("https://api.deepseek.com/v1")
        first.setVoiceIdentifier("com.apple.voice.premium.en-US.Zoe")
        first.setSpeechRate(0.5)

        let second = makeModel()
        XCTAssertFalse(second.isEnabled)
        XCTAssertEqual(second.explainShortcut, ExplainShortcut(keyCode: 2, modifiers: [.control, .option], label: "⌃⌥D"))
        XCTAssertEqual(second.speakShortcut, .unbound)
        XCTAssertFalse(second.speakShortcut.isBound)
        XCTAssertEqual(second.modelName, "deepseek-v4-pro")
        XCTAssertEqual(second.baseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(second.voiceIdentifier, "com.apple.voice.premium.en-US.Zoe")
        XCTAssertEqual(second.speechRate, 0.5)
    }

    func test_blankModelAndURLFallBackToDefaults() {
        let model = makeModel()
        model.setModelName("custom")
        model.setModelName("   ")
        model.setBaseURL("")
        XCTAssertEqual(model.modelName, ExplainSettingsModel.defaultModelName)
        XCTAssertEqual(model.baseURL, ExplainSettingsModel.defaultBaseURL)
    }

    func test_speechRateIsClamped() {
        let model = makeModel()
        model.setSpeechRate(5)
        XCTAssertEqual(model.speechRate, 0.65)
        model.setSpeechRate(-1)
        XCTAssertEqual(model.speechRate, 0.2)
    }

    func test_clearingVoiceReturnsToAutomatic() {
        let model = makeModel()
        model.setVoiceIdentifier("voice")
        model.setVoiceIdentifier(nil)
        XCTAssertNil(makeModel().voiceIdentifier)
    }

    func test_apiKeySaveAndDelete() {
        let model = makeModel()
        model.saveAPIKey("sk-test")
        XCTAssertTrue(model.hasSavedAPIKey)
        XCTAssertEqual(model.readSavedAPIKey(), "sk-test")
        XCTAssertNil(model.credentialError)

        model.saveAPIKey("")
        XCTAssertFalse(model.hasSavedAPIKey)
        XCTAssertNil(model.readSavedAPIKey())
    }

    func test_existingKeyIsDetectedAtInit() {
        XCTAssertTrue(makeModel(apiKey: "sk-existing").hasSavedAPIKey)
    }
}
