import SwiftUI

struct SpeechSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let speech: SpeechService

    var body: some View {
        NavigationStack {
            SpeechSettingsView(speech: speech)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.string("common.close", "关闭")) { dismiss() }
                    }
                }
        }
        // Keep this presentation independent of the compact study-settings sheet.
        .presentationDetents([.large])
        .presentationBackground(AppSurfaceColor.page)
        .presentationDragIndicator(.visible)
    }
}

struct SpeechSettingsView: View {
    @ObservedObject var speech: SpeechService
    @State private var hasPreviewed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle(L10n.string("speech.settings.english_voice", "英文朗读音色"))
                    Text(L10n.string("speech.settings.english_scope", "以下音色和试听仅用于英文。日语、西班牙语和法语按句子语言朗读，不受此选择影响。"))
                        .font(.footnote)
                        .foregroundStyle(AppTextColor.secondary)
                    VStack(spacing: 0) {
                        ForEach(SpeechVoice.allCases) { voice in
                            voiceRow(voice)
                            if voice != SpeechVoice.allCases.last {
                                Divider().padding(.horizontal, 18)
                            }
                        }
                    }
                    .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
                    .appCardBorder()
                }

                Text(L10n.string("speech.settings.fallback_hint", "网络不可用时，使用系统声音，音色可能不同。"))
                    .font(.footnote)
                    .foregroundStyle(AppTextColor.secondary)
            }
            .padding(AppSpacing.section)
        }
        .background(AppSurfaceColor.page)
        .navigationTitle(L10n.string("speech.settings.title", "朗读设置"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onDisappear {
            if hasPreviewed { speech.stop() }
        }
    }

    static func voiceSummary(for language: LearningLanguage, voice: SpeechVoice) -> String {
        if language == .english {
            return L10n.string("speech.settings.english_voice_summary", "英文 · %@", voice.rawValue)
        }
        return L10n.string("speech.settings.sentence_language_summary", "跟随句子语言")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTextColor.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func voiceRow(_ voice: SpeechVoice) -> some View {
        HStack(spacing: 12) {
            Button {
                speech.setVoice(voice)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: speech.selectedVoice == voice ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(speech.selectedVoice == voice ? AppPalette.accentText : AppTextColor.tertiary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(voice.rawValue).font(.body.weight(.semibold))
                        Text(voice.isFemale
                             ? L10n.string("speech.voice.female", "英文女声")
                             : L10n.string("speech.voice.male", "英文男声"))
                            .font(.caption)
                            .foregroundStyle(AppTextColor.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(AppTextColor.primary)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(speech.selectedVoice == voice ? .isSelected : [])

            Button {
                hasPreviewed = true
                speech.preview(voice)
            } label: {
                HStack(spacing: 6) {
                    if speech.loadingText == SpeechPreferences.previewText && speech.loadingVoice == voice {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(L10n.string("speech.settings.preview", "试听"))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppPalette.accentText)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(AppSurfaceColor.elevated, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("speech.settings.preview_voice", "试听 %@", voice.rawValue))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}
