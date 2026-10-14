import Foundation
import WidgetKit

enum MemoryWidgetSnapshotStore {
    nonisolated static let appGroupID = "group.com.yanglv.sanju"
    nonisolated static let widgetKind = "SanjuMemoryWidget"

    private static let snapshotFileName = "memory-widget-snapshot.json"
    private static let imageDirectoryName = "memory-widget-images"
    private static let snapshotQueue = DispatchQueue(
        label: "com.yanglv.sanju.memory-widget-snapshot",
        qos: .utility
    )

    struct Snapshot: Codable {
        var schemaVersion = 2
        let generatedAt: Date
        let items: [Item]
    }

    struct Item: Codable, Hashable {
        let id: String
        let memoryID: String
        let createdAt: Date
        let targetText: String
        let translationText: String
        let targetLanguage: String
        let translationLanguage: String
        let teachingLocale: String
        let contentVersion: Int
        let imageFileName: String?
    }

    static func scheduleUpdate(with memories: [MemoryEntry]) {
        let snapshotMemories = memories
        snapshotQueue.async {
            writeSnapshot(with: snapshotMemories)
        }
    }

    static func refreshImmediately(with memories: [MemoryEntry]) async {
        let snapshotMemories = memories
        await withCheckedContinuation { continuation in
            snapshotQueue.async {
                writeSnapshot(with: snapshotMemories)
                continuation.resume()
            }
        }
    }

    private static func writeSnapshot(with memories: [MemoryEntry]) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return
        }

        let imageDirectoryURL = containerURL.appendingPathComponent(imageDirectoryName, isDirectory: true)
        PersistenceDiagnostics.createDirectory(at: imageDirectoryURL, operation: "Create widget image directory")

        let validFileNames = Set<String>(memories.compactMap { memory in
            guard !memory.imageData.isEmpty, !memory.sentences.isEmpty else { return nil }
            return imageFileName(for: memory.id)
        })

        if let existingFiles = PersistenceDiagnostics.contentsOfDirectory(
            at: imageDirectoryURL,
            operation: "List widget image directory"
        ) {
            for fileURL in existingFiles where !validFileNames.contains(fileURL.lastPathComponent) {
                PersistenceDiagnostics.removeItem(at: fileURL, operation: "Remove stale widget image")
            }
        }

        var items: [Item] = []
        items.reserveCapacity(memories.reduce(into: 0) { $0 += $1.sentences.count })

        for memory in memories.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard !memory.sentences.isEmpty else { continue }

            let fileName = imageFileName(for: memory.id)
            if !memory.imageData.isEmpty {
                let imageFileURL = imageDirectoryURL.appendingPathComponent(fileName)
                PersistenceDiagnostics.writeData(memory.imageData, to: imageFileURL, operation: "Write widget image")
            }

            for sentence in memory.sentences {
                items.append(
                    Item(
                        id: sentence.id.uuidString.lowercased(),
                        memoryID: memory.id.uuidString.lowercased(),
                        createdAt: memory.createdAt,
                        targetText: sentence.targetText,
                        translationText: sentence.translationText,
                        targetLanguage: memory.context.targetLanguage.rawValue,
                        translationLanguage: memory.context.translationLanguage.rawValue,
                        teachingLocale: memory.context.teachingLocale.rawValue,
                        contentVersion: sentence.contentVersion,
                        imageFileName: fileName
                    )
                )
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let payload = Snapshot(generatedAt: .now, items: items)
        let payloadURL = containerURL.appendingPathComponent(snapshotFileName)

        if let data = PersistenceDiagnostics.encode(
            payload,
            using: encoder,
            operation: "Encode widget snapshot"
        ) {
            PersistenceDiagnostics.writeData(data, to: payloadURL, operation: "Write widget snapshot")
        }

        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }

    private static func imageFileName(for memoryID: UUID) -> String {
        "\(memoryID.uuidString.lowercased()).jpg"
    }
}
