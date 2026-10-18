import CryptoKit
import Foundation
import Security

struct VoWLANCredential: Equatable, Sendable {
    let secret: Data

    var encodedSecret: String { secret.base64URL }

    init(secret: Data) throws {
        guard secret.count >= 32 else { throw VoWLANAuthError.invalidSecret }
        self.secret = secret
    }
    init(encodedSecret: String) throws {
        let value = encodedSecret.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4)) else {
            throw VoWLANAuthError.invalidSecret
        }
        try self.init(secret: data)
    }
}

struct VoWLANSignedRequest: Equatable, Sendable {
    let timestamp: Int64
    let nonce: String
    let canonical: String
    let signature: String
}

enum VoWLANAuthError: LocalizedError {
    case invalidSecret
    case randomUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidSecret: return "VoWLAN 配对密钥无效"
        case .randomUnavailable: return "无法生成 VoWLAN 安全随机数"
        }
    }
}

struct VoWLANRequestSigner: Sendable {
    let credential: VoWLANCredential

    init(secret: Data) throws {
        credential = try VoWLANCredential(secret: secret)
    }

    func sign(
        method: String,
        path: String,
        body: Data,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970),
        nonce: String = VoWLANRequestSigner.makeNonce()
    ) throws -> VoWLANSignedRequest {
        guard !nonce.isEmpty else { throw VoWLANAuthError.randomUnavailable }
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let canonical = "\(method.uppercased())\n\(path)\n\(digest)\n\(timestamp)\n\(nonce)"
        let key = SymmetricKey(data: credential.secret)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: key)
        return VoWLANSignedRequest(
            timestamp: timestamp,
            nonce: nonce,
            canonical: canonical,
            signature: Data(mac).base64URL
        )
    }

    static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return "" }
        return Data(bytes).base64URL
    }
}

enum VoWLANCredentialStore {
    private static let service = "com.example.airsim.vowlan"
    private static let account = "paired-secret-v1"

    static func generate() throws -> VoWLANCredential {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw VoWLANAuthError.randomUnavailable
        }
        return try VoWLANCredential(secret: Data(bytes))
    }

    private static func deviceAccount(_ agentID: String) -> String {
        "agent-v1-" + SHA256.hash(data: Data(agentID.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func load(agentID: String) -> VoWLANCredential? {
        guard !agentID.isEmpty else { return nil }
        var query = queryWithoutValue()
        query[kSecAttrAccount as String] = deviceAccount(agentID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? VoWLANCredential(secret: data)
    }
    static func save(_ credential: VoWLANCredential, agentID: String) throws {
        guard !agentID.isEmpty else { throw VoWLANAuthError.invalidSecret }
        var query = queryWithoutValue()
        query[kSecAttrAccount as String] = deviceAccount(agentID)
        let update = [kSecValueData as String: credential.secret]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = credential.secret
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw VoWLANAuthError.randomUnavailable }
        } else if status != errSecSuccess { throw VoWLANAuthError.randomUnavailable }
    }
    static func remove(agentID: String) {
        var query = queryWithoutValue()
        query[kSecAttrAccount as String] = deviceAccount(agentID)
        SecItemDelete(query as CFDictionary)
    }
    static func hasAny() -> Bool {
        load() != nil || PairedAndroidDeviceStore.records().contains { load(agentID: $0.id) != nil }
    }

    static func loadOrCreate() throws -> VoWLANCredential {
        if let existing = load() { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw VoWLANAuthError.randomUnavailable
        }
        let credential = try VoWLANCredential(secret: Data(bytes))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: credential.secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(queryWithoutValue() as CFDictionary)
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw VoWLANAuthError.randomUnavailable
        }
        return credential
    }

    static func load() -> VoWLANCredential? {
        var query = queryWithoutValue()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? VoWLANCredential(secret: data)
    }

    static func remove() {
        SecItemDelete(queryWithoutValue() as CFDictionary)
    }

    private static func queryWithoutValue() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

struct KeychainLocalDeviceCredentials: LocalDeviceCredentialStoring {
    func load(agentID: String) -> VoWLANCredential? { VoWLANCredentialStore.load(agentID: agentID) }
    func save(_ credential: VoWLANCredential, agentID: String) throws { try VoWLANCredentialStore.save(credential, agentID: agentID) }
    func remove(agentID: String) { VoWLANCredentialStore.remove(agentID: agentID) }
    func legacy() -> VoWLANCredential? { VoWLANCredentialStore.load() }
}

enum VoWLANHealthProof {
    static func verifyDial(_ signature: String?, nonce: String, operationID: String,
                           androidID: String, backendID: String, credential: VoWLANCredential) -> Bool {
        guard let signature, !androidID.isEmpty, !backendID.isEmpty else { return false }
        let encoded = signature.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let bytes = Data(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(bytes,
            authenticating: Data("AIRSIM-DIAL1\n\(nonce)\n\(operationID)\n\(androidID)\n\(backendID)".utf8),
            using: SymmetricKey(data: credential.secret))
    }
    static func verify(_ signature: String?, nonce: String, agentID: String, credential: VoWLANCredential) -> Bool {
        guard let signature, !nonce.isEmpty, !agentID.isEmpty else { return false }
        let encoded = signature.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let supplied = Data(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(supplied,
            authenticating: Data("AIRSIM-HEALTH1\n\(nonce)\n\(agentID)".utf8), using: SymmetricKey(data: credential.secret))
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
