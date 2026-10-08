import SwiftUI
import Combine

@MainActor
final class StudyMatchSettingsEditor: ObservableObject {
    nonisolated deinit {}

    @Published var position: Double
    @Published private(set) var settings: StudySceneMatchSettings
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?
    private let save: (Double) async throws -> StudySceneMatchSettings
    private let didSave: () async -> Void

    init(settings: StudySceneMatchSettings,
         save: @escaping (Double) async throws -> StudySceneMatchSettings,
         didSave: @escaping () async -> Void) {
        self.settings = settings
        self.position = Double(StudyMatchRange.index(for: settings.threshold))
        self.save = save
        self.didSave = didSave
    }

    func saveDraft() async {
        let threshold = StudyMatchRange.threshold(at: position)
        guard settings.canAdjust, !isSaving, threshold != settings.threshold else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            settings = try await save(threshold)
            position = Double(StudyMatchRange.index(for: settings.threshold))
            await didSave()
        } catch {
            position = Double(StudyMatchRange.index(for: settings.threshold))
            if !(error is CancellationError) {
                errorMessage = L10n.string("study.match.save_failed", "暂时无法更新匹配范围，请检查网络后重试。")
            }
        }
    }
}

struct StudyMatchSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var editor: StudyMatchSettingsEditor
    @State private var isDragging = false
    @State private var pendingSave: Task<Void, Never>?

    init(settings: StudySceneMatchSettings,
         save: @escaping (Double) async throws -> StudySceneMatchSettings,
         didSave: @escaping () async -> Void) {
        _editor = StateObject(wrappedValue: StudyMatchSettingsEditor(settings: settings, save: save, didSave: didSave))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xLarge) {
                    VStack(spacing: AppSpacing.medium) {
                        HStack(alignment: .top) {
                            Text(L10n.string("study.match.strict", "严格"))
                            Spacer(minLength: AppSpacing.large)
                            Text(L10n.string("study.match.broad", "宽松"))
                                .multilineTextAlignment(.trailing)
                        }
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTextColor.primary)

                        StudyMatchRangeSlider(position: $editor.position) { editing in
                            isDragging = editing
                            if editing { pendingSave?.cancel() } else { scheduleSave() }
                        }
                        .disabled(editor.isSaving)
                        .accessibilityLabel(L10n.string("study.match.title", "匹配范围"))
                        .accessibilityValue(L10n.string("study.match.accessibility_level", "第 %d 档，共 7 档；档位越高，范围越宽", Int(editor.position) + 1))

                    }
                    .padding(AppSpacing.large)
                    .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    if let error = editor.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(AppSpacing.section)
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: AppSpacing.small) {
                    if editor.isSaving { ProgressView().controlSize(.small) }
                    Text(editor.isSaving
                         ? L10n.string("study.match.updating", "正在更新匹配结果…")
                         : L10n.string("study.match.count", "匹配到 %d 个句子", editor.settings.matchedCount))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(AppTextColor.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, AppSpacing.section)
                .padding(.bottom, AppSpacing.medium)
                .background(AppSurfaceColor.page)
            }
            .background(AppSurfaceColor.page)
            .navigationTitle(L10n.string("study.match.title", "匹配范围"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("study.match.done", "完成")) { dismiss() }
                        .disabled(editor.isSaving || pendingSave != nil)
                }
            }
        }
        .presentationDetents([.height(320), .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(editor.isSaving || pendingSave != nil)
        .onChange(of: editor.position) { _, _ in
            if !isDragging && !editor.isSaving { scheduleSave() }
        }
        .onDisappear {
            if !editor.isSaving { pendingSave?.cancel() }
        }
    }

    private func scheduleSave() {
        guard !editor.isSaving else { return }
        pendingSave?.cancel()
        pendingSave = Task {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled, !isDragging else { return }
            await editor.saveDraft()
            pendingSave = nil
        }
    }
}

private struct StudyMatchRangeSlider: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var position: Double
    var onEditingChanged: (Bool) -> Void
    @State private var isDragging = false
    @State private var dragPosition: Double?

    private let thumbSize: CGFloat = 32
    private var lastIndex: Double { Double(StudyMatchRange.thresholds.count - 1) }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - thumbSize)
            let progress = min(lastIndex, max(0, dragPosition ?? position)) / lastIndex
            let offset = width * progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppPalette.accentText.opacity(0.12))
                    .frame(height: 12)
                Capsule()
                    .fill(AppPalette.accentText.gradient)
                    .frame(width: offset + thumbSize / 2, height: 12)
                HStack(spacing: 0) {
                    ForEach(0..<StudyMatchRange.thresholds.count, id: \.self) { index in
                        Circle()
                            .fill(AppPalette.accentText.opacity(0.35))
                            .frame(width: 4, height: 4)
                        if index < StudyMatchRange.thresholds.count - 1 { Spacer(minLength: 0) }
                    }
                }
                .padding(.horizontal, thumbSize / 2 - 2)
                Circle()
                    .fill(AppSurfaceColor.card)
                    .overlay {
                        Circle().fill(AppPalette.accentText).frame(width: 10, height: 10)
                    }
                    .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
                    .frame(width: thumbSize, height: thumbSize)
                    .scaleEffect(isDragging ? 1.15 : 1)
                    .offset(x: offset)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled else { return }
                        if !isDragging {
                            onEditingChanged(true)
                            isDragging = true
                        }
                        let value = min(lastIndex, max(0, Double((value.location.x - thumbSize / 2) / width) * lastIndex))
                        dragPosition = value
                        position = value.rounded()
                    }
                    .onEnded { _ in
                        guard isDragging else { return }
                        isDragging = false
                        dragPosition = nil
                        onEditingChanged(false)
                    }
            )
            .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: isDragging)
        }
        .frame(height: 52)
        .opacity(isEnabled ? 1 : 0.5)
        .sensoryFeedback(.selection, trigger: position) { _, _ in isDragging }
        .accessibilityElement(children: .ignore)
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: position = min(lastIndex, position + 1)
            case .decrement: position = max(0, position - 1)
            @unknown default: break
            }
        }
    }
}
