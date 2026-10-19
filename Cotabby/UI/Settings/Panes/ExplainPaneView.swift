import SwiftUI

/// File overview:
/// "Explain & Translate" Settings pane. Presentation only: every control reads from and writes to
/// `ExplainSettingsModel`; the two actions it cannot express as settings (which key source is
/// active, and playing a voice sample) arrive as closures from the composition root, so the view
/// never touches the coordinator, Keychain, or speech engine directly.
/// Everything the Settings window needs to build this pane, bundled so the Settings coordinator
/// and container gain one parameter instead of three.
struct ExplainPaneDependencies {
    let settings: ExplainSettingsModel
    let activeKeySource: () -> ExplainAPIKeyResolver.Source?
    let previewVoice: () -> Void
}

struct ExplainPaneView: View {
    @ObservedObject var settings: ExplainSettingsModel
    /// Re-evaluated on every render, so saving a key updates the status line immediately.
    let activeKeySource: () -> ExplainAPIKeyResolver.Source?
    let previewVoice: () -> Void

    @State private var isRecordingExplain = false
    @State private var isRecordingSpeak = false
    @State private var apiKeyDraft = ""
    @State private var modelDraft = ""
    @State private var baseURLDraft = ""

    private let voices = SpeechService.englishVoiceOptions()

    var body: some View {
        SettingsPaneScaffold {
            Section {
                Toggle(isOn: Binding(get: { settings.isEnabled }, set: { settings.setEnabled($0) })) {
                    SettingsRowLabel(
                        title: "Explain & Translate",
                        description: "Select text in any app and press the shortcut to see a simple English "
                            + "explanation and a Chinese translation.",
                        systemImage: "character.book.closed"
                    )
                }
                .settingsItem(.explainTranslate)
            }

            Section("Shortcuts") {
                shortcutRow(
                    title: "Explain Selection",
                    description: "Show the explanation panel for the selected text. Esc closes it. "
                        + "While set, Option-E no longer types the é accent key.",
                    systemImage: "text.magnifyingglass",
                    shortcut: settings.explainShortcut,
                    other: settings.speakShortcut,
                    isRecording: $isRecordingExplain,
                    defaultShortcut: ExplainSettingsModel.defaultExplainShortcut,
                    save: settings.setExplainShortcut
                )
                shortcutRow(
                    title: "Read Selection Aloud",
                    description: "Read the selected text with the voice below. Press again to stop.",
                    systemImage: "speaker.wave.2",
                    shortcut: settings.speakShortcut,
                    other: settings.explainShortcut,
                    isRecording: $isRecordingSpeak,
                    defaultShortcut: ExplainSettingsModel.defaultSpeakShortcut,
                    save: settings.setSpeakShortcut
                )
                .settingsItem(.explainShortcuts)
            }

            Section("DeepSeek") {
                LabeledContent {
                    HStack(spacing: 8) {
                        SecureField("", text: $apiKeyDraft, prompt: Text(apiKeyPrompt))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 180, idealWidth: 240, maxWidth: 280)
                            .onSubmit(saveKey)
                        Button("Save", action: saveKey)
                            .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if settings.hasSavedAPIKey {
                            Button("Remove") { settings.saveAPIKey("") }
                        }
                    }
                } label: {
                    SettingsRowLabel(
                        title: "API Key",
                        description: keyStatus,
                        systemImage: "key"
                    )
                }
                .settingsItem(.explainAPIKey)
                if let error = settings.credentialError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                LabeledContent {
                    TextField("", text: $modelDraft, prompt: Text(ExplainSettingsModel.defaultModelName))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .onSubmit { settings.setModelName(modelDraft) }
                } label: {
                    SettingsRowLabel(title: "Model", description: "Press Return to save.", systemImage: "cpu")
                }

                LabeledContent {
                    TextField("", text: $baseURLDraft, prompt: Text(ExplainSettingsModel.defaultBaseURL))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit { settings.setBaseURL(baseURLDraft) }
                } label: {
                    SettingsRowLabel(title: "Server", description: "Press Return to save.", systemImage: "globe")
                }

                Label(
                    "The text you select is sent to DeepSeek's servers to be explained. Nothing is sent until you press the shortcut.",
                    systemImage: "exclamationmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Voice") {
                Picker(selection: Binding(
                    get: { settings.voiceIdentifier ?? "" },
                    set: { settings.setVoiceIdentifier($0.isEmpty ? nil : $0) }
                )) {
                    Text("Automatic (best installed English voice)").tag("")
                    ForEach(voices) { voice in
                        Text(voice.displayName).tag(voice.id)
                    }
                } label: {
                    SettingsRowLabel(
                        title: "Voice",
                        description: "Download nicer voices in System Settings → Accessibility → Spoken Content. "
                            + "Chinese text always uses a Chinese voice.",
                        systemImage: "person.wave.2"
                    )
                }
                .settingsItem(.explainVoice)

                LabeledContent {
                    HStack(spacing: 8) {
                        Slider(
                            value: Binding(get: { settings.speechRate }, set: { settings.setSpeechRate($0) }),
                            in: 0.2...0.65
                        )
                        .frame(width: 160)
                        Button("Test", action: previewVoice)
                    }
                } label: {
                    SettingsRowLabel(title: "Speed", description: "Slower is easier to follow.", systemImage: "tortoise")
                }
            }
        }
        .onAppear {
            modelDraft = settings.modelName
            baseURLDraft = settings.baseURL
        }
    }

    private var apiKeyPrompt: String {
        settings.hasSavedAPIKey ? "Saved — paste to replace" : "Paste API key"
    }

    private var keyStatus: String {
        guard let source = activeKeySource() else {
            return "No key found. Paste your DeepSeek key here, or set DEEPSEEK_API_KEY."
        }
        return "Using \(source.label)."
    }

    private func saveKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.saveAPIKey(trimmed)
        apiKeyDraft = ""
    }

    // swiftlint:disable:next function_parameter_count
    private func shortcutRow(
        title: String,
        description: String,
        systemImage: String,
        shortcut: ExplainShortcut,
        other: ExplainShortcut,
        isRecording: Binding<Bool>,
        defaultShortcut: ExplainShortcut,
        save: @escaping (ExplainShortcut) -> Void
    ) -> some View {
        LabeledContent {
            KeybindRow(
                label: shortcut.label,
                keyCode: shortcut.keyCode,
                isRecording: isRecording,
                onRecord: { keyCode, modifiers, label in
                    save(ExplainShortcut(keyCode: keyCode, modifiers: modifiers, label: label))
                },
                onReset: { save(defaultShortcut) },
                resetLabel: "Reset",
                shouldShowReset: shortcut != defaultShortcut,
                onClear: { save(.unbound) },
                clearLabel: "Clear",
                clearHelp: "Unbind this shortcut.",
                conflictChecker: { keyCode, modifiers in
                    keyCode == other.keyCode && modifiers == other.modifiers ? "the other Explain shortcut" : nil
                }
            )
        } label: {
            SettingsRowLabel(title: title, description: description, systemImage: systemImage)
        }
    }
}
