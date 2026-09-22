import SwiftUI

struct SpeechSettingsView: View {
    @ObservedObject var speech: SpeechService
    @State private var hasPreviewed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle(L10n.string("speech.settings.voice", "朗读音色"))
                    VStack(spacing: 0) {
                        ForEach(SpeechVoice.allCases) { voice in
                            voiceRow(voice)
                            if voice != SpeechVoice.allCases.last {
                                Divider().padding(.horizontal, 18)
                            }
                        }
                    }
                    .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.large))
                    .appCardBorder()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.string("speech.settings.scope", "用于所有页面的朗读与自动朗读。登录后音色随账号同步，未登录时仅保存在本机。"))
                    Text(syncStatusMessage)
                    Text(L10n.string("speech.settings.preview_hint", "试听使用同一句英文，首次需要联网，之后可使用缓存播放。"))
                    Text(L10n.string("speech.settings.fallback_hint", "离线或云端服务不可用时，使用系统声音，音色可能不同。"))
                }
                .font(.footnote)
                .foregroundStyle(AppTextColor.secondary)

                if hasPreviewed && speech.isUsingSystemVoice {
                    Label(L10n.string("speech.settings.fallback_active", "本次使用的是系统声音，并非所选音色。"), systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(AppTextColor.primary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppSurfaceColor.elevated, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium))
                }
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

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTextColor.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private var syncStatusMessage: String {
        switch speech.preferenceSyncStatus {
        case .local:
            L10n.string("speech.settings.sync.local", "音色已保存在本机")
        case .syncing:
            L10n.string("speech.settings.sync.syncing", "正在同步音色设置…")
        case .synced:
            L10n.string("speech.settings.sync.synced", "音色已同步到账号")
        case .pending:
            L10n.string("speech.settings.sync.pending", "暂未同步，联网后会自动重试；仍可使用当前音色。")
        }
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
