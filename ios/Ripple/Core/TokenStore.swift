import Foundation
import Security

/// 액세스·리프레시 토큰을 키체인에 보관
final class TokenStore {
    static let shared = TokenStore()
    private let service = "com.example.ripple.tokens"

    var accessToken: String? { read("access") }
    var refreshToken: String? { read("refresh") }

    func save(access: String, refresh: String) {
        write("access", access)
        write("refresh", refresh)
    }

    func clear() {
        delete("access")
        delete("refresh")
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    // 서명 없이 빌드된 시뮬레이터에서 키체인이 실패하면 UserDefaults로 대체 (개발용)
    private func fallbackKey(_ key: String) -> String { "\(service).\(key)" }

    private func read(_ key: String) -> String? {
        if let v = UserDefaults.standard.string(forKey: fallbackKey(key)) { return v }
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ key: String, _ value: String) {
        delete(key)
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(q as CFDictionary, nil) != errSecSuccess {
            UserDefaults.standard.set(value, forKey: fallbackKey(key))
        }
    }

    private func delete(_ key: String) {
        UserDefaults.standard.removeObject(forKey: fallbackKey(key))
        SecItemDelete(query(key) as CFDictionary)
    }
}
