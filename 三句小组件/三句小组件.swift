import AppIntents
import SwiftUI
import UIKit
import WidgetKit

enum WidgetInterfaceLanguage {
    static var resolvedCode: String {
        let shared = UserDefaults(suiteName: WidgetSnapshotStore.appGroupID)
        if let code = shared?.string(forKey: "sanju.interface.resolved-language.v1"), ["zh-Hans", "en"].contains(code) {
            return code
        }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred == "zh" || preferred.hasPrefix("zh-Hans") || preferred.hasPrefix("zh-CN") || preferred.hasPrefix("zh-SG") ? "zh-Hans" : "en"
    }

    static func string(_ key: String) -> String {
        let bundle = Bundle.main.path(forResource: resolvedCode, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}

enum WidgetSnapshotStore {
    static let appGroupID = "group.com.yanglv.sanju"
    static let widgetKind = "SanjuMemoryWidget"
    static let snapshotFileName = "memory-widget-snapshot.json"
    static let imageDirectoryName = "memory-widget-images"

    struct Snapshot: Decodable {
        let generatedAt: Date
        let items: [Item]

        private enum CodingKeys: String, CodingKey { case schemaVersion, generatedAt, items }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            guard [1, 2].contains(version) else {
                throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c, debugDescription: "Unsupported snapshot version")
            }
            generatedAt = try c.decode(Date.self, forKey: .generatedAt)
            items = try c.decode([Item].self, forKey: .items)
        }
    }

    struct Item: Decodable, Hashable {
        let id: String
        let memoryID: String
        let createdAt: Date
        let targetText: String
        let translationText: String
        let targetLanguage: String
        let translationLanguage: String
        let teachingLocale: String
        let imageFileName: String?

        init(id: String, memoryID: String, createdAt: Date, english: String, chinese: String, imageFileName: String?) {
            self.id = id; self.memoryID = memoryID; self.createdAt = createdAt
            targetText = english; translationText = chinese
            targetLanguage = "en"; translationLanguage = "zh-Hans"; teachingLocale = "en-US"
            self.imageFileName = imageFileName
        }

        private enum CodingKeys: String, CodingKey {
            case id, memoryID, createdAt, english, chinese, targetText, translationText
            case targetLanguage, translationLanguage, teachingLocale, imageFileName
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            memoryID = try c.decode(String.self, forKey: .memoryID)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            imageFileName = try c.decodeIfPresent(String.self, forKey: .imageFileName)
            if [.targetText, .translationText, .targetLanguage, .translationLanguage, .teachingLocale].contains(where: c.contains) {
                targetText = try c.decode(String.self, forKey: .targetText)
                translationText = try c.decode(String.self, forKey: .translationText)
                targetLanguage = try c.decode(String.self, forKey: .targetLanguage)
                translationLanguage = try c.decode(String.self, forKey: .translationLanguage)
                teachingLocale = try c.decode(String.self, forKey: .teachingLocale)
                let locales = ["en": "en-US", "es": "es-419", "ja": "ja-JP", "fr": "fr-FR"]
                guard locales[targetLanguage] == teachingLocale,
                      ["zh-Hans", "en", "es", "ja", "fr"].contains(translationLanguage) else {
                    throw DecodingError.dataCorruptedError(forKey: .targetLanguage, in: c, debugDescription: "Invalid content language")
                }
            } else {
                targetText = try c.decode(String.self, forKey: .english)
                translationText = try c.decode(String.self, forKey: .chinese)
                targetLanguage = "en"; translationLanguage = "zh-Hans"; teachingLocale = "en-US"
            }
        }
    }

    static func loadSnapshot() -> Snapshot? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return nil
        }

        let snapshotURL = containerURL.appendingPathComponent(snapshotFileName)
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    static func imageURL(for item: Item) -> URL? {
        let resolvedImageFileName = item.imageFileName ?? defaultImageFileName(for: item.memoryID)
        guard !resolvedImageFileName.isEmpty else {
            return nil
        }

        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return nil
        }

        return containerURL
            .appendingPathComponent(imageDirectoryName, isDirectory: true)
            .appendingPathComponent(resolvedImageFileName)
    }

    static func hasLocalImage(for item: Item) -> Bool {
        guard let imageURL = imageURL(for: item) else { return false }
        return FileManager.default.fileExists(atPath: imageURL.path)
    }

    static func preferredItems(from snapshot: Snapshot) -> [Item] {
        let imageReadyItems = snapshot.items.filter { item in
            hasLocalImage(for: item)
        }
        return imageReadyItems.isEmpty ? snapshot.items : imageReadyItems
    }

    static func interactiveItems(from snapshot: Snapshot) -> [Item] {
        let imageReadyItems = snapshot.items.filter { item in
            hasLocalImage(for: item)
        }

        if imageReadyItems.count > 1 {
            return imageReadyItems
        }

        return snapshot.items
    }

    private static func defaultImageFileName(for memoryID: String) -> String {
        "\(memoryID.lowercased()).jpg"
    }

    static func defaultItem(
        from snapshot: Snapshot,
        date: Date
    ) -> Item {
        let candidateItems = preferredItems(from: snapshot)
        let hourSeed = Int(date.timeIntervalSince1970 / 3600)
        let index = abs(hourSeed) % candidateItems.count
        return candidateItems[index]
    }
}

enum WidgetSelectionStore {
    private static let selectionFileName = "memory-widget-selection.json"
    private static let interactionCooldown: TimeInterval = 0.9
    private static let selectionQueue = DispatchQueue(
        label: "com.yanglv.sanju.memory-widget-selection",
        qos: .userInitiated
    )

    private struct Selection: Codable {
        let selectedItemID: String?
        let expiresAt: Date?
        let lastInteractionAt: Date?
    }

    static func loadSelectedItemID(at date: Date = .now) -> String? {
        selectionQueue.sync {
            let selection = loadSelectionUnsafe()
            guard let selectedItemID = selection?.selectedItemID else {
                return nil
            }

            if let expiresAt = selection?.expiresAt,
               date >= expiresAt {
                // Timeline generation asks for future dates; do not clear today's live selection early.
                return nil
            }

            return selectedItemID
        }
    }

    private static func loadSelectionUnsafe() -> Selection? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetSnapshotStore.appGroupID
        ) else {
            return nil
        }

        let fileURL = containerURL.appendingPathComponent(selectionFileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Selection.self, from: data)
    }

    static func saveSelectedItemID(
        _ selectedItemID: String?,
        expiresAt: Date? = nil
    ) {
        selectionQueue.sync {
            saveSelectionUnsafe(
                selectedItemID.map {
                    Selection(
                        selectedItemID: $0,
                        expiresAt: expiresAt,
                        lastInteractionAt: nil
                    )
                }
            )
        }
    }

    private static func saveSelectionUnsafe(_ selection: Selection?) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetSnapshotStore.appGroupID
        ) else {
            return
        }

        let fileURL = containerURL.appendingPathComponent(selectionFileName)
        let payload = selection ?? Selection(selectedItemID: nil, expiresAt: nil, lastInteractionAt: nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        if let data = try? encoder.encode(payload) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func selectRandomItemID(from snapshot: WidgetSnapshotStore.Snapshot) -> Bool {
        let now = Date()
        return selectionQueue.sync {
            let existingSelection = loadSelectionUnsafe()
            if let lastInteractionAt = existingSelection?.lastInteractionAt,
               now.timeIntervalSince(lastInteractionAt) < interactionCooldown {
                return false
            }

            let candidateItems = WidgetSnapshotStore.interactiveItems(from: snapshot)
            guard !candidateItems.isEmpty else {
                saveSelectionUnsafe(nil)
                return true
            }

            let currentID: String
            if let selectedItemID = existingSelection?.selectedItemID,
               let expiresAt = existingSelection?.expiresAt,
               now < expiresAt,
               snapshot.items.contains(where: { $0.id == selectedItemID }) {
                currentID = selectedItemID
            } else {
                currentID = WidgetSnapshotStore.defaultItem(from: snapshot, date: now).id
            }
            let candidates = candidateItems.map(\.id).filter { $0 != currentID }
            guard let nextID = candidates.randomElement() ?? candidateItems.first?.id else {
                return false
            }

            saveSelectionUnsafe(
                Selection(
                    selectedItemID: nextID,
                    expiresAt: nextAutomaticRefreshDate(after: now),
                    lastInteractionAt: now
                )
            )
            return nextID != currentID
        }
    }

    private static func nextAutomaticRefreshDate(after date: Date) -> Date {
        Calendar.current.nextDate(
            after: date,
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? date.addingTimeInterval(3600)
    }
}

struct ShuffleMemoryIntent: AppIntent {
    static var title: LocalizedStringResource {
        LocalizedStringResource("切换随机回忆", locale: Locale(identifier: WidgetInterfaceLanguage.resolvedCode))
    }
    static var description: IntentDescription {
        IntentDescription(LocalizedStringResource("随机切换小组件里展示的回忆。", locale: Locale(identifier: WidgetInterfaceLanguage.resolvedCode)))
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        var shouldReload = true
        if let snapshot = WidgetSnapshotStore.loadSnapshot() {
            shouldReload = WidgetSelectionStore.selectRandomItemID(from: snapshot)
        } else {
            WidgetSelectionStore.saveSelectedItemID(nil)
        }

        if shouldReload {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.widgetKind)
        }
        return .result()
    }
}

struct SanjuMemoryWidgetEntry: TimelineEntry {
    let date: Date
    let item: WidgetSnapshotStore.Item?
    var interfaceLanguageCode = WidgetInterfaceLanguage.resolvedCode
}

struct SanjuMemoryWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> SanjuMemoryWidgetEntry {
        SanjuMemoryWidgetEntry(
            date: .now,
            item: WidgetSnapshotStore.Item(
                id: "placeholder",
                memoryID: "placeholder",
                createdAt: .now,
                english: "A quiet photo can become a sentence you really remember.",
                chinese: "一张安静的照片，也能变成你真正记住的一句话。",
                imageFileName: nil
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (SanjuMemoryWidgetEntry) -> Void) {
        let snapshot = WidgetSnapshotStore.loadSnapshot()
        completion(SanjuMemoryWidgetEntry(date: .now, item: selectedItem(from: snapshot, date: .now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SanjuMemoryWidgetEntry>) -> Void) {
        let snapshot = WidgetSnapshotStore.loadSnapshot()
        let now = Date()
        let calendar = Calendar.current
        let nextHourDate = calendar.nextDate(
            after: now,
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(3600)

        var entries: [SanjuMemoryWidgetEntry] = [
            SanjuMemoryWidgetEntry(
                date: now,
                item: selectedItem(from: snapshot, date: now)
            )
        ]

        entries.append(
            contentsOf: (0..<12).map { offset in
                let entryDate = calendar.date(byAdding: .hour, value: offset, to: nextHourDate) ?? nextHourDate
                return SanjuMemoryWidgetEntry(
                    date: entryDate,
                    item: selectedItem(from: snapshot, date: entryDate)
                )
            }
        )

        let refreshDate = calendar.date(byAdding: .hour, value: 12, to: nextHourDate) ?? nextHourDate.addingTimeInterval(12 * 3600)
        completion(Timeline(entries: entries, policy: .after(refreshDate)))
    }

    private func selectedItem(
        from snapshot: WidgetSnapshotStore.Snapshot?,
        date: Date
    ) -> WidgetSnapshotStore.Item? {
        guard let snapshot, !snapshot.items.isEmpty else { return nil }
        if let selectedItemID = WidgetSelectionStore.loadSelectedItemID(at: date),
           let selectedItem = snapshot.items.first(where: { $0.id == selectedItemID }) {
            return selectedItem
        }

        return WidgetSnapshotStore.defaultItem(from: snapshot, date: date)
    }
}

struct SanjuMemoryWidgetView: View {
    var entry: SanjuMemoryWidgetProvider.Entry
    private let contentPadding: CGFloat = 10
    private let contentSpacing: CGFloat = 12
    private let imageCornerRadius: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let imageSide = max(proxy.size.height - (contentPadding * 2), 0)

            Group {
                if let item = entry.item {
                    HStack(spacing: contentSpacing) {
                        widgetImage(for: item)
                            .frame(width: imageSide, height: imageSide)
                            .clipShape(
                                RoundedRectangle(cornerRadius: imageCornerRadius, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 8) {
                            Text(attributedText(item.targetText, language: item.teachingLocale))
                                .font(.callout)
                                .foregroundStyle(Color(red: 0.24, green: 0.22, blue: 0.18))
                                .lineLimit(5)
                                .multilineTextAlignment(.leading)

                            Spacer(minLength: 0)

                            HStack(alignment: .center, spacing: 8) {
                                Text(item.createdAt, style: .date)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)

                                Spacer(minLength: 0)

                                Button(intent: ShuffleMemoryIntent()) {
                                    Image(systemName: "shuffle")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color(red: 0.46, green: 0.41, blue: 0.34))
                                        .frame(width: 28, height: 28)
                                        .background(Color.white.opacity(0.68), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text("切换随机回忆"))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(contentPadding)
                } else {
                    emptyStateView(imageSide: imageSide)
                    .padding(contentPadding)
                }
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color(red: 0.98, green: 0.97, blue: 0.93),
                    Color(red: 0.95, green: 0.94, blue: 0.90)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .widgetURL(entry.item.flatMap(widgetURL(for:)) ?? emptyStateWidgetURL())
        .environment(\.locale, Locale(identifier: entry.interfaceLanguageCode))
    }

    private func emptyStateView(imageSide: CGFloat) -> some View {
        HStack(spacing: contentSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: imageCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.93, green: 0.88, blue: 0.80),
                                Color(red: 0.85, green: 0.79, blue: 0.70)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: imageCornerRadius - 3, style: .continuous)
                    .stroke(Color.white.opacity(0.28), lineWidth: 1)
                    .padding(6)

                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(.white.opacity(0.94))

                    Text("随机回忆")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .frame(width: imageSide, height: imageSide)

            VStack(alignment: .leading, spacing: 10) {
                Text("暂无内容")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(red: 0.25, green: 0.23, blue: 0.19))

                Text("当你的回忆中有多张图片时，这里会随机显示一张图片和对应的描述。")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.36, green: 0.33, blue: 0.28))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                Text("现在去添加")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.47, green: 0.42, blue: 0.35))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.6), in: Capsule())

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func widgetImage(for item: WidgetSnapshotStore.Item) -> some View {
        if let image = loadImage(for: item) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.92, green: 0.88, blue: 0.80),
                        Color(red: 0.84, green: 0.78, blue: 0.68)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Image(systemName: "photo")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    private func loadImage(for item: WidgetSnapshotStore.Item) -> UIImage? {
        guard let imageURL = WidgetSnapshotStore.imageURL(for: item) else { return nil }
        return UIImage(contentsOfFile: imageURL.path)
    }

    private func attributedText(_ text: String, language: String) -> AttributedString {
        var value = AttributedString(text)
        value.languageIdentifier = language
        return value
    }

    private func widgetURL(for item: WidgetSnapshotStore.Item) -> URL? {
        URL(string: "sanju://memory/\(item.memoryID)")
    }

    private func emptyStateWidgetURL() -> URL? {
        URL(string: "sanju://new")
    }
}

struct SanjuMemoryWidget: Widget {
    let kind: String = WidgetSnapshotStore.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SanjuMemoryWidgetProvider()) { entry in
            SanjuMemoryWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(verbatim: WidgetInterfaceLanguage.string("随机回忆")))
        .description(Text(verbatim: WidgetInterfaceLanguage.string("从你生成过的回忆里，随机挑一句放到桌面上。")))
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct 三句小组件Bundle: WidgetBundle {
    var body: some Widget {
        SanjuMemoryWidget()
    }
}
