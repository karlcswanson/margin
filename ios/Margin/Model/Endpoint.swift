import Foundation
import Security

/// One workspace daemon the app talks to (a host + port + token).
struct Endpoint: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var baseURL: URL
    /// Filled from /v1/info after the first connection.
    var slug: String?
    var colorHex: String?

    var token: String? {
        get { Keychain.read(account: id.uuidString) }
        nonmutating set {
            if let v = newValue { Keychain.write(v, account: id.uuidString) }
            else { Keychain.delete(account: id.uuidString) }
        }
    }
}

/// Endpoint list in UserDefaults; tokens in the Keychain.
enum EndpointStore {
    private static let key = "margin.endpoints.v1"

    static func load() -> [Endpoint] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Endpoint].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [Endpoint]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

enum Keychain {
    private static let service = "margin.endpoint-token"

    static func write(_ value: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // Available after first unlock so notification actions work from the lock screen.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}
