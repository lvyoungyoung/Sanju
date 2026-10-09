import Foundation

enum L10n {
    nonisolated static func string(_ key: String, _ fallback: String, tableName: String) -> String {
        NSLocalizedString(key, tableName: tableName, bundle: .main, value: fallback, comment: "")
    }

    nonisolated static func string(_ key: String, _ fallback: String, _ arguments: CVarArg...) -> String {
        let format = NSLocalizedString(key, tableName: nil, bundle: .main, value: fallback, comment: "")
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}
