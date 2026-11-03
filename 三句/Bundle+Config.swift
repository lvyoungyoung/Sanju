import Foundation

nonisolated enum SupabaseEnvironment {
    // Keep the existing on-device keys when changing only the network route.
    static func persistenceNamespace(for url: String, isolationID: String? = nil) -> String {
        if let isolationID { return isolationID }
        return switch url {
        case "https://spb-bp103246ivn7q0nl.supabase.opentrust.net":
            "https://api.sanju.cc"
        case "https://spb-bp1364k407p37qn7.supabase.opentrust.net":
            "https://api-staging.sanju.cc"
        default:
            url
        }
    }

    static func storageKey(_ key: String, isolationID: String?) -> String {
        guard let isolationID else { return key }
        return "\(isolationID).\(key)"
    }

    static func dataDirectory(in root: URL, isolationID: String?) -> URL {
        let directory = root.appendingPathComponent("Sanju", isDirectory: true)
        guard let isolationID else { return directory }
        return directory.appendingPathComponent("environments", isDirectory: true)
            .appendingPathComponent(isolationID, isDirectory: true)
    }
}

extension Bundle {
    private var configResourceName: String {
        #if STAGING
        "Config.staging"
        #else
        "Config"
        #endif
    }

    var supabaseURL: String? {
        configValue(forKey: "SupabaseURL")
    }

    var supabasePersistenceNamespace: String? {
        supabaseURL.map {
            SupabaseEnvironment.persistenceNamespace(for: $0, isolationID: supabaseDataIsolationID)
        }
    }

    var supabaseDataIsolationID: String? {
        configValue(forKey: "SupabaseDataIsolationID")
    }

    var supabaseDefaults: UserDefaults {
        guard let isolationID = supabaseDataIsolationID else { return .standard }
        guard let defaults = UserDefaults(suiteName: "com.yanglv.sanju.\(isolationID)") else {
            preconditionFailure("Unable to open isolated staging storage")
        }
        return defaults
    }

    var supabaseDataDirectory: URL {
        SupabaseEnvironment.dataDirectory(
            in: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            isolationID: supabaseDataIsolationID
        )
    }

    var supabasePublishableKey: String? {
        configValue(forKey: "SupabasePublishableKey")
    }

    var storeProductConfigs: [StoreProductConfig] {
        guard let url = url(forResource: configResourceName, withExtension: "plist"),
              let data = PersistenceDiagnostics.readData(from: url, operation: "Load app config"),
              let plist = propertyList(from: data, operation: "Parse app config"),
              let rawProducts = plist["StoreKitProducts"] as? [[String: Any]] else {
            return []
        }

        return rawProducts.compactMap { item in
            guard let productID = item["productID"] as? String,
                  let credits = item["credits"] as? Int else {
                return nil
            }

            return StoreProductConfig(productID: productID, credits: credits)
        }
    }

    private func configValue(forKey key: String) -> String? {
        guard let url = url(forResource: configResourceName, withExtension: "plist"),
              let data = PersistenceDiagnostics.readData(from: url, operation: "Load app config"),
              let plist = propertyList(from: data, operation: "Parse app config"),
              let value = plist[key] as? String else {
            return nil
        }

        return value
    }

    private func propertyList(from data: Data, operation: String) -> [String: Any]? {
        do {
            return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        } catch {
            #if DEBUG
            print("[Persistence] \(operation) failed: \(error.localizedDescription)")
            #endif
            return nil
        }
    }
}
