import SwiftUI
import UIKit

struct MemoryDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    let memoryID: UUID
    @State private var currentMemoryID: UUID
    @State private var isShowingDeleteAlert = false
    @State private var isSavingToPhotos = false
    @State private var saveResultMessage: String?
    @State private var saveResultIsSuccess = false
    @State private var saveResultTask: Task<Void, Never>?

    init(memoryID: UUID) {
        self.memoryID = memoryID
        _currentMemoryID = State(initialValue: memoryID)
    }

    var body: some View {
        Group {
            if let memory = appModel.memory(withID: currentMemoryID) {
                ZStack(alignment: .bottom) {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: AppSpacing.large) {
                            MemoryDetailImageView(imageData: memory.imageData)

                            MemoryDetailSentencePanel(memory: memory)
                                .padding(.bottom, 88)
                        }
                        .padding(.horizontal, AppSpacing.xLarge)
                        .padding(.top, 24)
                        .padding(.bottom, 24)
                    }

                    MemoryDetailPagerControls(
                        canGoPrevious: previousMemoryID(for: memory.id) != nil,
                        canGoNext: nextMemoryID(for: memory.id) != nil,
                        onPrevious: {
                            if let previousID = previousMemoryID(for: memory.id) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    currentMemoryID = previousID
                                }
                            }
                        },
                        onNext: {
                            if let nextID = nextMemoryID(for: memory.id) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    currentMemoryID = nextID
                                }
                            }
                        }
                    )
                    .padding(.horizontal, AppSpacing.xLarge)
                    .padding(.bottom, 26)

                    if let saveResultMessage {
                        SaveResultHUD(message: saveResultMessage, isSuccess: saveResultIsSuccess)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                }
                .background(Color(.systemGroupedBackground))
                .toolbar(.hidden, for: .tabBar)
                .navigationTitle(L10n.string("memory_detail.title", "详情"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                saveMemoryToPhotos(memory)
                            } label: {
                                Label(L10n.string("memory_detail.save_to_photos", "保存到本地"), systemImage: "square.and.arrow.down")
                            }
                            .disabled(isSavingToPhotos)

                            Button(role: .destructive) {
                                isShowingDeleteAlert = true
                            } label: {
                                Label(L10n.string("common.delete", "删除"), systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(AppTextColor.primary)
                        }
                    }
                }
                .alert(L10n.string("memory.delete.alert_title", "删除这条回忆？"), isPresented: $isShowingDeleteAlert) {
                    Button(L10n.string("common.delete", "删除"), role: .destructive) {
                        appModel.deleteMemory(memoryID: memory.id)
                        dismiss()
                    }
                    Button(L10n.string("common.cancel", "取消"), role: .cancel) { }
                } message: {
                    Text(L10n.string("memory.delete.alert_message", "删除后，这张图片和对应的三句话都会被移除。"))
                }
                .task(id: currentMemoryID) {
                    await appModel.ensureMemoryImageLoaded(memoryID: currentMemoryID)
                }
            } else {
                EmptyStateView(
                    title: L10n.string("memory_detail.missing.title", "内容不存在"),
                    subtitle: L10n.string("memory_detail.missing.subtitle", "这条历史记录可能已被删除。")
                )
            }
        }
    }

    private func orderedMemories() -> [MemoryEntry] {
        appModel.memories.sorted { $0.createdAt > $1.createdAt }
    }

    private func previousMemoryID(for currentID: UUID) -> UUID? {
        let memories = orderedMemories()
        guard let index = memories.firstIndex(where: { $0.id == currentID }),
              index > 0 else {
            return nil
        }
        return memories[index - 1].id
    }

    private func nextMemoryID(for currentID: UUID) -> UUID? {
        let memories = orderedMemories()
        guard let index = memories.firstIndex(where: { $0.id == currentID }),
              index < memories.count - 1 else {
            return nil
        }
        return memories[index + 1].id
    }

    private func saveMemoryToPhotos(_ memory: MemoryEntry) {
        guard !isSavingToPhotos else { return }
        isSavingToPhotos = true

        Task { @MainActor in
            guard let image = MemoryExportRenderer.render(memory: memory, displayScale: displayScale) else {
                isSavingToPhotos = false
                showSaveResult(L10n.string("memory_detail.save_failed", "保存失败，请稍后重试。"), isSuccess: false)
                return
            }

            PhotoLibrarySaver.save(image: image) { error in
                Task { @MainActor in
                    isSavingToPhotos = false
                    showSaveResult(
                        error == nil
                        ? L10n.string("memory_detail.save_succeeded", "已保存到系统相册。")
                        : L10n.string("memory_detail.save_permission_failed", "保存失败，请检查相册权限后重试。"),
                        isSuccess: error == nil
                    )
                }
            }
        }
    }

    @MainActor
    private func showSaveResult(_ message: String, isSuccess: Bool) {
        saveResultTask?.cancel()
        saveResultIsSuccess = isSuccess
        withAnimation(.spring(response: 0.26, dampingFraction: 0.92)) {
            saveResultMessage = message
        }

        saveResultTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    saveResultMessage = nil
                }
            }
        }
    }
}

private struct MemoryDetailImageView: View {
    let imageData: Data

    private var image: UIImage? {
        UIImage(data: imageData)
    }

    private var displayAspectRatio: CGFloat {
        guard let image else {
            return AppImageAspectRatio.defaultDisplay
        }

        return AppImageAspectRatio.clamped(size: image.size)
    }

    var body: some View {
        ZStack {
            Color(red: 0.95, green: 0.94, blue: 0.91)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MemoryDetailImageSkeleton()
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(displayAspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
    }
}
