import Foundation

enum PersistenceDiagnostics {
    static func encode<T: Encodable>(_ value: T, using encoder: JSONEncoder, operation: String) -> Data? {
        do {
            return try encoder.encode(value)
        } catch {
            logFailure(operation, error: error)
            return nil
        }
    }

    static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        using decoder: JSONDecoder,
        operation: String
    ) -> T? {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            logFailure(operation, error: error)
            return nil
        }
    }

    static func readData(from url: URL, operation: String) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            return try Data(contentsOf: url)
        } catch {
            logFailure("\(operation) at \(url.lastPathComponent)", error: error)
            return nil
        }
    }

    static func writeData(_ data: Data, to url: URL, operation: String) {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            logFailure("\(operation) at \(url.lastPathComponent)", error: error)
        }
    }

    static func createDirectory(at url: URL, operation: String) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            logFailure("\(operation) at \(url.lastPathComponent)", error: error)
        }
    }

    static func contentsOfDirectory(at url: URL, operation: String) -> [URL]? {
        do {
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        } catch {
            logFailure("\(operation) at \(url.lastPathComponent)", error: error)
            return nil
        }
    }

    static func removeItem(at url: URL, operation: String) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logFailure("\(operation) at \(url.lastPathComponent)", error: error)
        }
    }

    static func moveItem(at sourceURL: URL, to destinationURL: URL, operation: String) {
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            logFailure(
                "\(operation) from \(sourceURL.lastPathComponent) to \(destinationURL.lastPathComponent)",
                error: error
            )
        }
    }

    private static func logFailure(_ operation: String, error: Error) {
        #if DEBUG
        print("[Persistence] \(operation) failed: \(error.localizedDescription)")
        #endif
    }
}
