import SwiftUI

struct SentenceDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.locale) private var locale
    @StateObject private var model = SentenceExplanationModel()
    @State private var generationTask: Task<Void, Never>?
    let memoryID: UUID
    let sentenceID: UUID

    private var sentence: SentenceRecord? {
        appModel.memory(withID: memoryID)?.sentences.first { $0.id == sentenceID }
    }

    private var language: String { locale.language.languageCode?.identifier == "zh" ? "zh" : "en" }
    private var identity: String {
        [appModel.accountRequests.revision.uuidString, sentenceID.uuidString, sentence?.english ?? "", sentence?.chinese ?? "", language].joined(separator: "|")
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            if let memory = appModel.memory(withID: memoryID), let sentence {
                VStack(alignment: .leading, spacing: AppSpacing.large) {
                    MemoryDetailImageView(imageData: memory.imageData)
                    originalSentence(sentence)
                    if let explanation = model.explanation {
                        SentenceExplanationContent(explanation: explanation)
                            .id(identity)
                    } else {
                        analysisAction(sentence)
                    }
                }
                .padding(AppSpacing.xLarge)
            } else {
                EmptyStateView(
                    title: L10n.string("memory_detail.missing.title", "内容不存在"),
                    subtitle: L10n.string("memory_detail.missing.subtitle", "这条历史记录可能已被删除。")
                )
                .padding(AppSpacing.section)
            }
        }
        .background(AppSurfaceColor.page)
        .navigationTitle(L10n.string("sentence_detail.title", "句子详情"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task(id: identity) {
            generationTask?.cancel()
            model.reset()
            guard let sentence else { return }
            await model.load(generate: false) {
                try await appModel.sentenceExplanation(sentence: sentence, language: language, generate: false)
            }
        }
        .task(id: memoryID) { await appModel.ensureMemoryImageLoaded(memoryID: memoryID) }
        .onDisappear { generationTask?.cancel() }
    }

    private func originalSentence(_ sentence: SentenceRecord) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.large) {
            Text(sentence.english)
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(AppTextColor.primary)
                .textSelection(.enabled)
            Text(sentence.chinese)
                .font(.body)
                .foregroundStyle(AppTextColor.secondary)
            SentencePlaybackButton(speech: appModel.speech, text: sentence.english)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.xLarge)
        .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.card))
    }

    private func analysisAction(_ sentence: SentenceRecord) -> some View {
        VStack(spacing: AppSpacing.medium) {
            Button {
                generationTask = Task {
                    await model.load(generate: true) {
                        try await appModel.sentenceExplanation(sentence: sentence, language: language, generate: true)
                    }
                }
            } label: {
                HStack(spacing: AppSpacing.small) {
                    if model.isLoading { ProgressView().tint(AppPalette.onAccent) }
                    Text(model.isGenerating
                         ? L10n.string("sentence_detail.analyzing", "正在解析…")
                         : model.isLoading ? L10n.string("sentence_detail.loading_saved", "正在读取解析…")
                         : L10n.string("sentence_detail.analyze", "AI解析"))
                        .font(.system(.body, weight: .semibold))
                }
                .foregroundStyle(AppPalette.onAccent)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(AppPalette.accent, in: Capsule())
            }
            .buttonStyle(StudioPressStyle())
            .disabled(model.isLoading)
            .accessibilityIdentifier("sentence_detail.analyze")
            if let error = model.errorMessage {
                Text(error).font(.subheadline).foregroundStyle(AppTextColor.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

struct SentenceExplanationContent: View {
    let explanation: SentenceExplanation

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.section) {
            section(L10n.string("sentence_detail.key_points", "理解这句话")) {
                ForEach(explanation.points.indices, id: \.self) { index in
                    let point = explanation.points[index]
                    VStack(alignment: .leading, spacing: AppSpacing.small) {
                        Text(point.title).font(.system(.body, weight: .semibold)).foregroundStyle(AppPalette.accentText)
                        Text(point.explanation).font(.body).foregroundStyle(AppTextColor.primary)
                    }
                }
            }
            section(L10n.string("sentence_detail.examples", "换个场景，也能这样说")) {
                ForEach(explanation.examples.indices, id: \.self) { index in
                    let example = explanation.examples[index]
                    VStack(alignment: .leading, spacing: AppSpacing.small) {
                        Text(example.english).font(.system(.body, weight: .medium)).foregroundStyle(AppTextColor.primary)
                        Text(example.chinese).font(.subheadline).foregroundStyle(AppTextColor.secondary)
                    }
                }
            }
            section(L10n.string("sentence_detail.practice", "试着用一用")) {
                SentenceExplanationExerciseView(exercise: explanation.exercise)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.large) {
            Text(title).font(.system(.headline, weight: .semibold)).foregroundStyle(AppTextColor.primary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.xLarge)
        .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.card))
    }
}

struct SentenceExplanationExerciseView: View {
    let exercise: SentenceExplanation.Exercise
    @State private var attempt = SentenceExerciseAttempt()

    private var selectedIndex: Int? { attempt.selectedIndex }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            Text(exercise.prompt).font(.subheadline).foregroundStyle(AppTextColor.secondary)
            Text(exercise.sentence).font(.system(.body, weight: .medium)).foregroundStyle(AppTextColor.primary)
            ForEach(exercise.options.indices, id: \.self) { index in
                Button { attempt.select(index, exercise: exercise) } label: {
                    HStack(spacing: AppSpacing.medium) {
                        Text(String(UnicodeScalar(65 + index)!)).font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(AppTextColor.secondary)
                        Text(exercise.options[index]).foregroundStyle(AppTextColor.primary)
                        Spacer(minLength: 0)
                        if selectedIndex != nil, index == exercise.answerIndex {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if selectedIndex == index {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                    .padding(AppSpacing.medium)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .background(selectedIndex == index ? AppPalette.accent.opacity(0.12) : AppSurfaceColor.subtleFill,
                                in: RoundedRectangle(cornerRadius: AppCornerRadius.small))
                }
                .buttonStyle(.plain)
                .disabled(selectedIndex != nil)
            }
            if let selectedIndex {
                Text(selectedIndex == exercise.answerIndex
                     ? L10n.string("sentence_detail.correct", "答对了")
                     : L10n.string("sentence_detail.incorrect", "再记住这个用法"))
                    .font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppPalette.accentText)
                Text(exercise.explanation).font(.subheadline).foregroundStyle(AppTextColor.secondary)
                    .accessibilityIdentifier("sentence_detail.answer_explanation")
                Button(L10n.string("sentence_detail.try_again", "再练一次")) { attempt.reset() }
                    .font(.subheadline).foregroundStyle(AppPalette.accentText)
            }
        }
    }
}
