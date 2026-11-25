import Foundation
import Security
import LocalAuthentication
import CommonCrypto

/// A saved native T3 connection. Credentials are borrowed in memory only;
/// Open Island never rewrites the desktop catalog or revokes its sessions.
public struct T3SavedEnvironment: Equatable, Sendable {
    public var environmentID: String
    public var label: String
    public var origin: URL
    public var webSocketOrigin: URL
    public var bearerToken: String

    public init(environmentID: String, label: String, origin: URL, webSocketOrigin: URL, bearerToken: String) {
        self.environmentID = environmentID
        self.label = label
        self.origin = origin
        self.webSocketOrigin = webSocketOrigin
        self.bearerToken = bearerToken
    }
}

public enum T3EnvironmentCatalog {
    public enum CatalogError: Error, LocalizedError, Equatable {
        case keychainUnavailable, invalidCatalog
        public var errorDescription: String? {
            switch self {
            case .keychainUnavailable: "Allow Open Island to read T3 Code’s saved connection key in macOS Keychain."
            case .invalidCatalog: "T3 Code’s saved connections could not be read."
            }
        }
    }

    public static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3"),
                            allowKeychainPrompt: Bool = false) throws -> [T3SavedEnvironment] {
        let path = home.appendingPathComponent("userdata/connection-catalog.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        struct Envelope: Decodable { var version: Int; var encryptedCatalog: String }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: path))
        guard envelope.version == 1, let ciphertext = Data(base64Encoded: envelope.encryptedCatalog) else {
            throw CatalogError.invalidCatalog
        }
        let context = LAContext()
        context.interactionNotAllowed = !allowKeychainPrompt
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "t3code Safe Storage",
            kSecAttrAccount: "t3code Key",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let password = item as? Data else { throw CatalogError.keychainUnavailable }
        return try decode(decrypt(ciphertext, password: password))
    }

    /// Electron safeStorage's macOS v10 format, using T3's own Keychain key.
    static func decrypt(_ ciphertext: Data, password: Data) throws -> Data {
        guard ciphertext.starts(with: Data("v10".utf8)), ciphertext.count > 3 else { throw CatalogError.invalidCatalog }
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let derived = password.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes.bindMemory(to: Int8.self).baseAddress,
                                password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                1003, &key, key.count)
        }
        guard derived == kCCSuccess else { throw CatalogError.invalidCatalog }
        let encrypted = Data(ciphertext.dropFirst(3))
        let iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: encrypted.count + kCCBlockSizeAES128)
        var outputCount = 0
        let status = encrypted.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, bytes.baseAddress, encrypted.count, &output, output.count, &outputCount)
        }
        guard status == kCCSuccess else { throw CatalogError.invalidCatalog }
        return Data(output.prefix(outputCount))
    }

    static func decode(_ data: Data) throws -> [T3SavedEnvironment] {
        struct Profile: Decodable {
            var _tag: String
            var connectionId: String
            var environmentId: String
            var label: String
            var httpBaseUrl: URL?
            var wsBaseUrl: URL?
        }
        struct Credential: Decodable {
            struct Value: Decodable { var _tag: String; var token: String? }
            var connectionId: String
            var credential: Value
        }
        struct Catalog: Decodable {
            var schemaVersion: Int
            var profiles: [Profile]
            var credentials: [Credential]
            var disabledEnvironmentIds: [String]?
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.schemaVersion == 1 else { throw CatalogError.invalidCatalog }
        let disabled = Set(catalog.disabledEnvironmentIds ?? [])
        var environments: [T3SavedEnvironment] = []
        var seen: Set<String> = []
        for profile in catalog.profiles where profile._tag == "BearerConnectionProfile" {
            guard !disabled.contains(profile.environmentId), !seen.contains(profile.environmentId),
                  let origin = profile.httpBaseUrl, let wsOrigin = profile.wsBaseUrl,
                  let token = catalog.credentials.first(where: { $0.connectionId == profile.connectionId
                      && $0.credential._tag == "BearerConnectionCredential" })?.credential.token,
                  !token.isEmpty else { continue }
            try validate(origin: origin, webSocketOrigin: wsOrigin)
            seen.insert(profile.environmentId)
            environments.append(T3SavedEnvironment(environmentID: profile.environmentId, label: profile.label,
                                                    origin: origin, webSocketOrigin: wsOrigin, bearerToken: token))
        }
        return environments
    }

    public static func validate(origin: URL, webSocketOrigin: URL) throws {
        guard let httpScheme = origin.scheme, let wsScheme = webSocketOrigin.scheme,
              ["http", "https"].contains(httpScheme), origin.host != nil,
              ["ws", "wss"].contains(wsScheme), webSocketOrigin.host == origin.host,
              webSocketOrigin.port == origin.port,
              (httpScheme == "https") == (wsScheme == "wss") else { throw CatalogError.invalidCatalog }
        for url in [origin, webSocketOrigin] {
            guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw CatalogError.invalidCatalog
            }
        }
    }
}
