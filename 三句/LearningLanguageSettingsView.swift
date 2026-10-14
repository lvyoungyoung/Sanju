import SwiftUI

struct LearningLanguageSettingsView: View {
    var isInitialSetup = false
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var interfaceLanguage = InterfaceLanguageStore.shared
    @State private var support: SupportLanguage = .simplifiedChinese
    @State private var target: LearningLanguage?
    @State private var error: String?
    @State private var isLoadingCapabilities = true

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.string("language.interface", "界面语言")) {
                    Picker(L10n.string("language.interface", "界面语言"), selection: Binding(
                        get: { interfaceLanguage.selection }, set: { interfaceLanguage.select($0) }
                    )) {
                        ForEach(InterfaceLanguage.allCases) { Text($0.displayTitle).tag($0) }
                    }
                }
                Section(L10n.string("language.support", "翻译与讲解语言")) {
                    Picker(L10n.string("language.support", "翻译与讲解语言"), selection: $support) {
                        ForEach(SupportLanguage.allCases) { Text($0.displayTitle).tag($0) }
                    }
                }
                Section {
                    if isLoadingCapabilities { ProgressView().frame(maxWidth: .infinity) }
                    ForEach(LanguageCatalog.targets(for: support)) { language in
                        let selection = try? LearningSelection.standard(target: language, support: support)
                        let available = selection.map { appModel.languageCapabilities.permits($0) } ?? false
                        Button {
                            target = language
                        } label: {
                            HStack {
                                Text(language.displayTitle)
                                Spacer()
                                if !available && !isLoadingCapabilities {
                                    Text(L10n.string("language.not_open", "暂未开放")).font(.caption).foregroundStyle(.secondary)
                                } else if target == language {
                                    Image(systemName: "checkmark").foregroundStyle(AppPalette.accent)
                                }
                            }
                        }
                        .disabled(!available)
                        .foregroundStyle(AppTextColor.primary)
                    }
                    if !isLoadingCapabilities && appModel.languageCapabilities.combinations.isEmpty {
                        Button(L10n.string("language.retry_availability", "无法获取可用语言，点击重试")) {
                            Task { await loadCapabilities() }
                        }
                    }
                } header: {
                    Text(L10n.string("language.target", "学习语言"))
                } footer: {
                    Text(L10n.string("language.future_only", "只影响之后生成的内容，不会改写已有照片的句子与翻译。"))
                }
                if support == .japanese || target == .japanese {
                    Toggle(L10n.string("language.readings", "显示日语假名"), isOn: Binding(
                        get: { appModel.showsJapaneseReadings }, set: { appModel.showsJapaneseReadings = $0 }
                    ))
                }
                if let error { Text(error).foregroundStyle(.red) }
                if let message = appModel.languagePreferenceError { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle(L10n.string("language.settings", "语言设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isInitialSetup ? L10n.string("common.later", "稍后设置") : L10n.string("common.cancel", "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("common.save", "保存")) { save() }.disabled(!canSave)
                }
            }
            .task {
                support = isInitialSetup
                    ? (InterfaceLanguageStore.resolvedCode == "en" ? .english : .simplifiedChinese)
                    : (appModel.learningSelection.mode == .legacyEnglish ? .simplifiedChinese : appModel.explanationLanguage)
                target = isInitialSetup ? nil : appModel.learningSelection.targetLanguage
                await loadCapabilities()
            }
            .onChange(of: support) { _, newValue in
                if let target, !LanguageCatalog.supportsGeneration(target: target, support: newValue) { self.target = nil }
            }
        }
        .tint(AppPalette.accentText)
        .environment(\.locale, interfaceLanguage.locale)
    }

    private func save() {
        guard let target else { return }
        do {
            try appModel.selectLearningLanguage(.standard(target: target, support: support))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private var canSave: Bool {
        guard !isLoadingCapabilities, let target,
              let selection = try? LearningSelection.standard(target: target, support: support) else { return false }
        return appModel.languageCapabilities.permits(selection)
    }

    private func loadCapabilities() async {
        isLoadingCapabilities = true
        await appModel.refreshLanguageCapabilities()
        isLoadingCapabilities = false
    }
}
