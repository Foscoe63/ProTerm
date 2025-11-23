import Foundation
import Security

/// Helper class for secure password storage in Keychain
@MainActor
class KeychainHelper {
    static let shared = KeychainHelper()
    
    private let service = "com.proterm.ssh"
    
    private init() {}
    
    /// Save a password to Keychain for a given connection ID
    func savePassword(_ password: String, for connectionID: UUID) -> Bool {
        let passwordData = password.data(using: .utf8)!
        let account = connectionID.uuidString
        
        // Delete existing password if any
        _ = deletePassword(for: connectionID)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// Retrieve a password from Keychain for a given connection ID
    func getPassword(for connectionID: UUID) -> String? {
        let account = connectionID.uuidString
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return password
    }
    
    /// Delete a password from Keychain for a given connection ID
    func deletePassword(for connectionID: UUID) -> Bool {
        let account = connectionID.uuidString
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    
    /// Check if a password exists for a given connection ID
    func hasPassword(for connectionID: UUID) -> Bool {
        return getPassword(for: connectionID) != nil
    }
}

