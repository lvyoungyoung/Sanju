import Foundation

extension Bundle {
    var supabaseURL: String? {
        configValue(forKey: "SupabaseURL")
    }

    var supabasePublishableKey: String? {
        configValue(forKey: "SupabasePublishableKey")
    }

    var storeProductConfigs: [StoreProductConfig] {
        guard let url = url(forResource: "Config", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
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
        guard let url = url(forResource: "Config", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let value = plist[key] as? String else {
            return nil
        }

        return value
    }
}
