import Foundation
import Security

/// The API keys of the saved connections, kept apart from the rest of the settings.
struct ConnectionSecrets: Codable, Equatable {
    var prdb = ""
    var sab = ""
    /// By indexer ID.
    var indexers: [String: String] = [:]
    var isEmpty: Bool { prdb.isEmpty && sab.isEmpty && indexers.isEmpty }
}

extension FeedConnections {
    /// Removes every API key and returns them.
    mutating func detachSecrets() -> ConnectionSecrets {
        var secrets = ConnectionSecrets(prdb: prdbKey, sab: sab?.apiKey ?? "")
        prdbKey = ""
        sab?.apiKey = ""
        for index in indexers.indices where !indexers[index].apiKey.isEmpty {
            secrets.indexers[indexers[index].id.uuidString] = indexers[index].apiKey
            indexers[index].apiKey = ""
        }
        return secrets
    }

    /// Fills in the keys this value does not carry itself.
    mutating func attach(_ secrets: ConnectionSecrets) {
        if prdbKey.isEmpty { prdbKey = secrets.prdb }
        if sab?.apiKey.isEmpty == true { sab?.apiKey = secrets.sab }
        for index in indexers.indices where indexers[index].apiKey.isEmpty {
            indexers[index].apiKey = secrets.indexers[indexers[index].id.uuidString] ?? ""
        }
    }
}

/// Where the API keys rest once they leave the database.
struct SecretStore: Sendable {
    let load: @Sendable () throws -> Data?
    let save: @Sendable (Data) throws -> Void
}

extension SecretStore {
    /// The Keychain grants access by code signature. An ad hoc or unsigned build gets a new signature
    /// every time it is built, and macOS would ask for the login password after each build.
    /// Only a build signed by a development team keeps its keys there.
    static var forThisBuild: SecretStore? { signedByTeam ? .keychain : nil }

    static let keychain = SecretStore(load: {
        var found: CFTypeRef?
        let status = SecItemCopyMatching(item(adding: [kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]), &found)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = found as? Data else { throw failure(status) }
        return data
    }, save: { data in
        var status = SecItemUpdate(item(), [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(item(adding: [kSecValueData: data, kSecAttrLabel: "Loaderoo API keys"]), nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    })

    private static func item(adding extra: [CFString: Any] = [:]) -> CFDictionary {
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                     kSecAttrService: "net.prdb.loaderoo", kSecAttrAccount: "connections"]
        return item.merging(extra) { $1 } as CFDictionary
    }

    private static func failure(_ status: OSStatus) -> FeedError {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return FeedError("The Keychain did not release the API keys: \(reason)")
    }

    static var signedByTeam: Bool {
        var code: SecCode?
        var program: SecStaticCode?
        var details: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &program) == errSecSuccess, let program,
              SecCodeCopySigningInformation(program, SecCSFlags(rawValue: kSecCSSigningInformation), &details) == errSecSuccess,
              let details = details as? [String: Any] else { return false }
        return details[kSecCodeInfoTeamIdentifier as String] is String
    }
}
