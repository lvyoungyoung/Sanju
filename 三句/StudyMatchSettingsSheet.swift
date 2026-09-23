import SwiftUI
import Combine

@MainActor
final class StudyMatchSettingsEditor: ObservableObject {
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
                    Text(L10n.string("study.match.explanation", "范围越宽，句子可能越多，但与主题的关联也可能更弱。"))
                        .font(.subheadline)
                        .foregroundStyle(AppTextColor.secondary)

                    VStack(spacing: AppSpacing.medium) {
                        HStack(alignment: .top) {
                            Text(L10n.string("study.match.strict", "更贴合主题"))
                            Spacer(minLength: AppSpacing.large)
                            Text(L10n.string("study.match.broad", "包含更多相关句子"))
                                .multilineTextAlignment(.trailing)
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTextColor.primary)

                        Slider(value: $editor.position, in: 0...6, step: 1) { editing in
                            isDragging = editing
                            if editing { pendingSave?.cancel() } else { scheduleSave() }
                        }
                        .tint(AppPalette.accentText)
                        .disabled(editor.isSaving)
                        .accessibilityLabel(L10n.string("study.match.title", "匹配范围"))
                        .accessibilityValue(L10n.string("study.match.accessibility_level", "第 %d 档，共 7 档；档位越高，范围越宽", Int(editor.position) + 1))

                        Text(Int(editor.position) == StudyMatchRange.defaultIndex
                             ? L10n.string("study.match.default", "默认范围")
                             : L10n.string("study.match.custom", "自定义范围"))
                            .font(.caption)
                            .foregroundStyle(AppTextColor.secondary)
                    }
                    .padding(AppSpacing.large)
                    .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    HStack(spacing: AppSpacing.small) {
                        if editor.isSaving { ProgressView().controlSize(.small) }
                        Text(editor.isSaving
                             ? L10n.string("study.match.updating", "正在更新匹配结果…")
                             : L10n.string("study.match.count", "匹配到 %d 个句子", editor.settings.matchedCount))
                            .font(.subheadline)
                            .foregroundStyle(AppTextColor.secondary)
                        Spacer()
                        Button(L10n.string("study.match.reset", "恢复默认")) {
                            editor.position = Double(StudyMatchRange.defaultIndex)
                            scheduleSave()
                        }
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 44)
                        .disabled(editor.isSaving || editor.settings.threshold == 0.42 && editor.position == 3)
                    }
                    .frame(minHeight: 44)

                    if let error = editor.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(AppSpacing.section)
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
        .presentationDetents([.height(390), .large])
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
