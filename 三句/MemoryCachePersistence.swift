import Foundation

enum MemoryCachePersistence {
    private struct Envelope<Value: Codable>: Codable {
        let schemaVersion: Int
        let userID: String?
        let payload: Value
    }

    struct Backup: Codable {
        let userID: String?
        let data: Data
    }

    static func owner(in data: Data, legacyOwner: String?) throws -> String? {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return legacyOwner }
        guard envelope["schemaVersion"] as? Int == 2 else { throw LanguageContractError.unsupportedVersion }
        if let owner = envelope["userID"] as? String { return owner }
        guard envelope["userID"] == nil || envelope["userID"] is NSNull else { throw LanguageContractError.corruptContent }
        return nil
    }

    static func decode<Value: Codable>(_ type: Value.Type, data: Data, userID: String?) throws -> Value {
        let decoder = JSONDecoder()
        if (try JSONSerialization.jsonObject(with: data)) is [String: Any] {
            let envelope = try decoder.decode(Envelope<Value>.self, from: data)
            guard envelope.schemaVersion == 2 else { throw LanguageContractError.unsupportedVersion }
            guard envelope.userID == userID else { throw LanguageContractError.corruptContent }
            return envelope.payload
        }
        return try decoder.decode(type, from: data)
    }

    /// Commit one verified value; failure leaves both the old bytes and its image references intact.
    static func write<Value: Codable>(_ value: Value, key: String, userID: String?,
                                      previousOwner: String?, defaults: UserDefaults) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(Envelope(schemaVersion: 2, userID: userID, payload: value))
        _ = try decode(Value.self, data: data, userID: userID)
        if let existing = defaults.data(forKey: key) {
            let oldOwner = try owner(in: existing, legacyOwner: previousOwner)
            _ = try decode(Value.self, data: existing, userID: oldOwner)
            let backupKey = "\(key).preV2Backup"
            if defaults.data(forKey: backupKey) == nil {
                defaults.set(try encoder.encode(Backup(userID: oldOwner, data: existing)), forKey: backupKey)
            }
        }
        defaults.set(data, forKey: key)
    }
}
