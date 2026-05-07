import Foundation

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
