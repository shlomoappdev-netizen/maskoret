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

    static func date(_ s: String) -> Date? {
        iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
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

private struct ConversationRow: Codable {
    var messages: [SyncedMessage]
    var cleared_at: String?
    var updated_at: String?
}

extension InsightsEngine {
    /// Brings in what the user's other devices wrote, merged with this device's messages (by id).
    func pullConversation() async {
        guard supabase.auth.currentUser != nil else { return }
        guard let rows = try? await supabase.from("ai_conversations").select("messages,cleared_at,updated_at")
            .execute().value as [ConversationRow], let row = rows.first else {
            // Nothing in the account yet: put this device's conversation there.
            if !messages.isEmpty { schedulePush(now: true) }
            return
        }
        let remoteCleared = row.cleared_at.flatMap(SyncedMessage.date)
        if let remoteCleared, remoteCleared > (clearedAt ?? .distantPast) { clearedAt = remoteCleared }
        let since = clearedAt ?? .distantPast
        var byID: [UUID: InsightMessage] = [:]
        for m in messages where m.date > since { byID[m.id] = m }
        for s in row.messages {
            guard let m = s.message, m.date > since else { continue }
            if var local = byID[m.id] {
                // Same message on both: keep this device's pictures, take the newest decision on its changes.
                if local.applied == nil, m.applied != nil { local.applied = m.applied; local.actionError = m.actionError }
                if m.dismissed == true { local.dismissed = true }
                byID[m.id] = local
            } else {
                byID[m.id] = m
            }
        }
        let merged = byID.values.sorted { $0.date < $1.date }.suffix(200)
        if Array(merged) != messages {
            setMessagesFromSync(Array(merged))
        }
        // Push when this device had something the account didn't.
        if merged.count != row.messages.count || remoteCleared != clearedAt { schedulePush(now: true) }
    }

    /// Saves the conversation in the account a moment after the last change.
    func schedulePush(now: Bool = false) {
        guard supabase.auth.currentUser != nil else { return }
        pushTaskHolder?.cancel()
        pushTaskHolder = Task { [weak self] in
            if !now { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            guard !Task.isCancelled, let self else { return }
            await self.pushConversation()
        }
    }

    private func pushConversation() async {
        guard let user = supabase.auth.currentUser else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let list = messages.suffix(200).map(SyncedMessage.init)
        struct Upsert: Encodable {
            let user_id: String
            let messages: [SyncedMessage]
            let cleared_at: String?
            let updated_at: String
        }
        let row = Upsert(user_id: user.id.uuidString.lowercased(), messages: list,
                         cleared_at: clearedAt.map { formatter.string(from: $0) }, updated_at: formatter.string(from: Date()))
        _ = try? await supabase.from("ai_conversations").upsert(row, onConflict: "user_id").execute()
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
