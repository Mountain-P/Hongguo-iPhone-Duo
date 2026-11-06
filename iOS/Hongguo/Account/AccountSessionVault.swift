import Foundation
import Security
import HongguoCore

enum AccountSessionVault {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "tw.mountainp.hongguo.official-account",
         kSecAttrAccount as String: "active-session"]
    }

    static func load() throws -> AccountSession? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 128 * 1024 else {
            throw AppError.message("暫時無法讀取登入狀態，請解鎖 iPhone 後重試。")
        }
        do { return try JSONDecoder().decode(AccountSession.self, from: data) }
        catch { throw AppError.message("登入狀態已無法使用，請重新登入。") }
    }

    static func save(_ session: AccountSession) throws {
        let data = try JSONEncoder().encode(session)
        guard data.count <= 128 * 1024 else { throw AppError.message("登入資料格式不符，尚未儲存。") }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw AppError.message("無法將登入狀態儲存至鑰匙圈，請稍後重試。")
            }
        } else if status != errSecSuccess {
            throw AppError.message("無法更新鑰匙圈中的登入狀態。")
        }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.message("無法移除登入狀態，請解鎖 iPhone 後重試。")
        }
    }
}
