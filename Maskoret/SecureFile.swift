import Foundation
import CryptoKit
import Security

/// The only thing the app keeps on the device: a temporary, encrypted copy of the household on screen,
/// so it opens fast and keeps working without internet. The server is the source of truth;
/// signing out deletes this copy and its key.
///
/// Files are AES-GCM sealed with a 256-bit key that lives in the Keychain (never in the files' folder).
enum SecureFile {
    private static let service = "com.shlomodavid.maskoret.cache"
    private static let account = "local-cache-key"
    private static let magic = Data("MSK1".utf8)

    /// The local working copy: Application Support/Maskoret.
    static var folder: URL { Store.fileURL.deletingLastPathComponent() }

    // MARK: Read / write

    static func write(_ plain: Data, to url: URL) throws {
        let sealed = try AES.GCM.seal(plain, using: key())
        guard let combined = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try (magic + combined).write(to: url, options: options)
    }

    /// Reads an encrypted file. Plain JSON written by older versions is still read (and gets encrypted on the next save).
    static func read(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard data.starts(with: magic) else { return data }
        guard let box = try? AES.GCM.SealedBox(combined: data.dropFirst(magic.count)),
              let key = try? existingKey(),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return plain
    }

    static func isEncrypted(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: magic.count)) == magic
    }

    /// Signing out: the encrypted copy and its key are gone — what's left on disk (if anything) can't be read.
    static func wipeAll() {
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: item)
        }
        SecItemDelete(query() as CFDictionary)
        cachedKey = nil
    }

    // MARK: Key

    private static var cachedKey: SymmetricKey?

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func existingKey() throws -> SymmetricKey? {
        if let cachedKey { return cachedKey }
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let key = SymmetricKey(data: data)
        cachedKey = key
        return key
    }

    private static func key() throws -> SymmetricKey {
        if let key = try existingKey() { return key }
        let key = SymmetricKey(size: .bits256)
        var add = query()
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrLabel as String] = "מחשבון שכר — מפתח העותק המקומי"
        #if os(iOS)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        cachedKey = key
        return key
    }
}
