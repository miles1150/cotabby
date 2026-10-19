import Combine
import SwiftUI

/// File overview:
/// The SwiftUI content of the Explain & Translate panel. Presentation only: it renders an
/// `ExplainPanelState` and reports button taps through closures. It owns no networking, speech,
/// or window logic — those live in `ExplainCoordinator` and `ExplainPanelController`.
///
/// It reuses the shared dark HUD look (`popupHUDChrome`) so it matches Cotabby's other floating
/// surfaces (emoji picker, suggestion card).

/// Observable state the panel controller updates and the view reads. A class (not a struct)
/// because the hosting view keeps one long-lived instance and SwiftUI re-renders when the
/// `@Published` values change.
@MainActor
final class ExplainPanelViewModel: ObservableObject {
    @Published var state: ExplainPanelState?
    @Published var isSpeaking = false

    nonisolated deinit {}
}

struct ExplainPanelView: View {
    static let width: CGFloat = 380
    /// Long paragraph answers scroll instead of growing past this height.
    static let maxContentHeight: CGFloat = 420

    @ObservedObject var model: ExplainPanelViewModel
    let onSpeak: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().overlay(PopupTheme.hairline)
            content
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .popupHUDChrome(cornerRadius: 12)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.state?.input?.text ?? "Explain & Translate")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PopupTheme.primaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(PopupTheme.secondaryText)
                }
            }
            Spacer(minLength: 4)
            if model.state?.input != nil {
                iconButton(model.isSpeaking ? "stop.fill" : "speaker.wave.2.fill",
                           help: model.isSpeaking ? "Stop reading" : "Read aloud",
                           action: onSpeak)
            }
            iconButton("xmark", help: "Close (Esc)", action: onClose)
        }
    }

    /// Mode, IPA and part of speech in one quiet line, e.g. "/ˈnjuː.ɑːns/ · noun".
    private var subtitle: String? {
        guard case .loaded(let input, let result) = model.state else { return nil }
        var parts: [String] = []
        if let ipa = result.ipa { parts.append(ipa) }
        if let partOfSpeech = result.partOfSpeech { parts.append(partOfSpeech) }
        if parts.isEmpty { parts.append(input.mode.label) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking DeepSeek…")
                    .font(.system(size: 12))
                    .foregroundStyle(PopupTheme.secondaryText)
            }
        case .loaded(let input, let result):
            ScrollView {
                ExplainResultSections(input: input, result: result)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Self.maxContentHeight)
            .fixedSize(horizontal: false, vertical: true)
        case .failed(let failure, _):
            Label(failure.userMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PopupTheme.primaryText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The answer itself, arranged by mode: dictionary entry for words, rewrite + translation for
/// sentences, translation + summary for paragraphs.
private struct ExplainResultSections: View {
    let input: ExplainInput
    let result: ExplainResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch input.mode {
            case .word:
                section("Meaning", result.explanation)
                section("中文", result.chinese)
                if let example = result.example {
                    section("Example", example, italic: true)
                }
            case .sentence:
                section("In plain English", result.explanation)
                section("中文", result.chinese)
                hardWords
            case .paragraph:
                section("中文", result.chinese)
                section("Summary", result.explanation)
                hardWords
            }
            if input.wasTruncated {
                Text("Only the first \(ExplainModeClassifier.maxCharacters) characters were explained.")
                    .font(.system(size: 10))
                    .foregroundStyle(PopupTheme.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var hardWords: some View {
        if !result.hardWords.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("Words")
                ForEach(result.hardWords, id: \.self) { word in
                    Text("\(Text(word.word).bold()) — \(word.meaning)")
                        .font(.system(size: 12))
                        .foregroundStyle(PopupTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func section(_ title: String, _ body: String, italic: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionTitle(title)
            Text(body)
                .font(.system(size: 13))
                .italic(italic)
                .foregroundStyle(PopupTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(PopupTheme.secondaryText)
    }
}

extension ExplainMode {
    /// Short label for the panel subtitle when the model gave no IPA or part of speech.
    var label: String {
        switch self {
        case .word: return "word or phrase"
        case .sentence: return "sentence"
        case .paragraph: return "paragraph"
        }
    }
}
