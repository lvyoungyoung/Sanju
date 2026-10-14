import Combine
import Foundation
import WidgetKit

@MainActor
final class InterfaceLanguageStore: ObservableObject {
    static let shared = InterfaceLanguageStore()
    nonisolated static let preferenceKey = "sanju.interface.language.v1"
    nonisolated static let widgetLocaleKey = "sanju.interface.resolved-language.v1"
    @Published private(set) var selection: InterfaceLanguage
    @Published private(set) var resolvedLanguageCode: String
    private let defaults: UserDefaults
    private let sharedDefaults: UserDefaults?
    private let preferredLanguages: () -> [String]
    private let reloadWidgets: () -> Void
    var locale: Locale { Locale(identifier: resolvedLanguageCode) }

    init(defaults: UserDefaults = .standard,
         sharedDefaults: UserDefaults? = UserDefaults(suiteName: MemoryWidgetSnapshotStore.appGroupID),
         preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages },
         reloadWidgets: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: MemoryWidgetSnapshotStore.widgetKind) }) {
        self.defaults = defaults
        self.sharedDefaults = sharedDefaults
        self.preferredLanguages = preferredLanguages
        self.reloadWidgets = reloadWidgets
        let initialSelection = InterfaceLanguage(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .system
        selection = initialSelection
        resolvedLanguageCode = Self.resolve(initialSelection, preferredLanguages: preferredLanguages())
        syncWidgetLocale()
    }
    func select(_ value: InterfaceLanguage) {
        defaults.set(value.rawValue, forKey: Self.preferenceKey)
        selection = value
        syncWidgetLocale()
    }

    func syncWidgetLocale() {
        let code = Self.resolve(selection, preferredLanguages: preferredLanguages())
        if resolvedLanguageCode != code { resolvedLanguageCode = code }
        guard let sharedDefaults else { return }
        guard sharedDefaults.string(forKey: Self.widgetLocaleKey) != code ||
                sharedDefaults.string(forKey: Self.preferenceKey) != selection.rawValue else { return }
        sharedDefaults.set(selection.rawValue, forKey: Self.preferenceKey)
        sharedDefaults.set(code, forKey: Self.widgetLocaleKey)
        reloadWidgets()
    }
    nonisolated static var resolvedCode: String {
        let selection = InterfaceLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .system
        return resolve(selection, preferredLanguages: Locale.preferredLanguages)
    }
    nonisolated static func resolve(_ selection: InterfaceLanguage, preferredLanguages: [String]) -> String {
        switch selection {
        case .simplifiedChinese: return "zh-Hans"
        case .english: return "en"
        case .system:
            let preferred = preferredLanguages.first ?? "en"
            return preferred == "zh" || preferred.hasPrefix("zh-Hans") || preferred.hasPrefix("zh-CN") || preferred.hasPrefix("zh-SG") ? "zh-Hans" : "en"
        }
    }
    nonisolated static var bundle: Bundle {
        bundle(for: resolvedCode)
    }
    nonisolated static func bundle(for languageCode: String) -> Bundle {
        guard let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"), let bundle = Bundle(path: path) else { return .main }
        return bundle
    }
}
