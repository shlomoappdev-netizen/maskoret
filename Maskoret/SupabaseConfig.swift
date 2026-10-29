import Foundation
import Security
import Supabase

/// The app's Supabase project ("Maskoret").
enum SupabaseConfig {
    static let url = URL(string: "https://pukbrxsuucqrukiaojlp.supabase.co")!
    /// The public (anon) key. It's meant to be inside the app: what each user can read or change
    /// is decided by the database's row-level security and functions, not by this key.
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InB1a2JyeHN1dWNxcnVraWFvamxwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTMyNTIwMjksImV4cCI6MjEwODgyODAyOX0.EOR76pbmTJQUaM8IxCzevHUJM7WT4EF4EIUjk3xip1I"
}

/// Keeps the login session in the Keychain, the same kind of item the AI keys use
/// (works for the locally signed Mac app, which can't use the data-protection keychain).
struct KeychainAuthStorage: AuthLocalStorage {
    static let service = "com.shlomodavid.maskoret.auth"

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: KeychainAuthStorage.service,
         kSecAttrAccount as String: key]
    }

    func store(key: String, value: Data) throws {
        SecItemDelete(query(key) as CFDictionary)
        var add = query(key)
        add[kSecValueData as String] = value
        add[kSecAttrLabel as String] = "מחשבון שכר — התחברות"
        #if os(iOS)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        #endif
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func retrieve(key: String) throws -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return out as? Data
    }

    func remove(key: String) throws {
        SecItemDelete(query(key) as CFDictionary)
    }
}

let supabase = SupabaseClient(
    supabaseURL: SupabaseConfig.url,
    supabaseKey: SupabaseConfig.anonKey,
    options: SupabaseClientOptions(
        auth: .init(storage: KeychainAuthStorage(), emitLocalSessionAsInitialSession: true)
    )
)

/// Raw JSON from the API, decoded with a plain decoder (the app's own data stores dates as numbers).
extension PostgrestBuilder {
    func decoded<T: Decodable>(_ type: T.Type) async throws -> T {
        let response = try await execute()
        return try JSONDecoder().decode(T.self, from: response.data)
    }
}

extension AnyJSON {
    /// The app's data as JSON, encoded exactly like the files on disk.
    static func appJSON<T: Encodable>(_ value: T) throws -> AnyJSON {
        try JSONDecoder().decode(AnyJSON.self, from: JSONEncoder().encode(value))
    }
}
