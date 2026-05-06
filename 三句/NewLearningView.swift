import PhotosUI
import SwiftUI
import UIKit

struct NewLearningView: View {
    private let recoveryResultUnavailableMessage = "暂未从云端获取到结果，请重试。"
    private let generationStepDisplayDuration: Duration = .seconds(2)

    @EnvironmentObject private var appModel: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedItem: PhotosPickerItem?
    @State private var isShowingPhotoPicker = false
    @State private var shouldClearGeneratedMemoryOnNextPhotoSelection = false
    @State private var isLoadingSelectedPhoto = false
    @State private var isGenerating = false
    @State private var generationStatus = "正在识别图片内容..."
    @State private var generationStep = 0
    @State private var errorMessage: String?
    @State private var isShowingPurchasePrompt = false
    @State private var isShowingPurchaseSheet = false
    @State private var isWaitingForRecoveredGeneration = false
    @State private var hasAttemptedPendingRecovery = false
    @State private var isRecoveryCancelButtonVisible = false
    @State private var recoveryCancelButtonRevealTask: Task<Void, Never>?
    @State private var activePendingRecoveryTask: Task<Void, Never>?
    @State private var photoLoadRequestID = UUID()

    private var heroTitleFontSize: CGFloat {
        horizontalSizeClass == .compact ? 24 : 28
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: AppSpacing.large) {
                if selectedImageData == nil && !isLoadingSelectedPhoto {
                    newLearningHero
                }

                if selectedImageData == nil && !isLoadingSelectedPhoto {
                    Button {
                        guard !isRecoveryInteractionLocked else { return }
                        selectedItem = nil
                        isShowingPhotoPicker = true
                    } label: {
                        uploadCard
                    }
                    .buttonStyle(.plain)
                    .disabled(isRecoveryInteractionLocked)

                    Text("图片会被发送给AI分析，请谨慎上传包含敏感信息的图片")
                        .font(.system(size: AppFontSize.metadata))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    agreementHint
                } else {
                    uploadCard
                }

                if let errorMessage,
                   displayedMemory == nil,
                   !shouldShowRecoveryLoadingState {
                    Text(errorMessage)
                        .font(.system(size: AppFontSize.metadata))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let selectedImageData {
                    if isGenerating || shouldShowRecoveryLoadingState || shouldShowPendingRecoveryLoadingState {
                        NewLearningResultPanel {
                            VStack(alignment: .leading, spacing: AppSpacing.large) {
                                GenerationProgressCard(
                                    title: isGenerating ? generationStatus : "正在尝试获取上次结果，请稍等"
                                )
                                if isRecoveryCancelButtonVisible {
                                    Button {
                                        cancelPendingRecovery()
                                    } label: {
                                        Text("放弃本次恢复")
                                            .font(.system(size: AppFontSize.body, weight: .semibold))
                                            .foregroundStyle(Color(red: 0.72, green: 0.42, blue: 0.08))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, AppSpacing.medium)
                                            .background(
                                                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                                    .fill(Color(red: 0.99, green: 0.95, blue: 0.90))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                                SentenceSkeletonSection()
                            }
                        }
                    } else if let displayedMemory {
                        NewLearningResultPanel {
                            VStack(spacing: AppSpacing.xLarge) {
                                NewLearningSentenceList(memory: displayedMemory)

                                VStack(spacing: AppSpacing.large) {
                                    Text("内容已保存到「回忆」中，你可以选择其他图片继续使用")
                                        .font(.system(size: AppFontSize.sectionLabel))
                                        .foregroundStyle(AppTextColor.secondary)
                                        .multilineTextAlignment(.center)

                                    Button {
                                        guard !isRecoveryInteractionLocked else { return }
                                        selectedItem = nil
                                        shouldClearGeneratedMemoryOnNextPhotoSelection = true
                                        isShowingPhotoPicker = true
                                    } label: {
                                        Text("再来一张")
                                            .font(.system(size: AppFontSize.field, weight: .semibold))
                                            .foregroundStyle(.orange)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, AppSpacing.medium)
                                            .background(
                                                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                                    .fill(Color(red: 1.0, green: 0.98, blue: 0.95))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isRecoveryInteractionLocked)
                                }
                            }
                        }
                    } else if !shouldHideActionsForRecoveryFailure {
                        VStack(spacing: AppSpacing.medium) {
                            Button {
                                guard !isRecoveryInteractionLocked else { return }
                                if appModel.remainingCredits <= 0 {
                                    isShowingPurchasePrompt = true
                                } else {
                                    Task {
                                        await generateSentences()
                                    }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: AppFontSize.body, weight: .semibold))
                                    Text("用三句描述一下")
                                        .font(.system(size: AppFontSize.bodyProminent, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, AppSpacing.large)
                                .background(
                                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    Color(red: 1.00, green: 0.72, blue: 0.10),
                                                    Color(red: 0.98, green: 0.56, blue: 0.00)
                                                ],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(selectedImageData.isEmpty || isRecoveryInteractionLocked)

                            HStack {
                                Text("剩余可用次数：\(appModel.remainingCredits)")
                                    .font(.system(size: AppFontSize.caption, weight: .medium))
                                    .foregroundStyle(AppTextColor.secondary)
                                Spacer()
                                Text("生成后自动保存到回忆")
                                    .font(.system(size: AppFontSize.caption))
                                    .foregroundStyle(AppTextColor.subtle)
                            }
                        }
                        .padding(AppSpacing.xLarge)
                        .background(
                            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                                .fill(Color.white)
                        )
                        .appCardShadow()
                    }
                }
            }
            .padding(AppSpacing.xLarge)
            .padding(.bottom, 120)
        }
        .task(id: selectedItem) {
            await loadSelectedPhoto()
        }
        .task {
            startPendingRecoveryTaskIfNeeded(isInitialAttempt: true)
        }
        .photosPicker(
            isPresented: $isShowingPhotoPicker,
            selection: $selectedItem,
            matching: .images,
            photoLibrary: .shared()
        )
        .background(Color(.systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            startPendingRecoveryTaskIfNeeded()
        }
        .onChange(of: displayedMemory?.id) { _, _ in
            if displayedMemory != nil {
                errorMessage = nil
            }
        }
        .sheet(isPresented: $isShowingPurchaseSheet) {
            PurchaseSheet()
                .environmentObject(appModel)
        }
        .alert("可用生成次数不足，是否购买", isPresented: $isShowingPurchasePrompt) {
            Button("取消", role: .cancel) { }
            Button("购买") {
                isShowingPurchaseSheet = true
            }
        }
    }

    private var newLearningHero: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1.00, green: 0.96, blue: 0.89),
                            Color(red: 0.95, green: 0.98, blue: 0.92)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: AppSpacing.large) {
                VStack(alignment: .leading, spacing: AppSpacing.medium) {
                    Text("新的")
                        .font(.system(size: AppFontSize.sectionLabel, weight: .bold))
                        .foregroundStyle(Color(red: 0.98, green: 0.65, blue: 0.00))

                    Text("把今天拍到的画面变成可学习的英语表达")
                        .font(.system(size: heroTitleFontSize, weight: .bold))
                        .foregroundStyle(AppTextColor.primary)
                        .lineSpacing(4)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 128)
            }
            .padding(AppSpacing.xLarge)

            Image("NewLearningHero")
                .resizable()
                .scaledToFit()
                .frame(width: 132, height: 118)
                .padding(.top, AppSpacing.xLarge)
                .padding(.trailing, AppSpacing.xLarge)
        }
        .appHeroShadow()
    }

    private var uploadCard: some View {
        ZStack(alignment: .topTrailing) {
            if let selectedImageData,
               let image = UIImage(data: selectedImageData) {
                ZStack {
                    Color(red: 0.95, green: 0.94, blue: 0.91)

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isGenerating {
                        GeneratingImageOverlay()
                    }
                }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(AppImageAspectRatio.clamped(size: image.size), contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))

                Button {
                    removeSelectedPhoto()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color(red: 0.98, green: 0.65, blue: 0.00))
                        .frame(width: 44, height: 44)
                        .background(Color(red: 0.98, green: 0.95, blue: 0.91), in: Circle())
                        .appCardShadow()
                }
                .padding(.top, AppSpacing.medium)
                .padding(.trailing, AppSpacing.medium)
                .disabled(isGenerating || isRecoveryInteractionLocked)
                .opacity(isGenerating || isRecoveryInteractionLocked ? 0.45 : 1)
            } else if isLoadingSelectedPhoto {
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .frame(height: 266)
                    .overlay {
                        VStack(spacing: AppSpacing.large) {
                            ThinkingIndicator()
                                .scaleEffect(1.15)

                            Text("正在读取照片...")
                                .font(.system(size: AppFontSize.field, weight: .semibold))
                                .foregroundStyle(Color(red: 0.98, green: 0.65, blue: 0.00))
                        }
                        .padding(.horizontal, AppSpacing.section)
                    }
                    .appCardShadow()
            } else {
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .frame(height: 266)
                    .overlay {
                        RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [7]))
                            .foregroundStyle(Color(red: 0.92, green: 0.66, blue: 0.49))
                    }
                    .overlay {
                        VStack(spacing: AppSpacing.xLarge) {
                            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                .fill(Color(red: 0.98, green: 0.95, blue: 0.91))
                                .frame(width: 108, height: 104)
                                .overlay {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: AppFontSize.pageTitle, weight: .medium))
                                        .foregroundStyle(Color(red: 0.98, green: 0.65, blue: 0.00))
                                }

                            VStack(spacing: AppSpacing.small) {
                                Text("点击上传照片")
                                    .font(.system(size: AppFontSize.field, weight: .semibold))
                                    .foregroundStyle(Color(red: 0.98, green: 0.65, blue: 0.00))
                            }
                        }
                        .padding(.horizontal, AppSpacing.section)
                    }
                    .appCardShadow()
            }
        }
    }

    @ViewBuilder
    private var agreementHint: some View {
        if let termsOfServiceURL = AppLinks.termsOfService,
           let privacyPolicyURL = AppLinks.privacyPolicy {
            Text(.init("使用本应用即表示你同意《[用户服务协议](\(termsOfServiceURL.absoluteString))》和《[隐私政策](\(privacyPolicyURL.absoluteString))》"))
                .font(.system(size: AppFontSize.metadata))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            Text("使用本应用即表示你同意《用户服务协议》和《隐私政策》")
                .font(.system(size: AppFontSize.metadata))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func loadSelectedPhoto() async {
        guard let selectedItem else {
            photoLoadRequestID = UUID()
            isLoadingSelectedPhoto = false
            return
        }

        let loadRequestID = UUID()
        photoLoadRequestID = loadRequestID
        isLoadingSelectedPhoto = true
        defer {
            if photoLoadRequestID == loadRequestID {
                isLoadingSelectedPhoto = false
            }
        }

        do {
            guard let data = try await selectedItem.loadTransferable(type: Data.self) else {
                guard photoLoadRequestID == loadRequestID else { return }
                errorMessage = "无法读取这张图片。"
                return
            }

            guard photoLoadRequestID == loadRequestID else { return }

            let itemIdentifier = selectedItem.itemIdentifier
            let isNewSelection: Bool
            if shouldClearGeneratedMemoryOnNextPhotoSelection {
                isNewSelection = true
            } else if let itemIdentifier {
                isNewSelection = appModel.draftLearningItemIdentifier != itemIdentifier
            } else {
                isNewSelection = appModel.draftLearningImageData != data
            }

            shouldClearGeneratedMemoryOnNextPhotoSelection = false
            appModel.draftLearningItemIdentifier = itemIdentifier
            appModel.draftLearningImageData = data
            if isNewSelection {
                stopPendingRecoveryUI()
                appModel.draftGeneratedMemory = nil
                appModel.draftGeneratedMemoryID = nil
            }
            errorMessage = nil
        } catch {
            guard photoLoadRequestID == loadRequestID else { return }
            errorMessage = "读取图片失败，请重试。"
        }
    }

    private func generateSentences() async {
        guard let selectedImageData, !isRecoveryInteractionLocked else { return }

        isGenerating = true
        isWaitingForRecoveredGeneration = true
        generationStep = 0
        generationStatus = generationSteps[0]
        errorMessage = nil
        resetRecoveryCancelButtonVisibility()
        appModel.draftGeneratedMemory = nil
        appModel.draftGeneratedMemoryID = nil

        let statusTask = Task {
            for index in 1..<generationSteps.count {
                try? await Task.sleep(for: generationStepDisplayDuration)
                if Task.isCancelled { return }
                await MainActor.run {
                    if isGenerating {
                        generationStep = index
                        generationStatus = generationSteps[index]
                    }
                }
            }
        }

        do {
            let memory = try await appModel.generateMemory(from: selectedImageData)
            statusTask.cancel()
            appModel.draftGeneratedMemory = memory
            isWaitingForRecoveredGeneration = false
            resetRecoveryCancelButtonVisibility()
        } catch {
            let localizedError = error.localizedDescription
            if !isTransientGenerationError(localizedError) {
                statusTask.cancel()
                appModel.clearPendingGeneratedMemoryImage()
                errorMessage = localizedError
                isWaitingForRecoveredGeneration = false
                resetRecoveryCancelButtonVisibility()
            } else {
                statusTask.cancel()
                startPendingRecoveryTaskIfNeeded()
            }
        }

        isGenerating = false
        generationStep = 0
        generationStatus = generationSteps[0]
    }

    private func removeSelectedPhoto() {
        guard !isRecoveryInteractionLocked else { return }
        selectedItem = nil
        isLoadingSelectedPhoto = false
        shouldClearGeneratedMemoryOnNextPhotoSelection = false
        isWaitingForRecoveredGeneration = false
        appModel.clearLearningDraft()
        errorMessage = nil
        generationStep = 0
        generationStatus = generationSteps[0]
    }

    private func cancelPendingRecovery() {
        stopPendingRecoveryUI()
        selectedItem = nil
        isLoadingSelectedPhoto = false
        shouldClearGeneratedMemoryOnNextPhotoSelection = false
        appModel.clearLearningDraft()
        appModel.clearPendingGeneratedMemoryImage()
    }

    private func stopPendingRecoveryUI() {
        activePendingRecoveryTask?.cancel()
        activePendingRecoveryTask = nil
        selectedItem = nil
        isWaitingForRecoveredGeneration = false
        errorMessage = nil
        generationStep = 0
        generationStatus = generationSteps[0]
        resetRecoveryCancelButtonVisibility()
    }

    private var generationSteps: [String] {
        [
            "正在观察图片...",
            "正在理解画面...",
            "正在组织表达...",
            "正在检查翻译...",
            "正在完成最后整理..."
        ]
    }

    private var displayedMemory: MemoryEntry? {
        if let memoryID = appModel.draftGeneratedMemoryID,
           let persistedMemory = appModel.memory(withID: memoryID) {
            return persistedMemory
        }

        if let draftGeneratedMemory = appModel.draftGeneratedMemory {
            return draftGeneratedMemory
        }

        return nil
    }

    private var selectedImageData: Data? {
        appModel.draftLearningImageData
    }

    private var shouldShowRecoveryLoadingState: Bool {
        guard !isGenerating,
              isWaitingForRecoveredGeneration,
              selectedImageData != nil,
              displayedMemory == nil,
              let errorMessage else {
            return false
        }

        return isTransientGenerationError(errorMessage)
    }

    private var shouldShowPendingRecoveryLoadingState: Bool {
        !isGenerating &&
            isWaitingForRecoveredGeneration &&
            selectedImageData != nil &&
            displayedMemory == nil &&
            errorMessage == nil
    }

    private var isRecoveryInteractionLocked: Bool {
        shouldShowRecoveryLoadingState || shouldShowPendingRecoveryLoadingState
    }

    private var shouldHideActionsForRecoveryFailure: Bool {
        selectedImageData != nil &&
            displayedMemory == nil &&
            errorMessage == recoveryResultUnavailableMessage
    }

    private func scheduleRecoveryCancelButtonReveal() {
        recoveryCancelButtonRevealTask?.cancel()
        isRecoveryCancelButtonVisible = false
        recoveryCancelButtonRevealTask = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if shouldShowPendingRecoveryLoadingState {
                    isRecoveryCancelButtonVisible = true
                }
            }
        }
    }

    private func showRecoveryCancelButton() {
        recoveryCancelButtonRevealTask?.cancel()
        isRecoveryCancelButtonVisible = true
    }

    private func resetRecoveryCancelButtonVisibility() {
        recoveryCancelButtonRevealTask?.cancel()
        recoveryCancelButtonRevealTask = nil
        isRecoveryCancelButtonVisible = false
    }

    private func startPendingRecoveryTaskIfNeeded(isInitialAttempt: Bool = false) {
        if isInitialAttempt {
            guard !hasAttemptedPendingRecovery else { return }
            hasAttemptedPendingRecovery = true
        }

        guard activePendingRecoveryTask == nil else { return }
        guard let pendingGeneratedMemoryImage = appModel.pendingGeneratedMemoryImage else { return }
        guard displayedMemory == nil else { return }
        guard !appModel.isPendingGeneratedRecoveryExpired(pendingGeneratedMemoryImage) else {
            appModel.clearPendingGeneratedMemoryImage()
            return
        }

        if selectedImageData == nil {
            appModel.draftLearningImageData = pendingGeneratedMemoryImage.imageData
        }
        appModel.draftGeneratedMemory = nil
        appModel.draftGeneratedMemoryID = nil
        isWaitingForRecoveredGeneration = true
        errorMessage = nil
        scheduleRecoveryCancelButtonReveal()

        activePendingRecoveryTask = Task {
            let recoveredMemory = await appModel.resumePendingGeneratedMemoryRecoveryIfNeeded()
            if Task.isCancelled {
                return
            }

            await MainActor.run {
                activePendingRecoveryTask = nil
                if let recoveredMemory {
                    appModel.draftGeneratedMemory = recoveredMemory
                    appModel.draftGeneratedMemoryID = recoveredMemory.id
                    appModel.clearPendingGeneratedMemoryImage()
                    errorMessage = nil
                    isWaitingForRecoveredGeneration = false
                    resetRecoveryCancelButtonVisibility()
                    return
                }

                isWaitingForRecoveredGeneration = false
                resetRecoveryCancelButtonVisibility()
                errorMessage = recoveryResultUnavailableMessage
            }
        }
    }

    private func isTransientGenerationError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("网关") ||
            normalized.contains("gateway") ||
            normalized.contains("timeout") ||
            normalized.contains("timed out")
    }
}

private struct NewLearningResultPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NewLearningSentenceList: View {
    let memory: MemoryEntry

    var body: some View {
        VStack(spacing: 10) {
            ForEach(memory.sentences) { sentence in
                MemoryDetailSentenceRow(sentence: sentence)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
            }
        }
    }
}

private struct GeneratingImageOverlay: View {
    private let cellSize: CGFloat = 28

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: false)) { context in
            Canvas { canvas, size in
                let columns = max(Int(size.width / cellSize), 1)
                let rows = max(Int(size.height / cellSize), 1)
                let step = cellSize

                canvas.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(Color.black.opacity(0.12))
                )

                var grid = Path()
                for column in 0...columns {
                    let x = CGFloat(column) * step
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                }

                for row in 0...rows {
                    let y = CGFloat(row) * step
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }

                canvas.stroke(grid, with: .color(Color.white.opacity(0.16)), lineWidth: 0.8)

                let time = context.date.timeIntervalSinceReferenceDate
                for row in 0...rows {
                    for column in 0...columns {
                        let phase = Double(row * 13 + column * 7) * 0.42
                        let pulse = (sin(time * 1.8 + phase) + 1) / 2
                        let intensity = pow(pulse, 3.8)
                        guard intensity > 0.42 else { continue }

                        let point = CGPoint(
                            x: CGFloat(column) * step,
                            y: CGFloat(row) * step
                        )
                        let glowRadius = 1.1 + intensity * 1.4
                        let glowRect = CGRect(
                            x: point.x - glowRadius,
                            y: point.y - glowRadius,
                            width: glowRadius * 2,
                            height: glowRadius * 2
                        )
                        canvas.fill(
                            Path(ellipseIn: glowRect),
                            with: .color(Color.white.opacity(0.10 + intensity * 0.28))
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
