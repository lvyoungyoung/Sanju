import SwiftUI
import UIKit

struct SaveResultHUD: View {
    let message: String
    let isSuccess: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(
                    isSuccess
                    ? AppPalette.accent
                    : Color(red: 0.88, green: 0.37, blue: 0.24)
                )

            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppTextColor.primary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(width: 188)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .stroke(AppStroke.highlight.opacity(0.75), lineWidth: 1)
        )
        .appCardShadow()
    }
}

struct MemoryDetailImageSkeleton: View {
    @State private var phase: CGFloat = -0.35

    var body: some View {
        RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous)
            .fill(AppSurfaceColor.secondaryFill)
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color(.systemBackground).opacity(0.28),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .rotationEffect(.degrees(22))
                    .frame(width: proxy.size.width * 0.55, height: proxy.size.height * 1.4)
                    .offset(x: proxy.size.width * phase)
                }
                .clipped()
            }
            .onAppear {
                withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                    phase = 1.2
                }
            }
    }
}

struct MemoryDetailSentencePanel: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var selectedScenarioIndex = 0
    let memory: MemoryEntry
    var body: some View {
        VStack(spacing: 28) {
            if memory.sentences.isEmpty {
                ContentUnavailableView(
                    L10n.string("memory_detail.group.empty.title", "没有内容"),
                    systemImage: "text.badge.xmark"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.xLarge)
            } else if memory.sentences.isCompleteScenarioDialogues {
                let groups = memory.sentences.dialogueGroups
                HStack(spacing: 6) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            Button {
                                guard selectedScenarioIndex != index else { return }
                                appModel.speech.stop()
                                selectedScenarioIndex = index
                            } label: {
                                Text(group.scenarioTitle ?? "")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(selectedScenarioIndex == index ? AppTextColor.primary : AppTextColor.secondary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(selectedScenarioIndex == index ? AppSurfaceColor.card : Color.clear, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selectedScenarioIndex == index ? .isSelected : [])
                            .accessibilityIdentifier("scenario.tab.\(index)")
                        }
                }
                .padding(4)
                .background(AppSurfaceColor.secondaryFill, in: Capsule())
                if let group = groups.indices.contains(selectedScenarioIndex) ? groups[selectedScenarioIndex] : groups.first {
                    VStack(spacing: 12) {
                        ScenarioPlaybackButton(speech: appModel.speech, requests: group.sentences.map {
                            appModel.speech.request(sentence: $0, context: memory.context)
                        })
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        MemoryDialogueGroupCard(group: group, context: memory.context)
                    }
                    .id(group.id)
                }
            } else {
                ForEach(Array(memory.sentences.dialogueGroups.enumerated()), id: \.element.id) { index, group in
                    VStack(spacing: 12) {
                        if group.sentences.count == 2 {
                            HStack(spacing: 12) {
                                Rectangle().fill(AppTextColor.secondary.opacity(0.2)).frame(height: 1)
                                Text(String(format: "%02d", index + 1))
                                    .font(.system(.caption, design: .rounded, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(AppTextColor.secondary)
                                Rectangle().fill(AppTextColor.secondary.opacity(0.2)).frame(height: 1)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(L10n.string("dialogue.group.number", "第 %d 组对话", index + 1))
                            .accessibilityAddTraits(.isHeader)
                        }
                        MemoryDialogueGroupCard(group: group, context: memory.context)
                    }
                }
            }
        }
        .onChange(of: memory.id) { _, _ in selectedScenarioIndex = 0 }
        .onDisappear { if memory.sentences.isCompleteScenarioDialogues { appModel.speech.stop() } }
    }
}

private struct ScenarioPlaybackButton: View {
    @ObservedObject var speech: SpeechService
    let requests: [SpeechRequest]

    private var isActive: Bool {
        speech.sequenceRequests == requests || speech.activeRequest.map { requests.contains($0) } == true
    }

    var body: some View {
        Button {
            if isActive { speech.stop() } else { speech.speakSequence(requests) }
        } label: {
            Label(isActive ? L10n.string("new.result.playing", "播放中") : L10n.string("dialogue.play_all", "播放对话"),
                  systemImage: isActive ? "stop.fill" : "play.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppPalette.accentText)
                .frame(minHeight: 44)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("scenario.play")
    }
}

struct MemoryDialogueGroupCard: View {
    let group: SentenceDialogueGroup
    let context: MemoryContentContext
    private var isDialogue: Bool { group.sentences.count >= 2 }

    var body: some View {
        if isDialogue {
            VStack(spacing: 12) {
                ForEach(group.sentences) { sentence in
                    MemoryDialogueChatBubble(sentence: sentence, context: context)
                }
            }
            .padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(group.sentences) { sentence in
                    MemoryDetailSentenceRow(sentence: sentence, context: context)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
            .appCardBorder()
        }
    }
}

struct MemoryDialogueChatBubble: View {
    @State private var isExpanded = false
    let sentence: SentenceRecord
    let context: MemoryContentContext

    var body: some View {
        MemoryDialogueChatBubbleContent(sentence: sentence, context: context, isExpanded: $isExpanded)
    }
}

struct MemoryDialogueChatBubbleContent: View {
    @EnvironmentObject private var appModel: AppModel
    let sentence: SentenceRecord
    let context: MemoryContentContext
    @Binding var isExpanded: Bool
    private var isReply: Bool { sentence.dialogue?.turn == 1 }

    var body: some View {
        DialogueBubble(isReply: isReply, bottomPadding: isExpanded ? 4 : 12) {
            Button { isExpanded.toggle() } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(sentenceText: sentence.targetText, language: context.teachingLocale.rawValue)
                        .font(AppTypography.sentence)
                        .foregroundStyle(AppTextColor.primary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SentenceReadingView(sentence: sentence, context: context, isEnabled: appModel.showsJapaneseReadings)
                }
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded
                ? L10n.string("dialogue.details.collapse", "轻点收起翻译和操作")
                : L10n.string("dialogue.details.expand", "轻点查看翻译和操作"))
            .accessibilityIdentifier("dialogue.details.\(sentence.id)")

            if isExpanded {
                Text(sentenceText: sentence.translationText, language: context.translationLanguage.rawValue)
                    .font(.subheadline)
                    .foregroundStyle(AppTextColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
        }
    }

    private var actions: some View {
        let request = appModel.speech.request(sentence: sentence, context: context)
        return HStack(spacing: 2) {
            Button { appModel.speech.speak(request) } label: {
                SpeechPlaybackLabel(speech: appModel.speech, text: request.text,
                    playingTitle: L10n.string("new.result.playing", "播放中"), request: request)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("dialogue.play.\(sentence.id)")

            Button { appModel.toggleFavorite(sentenceID: sentence.id) } label: {
                Image(systemName: sentence.isFavorite ? "star.fill" : "star")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(sentence.isFavorite
                ? L10n.string("favorites.action.unfavorite", "取消收藏")
                : L10n.string("new.result.favorite", "收藏"))
            .accessibilityAddTraits(sentence.isFavorite ? .isSelected : [])
            .accessibilityIdentifier("dialogue.favorite.\(sentence.id)")
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(AppPalette.accentText)
        .tint(AppPalette.accentText)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: isReply ? .trailing : .leading)
    }
}

struct MemoryDetailSentenceRow: View {
    @EnvironmentObject private var appModel: AppModel
    let sentence: SentenceRecord
    var context: MemoryContentContext = .legacyEnglish
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : AppSpacing.large) {
            if isCompact {
                HStack(alignment: .top, spacing: 10) {
                    if let dialogue = sentence.dialogue {
                        SentenceSpeakerBadge(speaker: dialogue.speaker)
                    }
                    sentenceContent
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if let dialogue = sentence.dialogue {
                        SentenceSpeakerBadge(speaker: dialogue.speaker)
                    }
                    sentenceContent
                }
            }

            SentenceActions(speech: appModel.speech, request: appModel.speech.request(sentence: sentence, context: context), isFavorite: sentence.isFavorite) {
                appModel.toggleFavorite(sentenceID: sentence.id)
            }
        }
        .padding(.vertical, isCompact ? 0 : 8)
    }

    private var sentenceContent: some View {
        VStack(alignment: .leading, spacing: isCompact ? 6 : 10) {
            Text(sentenceText: sentence.targetText, language: context.teachingLocale.rawValue)
                .font(AppTypography.sentence)
                .lineSpacing(isCompact ? 3 : 4)
                .foregroundStyle(AppTextColor.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            SentenceReadingView(sentence: sentence, context: context, isEnabled: appModel.showsJapaneseReadings)

            Text(sentenceText: sentence.translationText, language: context.translationLanguage.rawValue)
                .font(.system(size: 13))
                .foregroundStyle(AppTextColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MemoryDetailPagerControls: View {
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack {
            MemoryDetailPagerButton(
                title: L10n.string("memory_detail.pager.previous", "上一张"),
                isEnabled: canGoPrevious,
                action: onPrevious
            )

            Spacer()

            MemoryDetailPagerButton(
                title: L10n.string("memory_detail.pager.next", "下一张"),
                isEnabled: canGoNext,
                action: onNext
            )
        }
    }
}

private struct MemoryDetailPagerButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                Button(action: action) {
                    label
                }
                .buttonStyle(.glass)
            } else {
                Button(action: action) {
                    label
                        .background(.ultraThinMaterial, in: Capsule())
                        .appCardShadow()
                }
                .buttonStyle(.plain)
            }
        }
        .disabled(!isEnabled)
    }

    private var label: some View {
        Text(title)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(AppTextColor.primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .opacity(isEnabled ? 1 : 0.45)
    }
}
