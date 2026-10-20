import CommonCrypto
import Foundation
import Security

public struct AppPasswordRecord: Codable {
    let salt: Data
    let digest: Data
    let iterations: UInt32

    public static func create(password: String) throws -> AppPasswordRecord {
        guard password.count >= 12, password.utf8.count <= 1024 else {
            throw AppPasswordError.message("비밀번호는 12자 이상, UTF-8 1024바이트 이하여야 합니다.")
        }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw AppPasswordError.keychain(status) }
        let iterations: UInt32 = 600_000
        return try AppPasswordRecord(salt: salt, digest: derive(password, salt: salt, iterations: iterations), iterations: iterations)
    }

    public func matches(_ password: String) throws -> Bool {
        guard salt.count == 16, digest.count == 32, iterations == 600_000 else {
            throw AppPasswordError.message("저장된 앱 비밀번호 정보가 손상되었습니다.")
        }
        guard password.utf8.count <= 1024 else { return false }
        let candidate = try Self.derive(password, salt: salt, iterations: iterations)
        var difference: UInt8 = 0
        for (left, right) in zip(candidate, digest) { difference |= left ^ right }
        return difference == 0
    }

    private static func derive(_ password: String, salt: Data, iterations: UInt32) throws -> Data {
        let passwordBytes = Array(password.utf8)
        var result = Data(count: 32)
        let status = result.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                passwordBytes.withUnsafeBytes { input in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        input.baseAddress?.assumingMemoryBound(to: Int8.self), input.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                        output.baseAddress?.assumingMemoryBound(to: UInt8.self), output.count)
                }
            }
        }
        guard status == kCCSuccess else { throw AppPasswordError.message("비밀번호 검증값 생성에 실패했습니다.") }
        return result
    }
}

public enum AppPasswordStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.macmonitor.app.password",
         kSecAttrAccount as String: "owner"]
    }

    public static func load() throws -> AppPasswordRecord? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AppPasswordError.keychain(status)
        }
        return try JSONDecoder().decode(AppPasswordRecord.self, from: data)
    }

    public static func save(password: String) throws {
        let data = try JSONEncoder().encode(AppPasswordRecord.create(password: password))
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppPasswordError.keychain(status) }
    }
}

public enum AppPasswordError: LocalizedError {
    case message(String)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .message(message): return message
        case let .keychain(status): return "앱 비밀번호 키체인 접근 실패 (\(status)). 키체인 잠금을 확인하세요."
        }
    }
}
