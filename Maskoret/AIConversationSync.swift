import Foundation
import ImageIO
import UniformTypeIdentifiers
import Supabase

// MARK: - The conversation, shared by the user's devices (table ai_conversations)

/// How a message is kept in the account — the same shape the Android/Windows app writes. Pictures stay on the device
/// that sent them; the account keeps only how many there were.
struct SyncedMessage: Codable {
    var id: String
    var role: String
    var text: String
    var date: String
    var model: String?
    var label: String?
    var auto: Bool?
    var imageCount: Int?
    var applied: [Int]?
    var dismissed: Bool?
    var actionError: String?

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Dates as the apps and the server write them: "…T10:20:28.056Z", "….056123Z" (Dart), "….828123+00:00" (Postgres).
    static func date(_ s: String) -> Date? {
        let trimmed = s.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        return iso.date(from: trimmed) ?? ISO8601DateFormatter().date(from: trimmed)
    }

    init(_ m: InsightMessage) {
        id = m.id.uuidString.lowercased()
        role = m.role
        text = m.text
        date = SyncedMessage.iso.string(from: m.date)
        model = m.model
        label = m.label
        auto = m.auto
        imageCount = m.pictureCount > 0 ? m.pictureCount : nil
        applied = m.applied
        dismissed = m.dismissed
        actionError = m.actionError
    }

    var message: InsightMessage? {
        guard let uuid = UUID(uuidString: id), let when = SyncedMessage.date(date) else { return nil }
        var m = InsightMessage(id: uuid, role: role, text: text, date: when, auto: auto, model: model, label: label)
        m.imageCount = imageCount
        m.applied = applied
        m.dismissed = dismissed
        m.actionError = actionError
        return m
    }
}

extension InsightsEngine {
    /// Sends this device's conversation and takes the account's: the server merges them by message id (nothing is
    /// overwritten), drops what came before the newest "new conversation", and returns the one conversation
    /// every device shows.
    func syncConversation() async {
        guard supabase.auth.currentUser != nil else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        struct Params: Encodable {
            let p_messages: [SyncedMessage]
            let p_cleared_at: String?
        }
        struct Merged: Decodable {
            let messages: [SyncedMessage]
            let cleared_at: String?
        }
        let sent = messages.suffix(200)
        let params = Params(p_messages: sent.map(SyncedMessage.init), p_cleared_at: clearedAt.map { formatter.string(from: $0) })
        guard let merged = try? await supabase.rpc("ai_conversation_merge", params: params).decoded(Merged.self) else { return }
        if let cleared = merged.cleared_at.flatMap(SyncedMessage.date), cleared > (clearedAt ?? .distantPast) { clearedAt = cleared }
        let since = clearedAt ?? .distantPast
        // This device keeps its pictures; messages written here while the request was on its way stay too.
        let local = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [InsightMessage] = merged.messages.compactMap { s in
            guard var m = s.message else { return nil }
            if let mine = local[m.id] { m.images = mine.images }
            return m
        }
        let ids = Set(result.map(\.id))
        result += messages.filter { !ids.contains($0.id) && $0.date > since && !sent.contains($0) }
        result.sort { $0.date < $1.date }
        if result != messages { setMessagesFromSync(result) }
    }

    /// Brings in what the user's other devices wrote.
    func pullConversation() async { await syncConversation() }

    /// Saves the conversation in the account a moment after the last change.
    func schedulePush(now: Bool = false) {
        guard supabase.auth.currentUser != nil else { return }
        pushTaskHolder?.cancel()
        pushTaskHolder = Task { [weak self] in
            if !now { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            guard !Task.isCancelled, let self else { return }
            await self.syncConversation()
        }
    }
}

// MARK: - Pictures the user attaches

enum AttachedImage {
    /// Any picture file (PNG screenshot, HEIC photo…) as a JPEG no larger than `maxSide` pixels — small enough to send.
    static func jpeg(from data: Data, maxSide: Int = 1600) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
