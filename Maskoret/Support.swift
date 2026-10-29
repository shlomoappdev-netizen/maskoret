import Foundation
import SwiftUI
import Supabase
#if os(iOS)
import UIKit
#endif

// MARK: - App log

/// A short technical log of what the app did (sync, errors), kept in a file in Caches so it survives a crash.
/// It is sent only when the user attaches it to a support message.
enum AppLog {
    private static let lock = NSLock()
    private static let maxBytes = 250_000

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("maskoret-log.txt")
    }

    static func add(_ category: String, _ message: String) {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        let line = "\(stamp) [\(category)] \(message.replacingOccurrences(of: "\n", with: " "))\n"
        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: fileURL)
        }
    }

    /// The newest part of the log (trims the file when it grew too big).
    static func recent() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return "" }
        let tail = data.count > maxBytes ? data.suffix(maxBytes) : data
        if data.count > maxBytes * 2 { try? tail.write(to: fileURL) }
        return String(decoding: tail, as: UTF8.self)
    }
}

// MARK: - Diagnostics

/// What a support message tells about the device (always sent) and the full report (only when logs are attached).
enum Diagnostics {
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    static var platform: String {
        #if os(iOS)
        return "iOS \(UIDevice.current.systemVersion)"
        #else
        return "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #endif
    }

    @MainActor
    static func appInfo(memberNo: Int64?) -> [String: AnyJSON] {
        var info: [String: AnyJSON] = [
            "version": .string(appVersion),
            "platform": .string(platform),
            "device": .string(Platform.deviceName)
        ]
        if let memberNo { info["member_no"] = .integer(Int(memberNo)) }
        return info
    }

    @MainActor
    static func report(account: UserAccount, sync: ServerSync) -> String {
        var lines = [
            "גרסה: \(appVersion)",
            "מערכת: \(platform)",
            "מכשיר: \(Platform.deviceName)",
            "מספר מנוי: \(account.memberNo.map(String.init) ?? "—")",
            "חשבון: \(account.userID?.uuidString ?? "—")",
            "משק בית פעיל: \(account.activeHouseholdID?.uuidString ?? "—")",
            "משקי בית: \(account.households.map { "\($0.name) [\($0.role)] rev \($0.revision)" }.joined(separator: " | "))",
            "סנכרון אחרון: \(sync.lastSync.map { $0.formatted(.iso8601) } ?? "—")",
            "שגיאת סנכרון: \(sync.lastError ?? "אין")"
        ]
        lines.append("")
        lines.append("— יומן —")
        lines.append(AppLog.recent())
        return lines.joined(separator: "\n")
    }
}

// MARK: - Models

struct SupportThread: Decodable, Identifiable, Hashable {
    let id: UUID
    let user_id: UUID
    let subject: String
    let category: String
    let status: String
    let created_at: String
    let last_message_at: String
    let user_unread: Int
    let admin_unread: Int

    var isOpen: Bool { status == "open" }
    var lastMessageDate: Date? { ISO8601DateFormatter.flexible(last_message_at) }

    static let categories: [(id: String, title: String, icon: String)] = [
        ("bug", "תקלה", "ladybug"),
        ("question", "שאלה", "questionmark.bubble"),
        ("idea", "רעיון לשיפור", "lightbulb"),
        ("other", "אחר", "ellipsis.bubble")
    ]

    static func title(of category: String) -> String {
        categories.first { $0.id == category }?.title ?? category
    }

    static func icon(of category: String) -> String {
        categories.first { $0.id == category }?.icon ?? "bubble.left"
    }
}

struct SupportMessage: Decodable, Identifiable, Hashable {
    let id: Int64
    let thread_id: UUID
    let sender: UUID?
    let from_admin: Bool
    let body: String
    let log: String?
    let created_at: String

    var date: Date? { ISO8601DateFormatter.flexible(created_at) }
}

// MARK: - Support center

/// The signed-in user's support threads, and the unread badge (for the admin: every thread waiting for an answer).
@MainActor
final class SupportCenter: ObservableObject {
    @Published private(set) var threads: [SupportThread] = []
    @Published private(set) var unread = 0
    @Published private(set) var adminUnread = 0

    private var channel: RealtimeChannelV2?
    private var listenTask: Task<Void, Never>?
    private var listeningAs: UUID?
    private var listeningAsAdmin = false

    /// Called whenever the signed-in user changes (nil after sign-out).
    func start(userID: UUID?, isAdmin: Bool) async {
        guard listeningAs != userID || listeningAsAdmin != isAdmin else { return }
        await stop()
        threads = []
        unread = 0
        adminUnread = 0
        guard let userID else { return }
        listeningAs = userID
        listeningAsAdmin = isAdmin
        await refresh(isAdmin: isAdmin)
        // Row-level security sends each user only their own threads (and the admin all of them).
        let channel = supabase.channel("support-\(userID.uuidString.lowercased())")
        let changes = channel.postgresChange(AnyAction.self, schema: "public", table: "support_threads")
        self.channel = channel
        await channel.subscribe()
        listenTask = Task { [weak self] in
            for await _ in changes {
                await self?.refresh(isAdmin: isAdmin)
            }
        }
    }

    func stop() async {
        listenTask?.cancel()
        listenTask = nil
        if let channel { await supabase.removeChannel(channel) }
        channel = nil
        listeningAs = nil
    }

    func refresh(isAdmin: Bool) async {
        guard let me = listeningAs else { return }
        if let mine: [SupportThread] = try? await supabase.from("support_threads").select()
            .eq("user_id", value: me).order("last_message_at", ascending: false).decoded([SupportThread].self) {
            threads = mine
            unread = mine.reduce(0) { $0 + $1.user_unread }
        }
        if isAdmin, let stats = try? await supabase.rpc("admin_stats").decoded(AdminStats.self) {
            adminUnread = stats.unread_threads
        }
    }

    func openThread(subject: String, category: String, body: String, log: String?, memberNo: Int64?) async throws -> UUID {
        struct Params: Encodable {
            let p_subject: String, p_category: String, p_body: String, p_log: String?, p_app_info: [String: AnyJSON]
        }
        let params = Params(p_subject: subject, p_category: category, p_body: body, p_log: log,
                            p_app_info: Diagnostics.appInfo(memberNo: memberNo))
        let id = try await supabase.rpc("support_open_thread", params: params).decoded(UUID.self)
        AppLog.add("support", "נפתחה פנייה \(id.uuidString)")
        return id
    }

    func send(thread: UUID, body: String, log: String?) async throws {
        struct Params: Encodable { let p_thread: UUID, p_body: String, p_log: String? }
        try await supabase.rpc("support_send", params: Params(p_thread: thread, p_body: body, p_log: log)).execute()
    }

    func markRead(thread: UUID) async {
        _ = try? await supabase.rpc("support_mark_read", params: ["p_thread": thread]).execute()
    }

    func setStatus(thread: UUID, open: Bool) async throws {
        struct Params: Encodable { let p_thread: UUID, p_status: String }
        try await supabase.rpc("support_set_status", params: Params(p_thread: thread, p_status: open ? "open" : "closed"))
            .execute()
    }

    static func messages(in thread: UUID) async throws -> [SupportMessage] {
        try await supabase.from("support_messages").select()
            .eq("thread_id", value: thread).order("id").decoded([SupportMessage].self)
    }

    static func thread(_ id: UUID) async throws -> SupportThread {
        try await supabase.from("support_threads").select().eq("id", value: id).single().decoded(SupportThread.self)
    }
}

struct AdminStats: Decodable {
    let users: Int
    let new_7d: Int
    let active_7d: Int
    let households: Int
    let open_threads: Int
    let unread_threads: Int
}
