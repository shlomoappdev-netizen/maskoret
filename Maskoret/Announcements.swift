import SwiftUI
import Supabase

// MARK: - Announcements from the admin

/// A message the admin posted for everyone (public.announcements).
struct Announcement: Decodable, Identifiable, Hashable {
    let id: Int64
    let title: String
    let body: String
    let active: Bool
    let created_at: String
    let expires_at: String?
}

/// The newest active announcement this device hasn't closed, live. Readable without an account.
@MainActor
final class AnnouncementCenter: ObservableObject {
    @Published private(set) var current: Announcement?
    private var all: [Announcement] = []
    private var channel: RealtimeChannelV2?
    private static let closedKey = "closedAnnouncements"

    private var closed: Set<Int64> {
        get { Set((UserDefaults.standard.array(forKey: Self.closedKey) as? [Int64]) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.closedKey) }
    }

    func start() async {
        await refresh()
        guard channel == nil else { return }
        let channel = supabase.channel("announcements")
        let changes = channel.postgresChange(AnyAction.self, schema: "public", table: "announcements")
        self.channel = channel
        await channel.subscribe()
        for await _ in changes { await refresh() }
    }

    func refresh() async {
        do {
            all = try await supabase.from("announcements").select()
                .eq("active", value: true).order("id", ascending: false).limit(10)
                .decoded([Announcement].self)
            pick()
        } catch {
            // Offline: keep what was shown.
        }
    }

    func close(_ announcement: Announcement) {
        closed.insert(announcement.id)
        pick()
    }

    private func pick() {
        let now = Date()
        let closed = closed
        current = all.first { a in
            a.active && !closed.contains(a.id)
                && (a.expires_at.flatMap(ISO8601DateFormatter.flexible).map { $0 > now } ?? true)
        }
    }
}

/// The announcement card at the top of the main screen.
struct AnnouncementBanner: View {
    @EnvironmentObject private var announcements: AnnouncementCenter

    var body: some View {
        if let a = announcements.current {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "megaphone.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(LinearGradient(colors: [.teal, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: a.title).font(.headline)
                    if !a.body.isEmpty {
                        Text(verbatim: a.body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    withAnimation(.snappy) { announcements.close(a) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("סגירה")
                .accessibilityLabel("סגירת ההודעה")
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.teal.opacity(0.35)))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - What's new

/// One version in the published changelog (changelog.json on the releases site, made from CHANGELOG.md).
struct ChangelogEntry: Decodable, Identifiable, Hashable {
    let version: String
    let build: Int
    let date: String?
    let notes: [String]
    var id: Int { build }
}

/// After an update, shows what changed since the build this device last saw (skipped versions included).
@MainActor
final class WhatsNewCenter: ObservableObject {
    @Published var entries: [ChangelogEntry] = []
    static let changelogURL = URL(string: "https://shlomoappdev-netizen.github.io/maskoret-releases/changelog.json")!
    private static let seenKey = "whatsNewSeenBuild"
    private let currentBuild = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0

    var isShown: Binding<Bool> {
        Binding(get: { !self.entries.isEmpty }, set: { if !$0 { self.done() } })
    }

    func check() async {
        let seen = UserDefaults.standard.integer(forKey: Self.seenKey)
        // First run on this device: nothing to compare with.
        guard seen > 0 else {
            UserDefaults.standard.set(currentBuild, forKey: Self.seenKey)
            return
        }
        guard currentBuild > seen, entries.isEmpty else { return }
        var request = URLRequest(url: Self.changelogURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let all = try? JSONDecoder().decode([ChangelogEntry].self, from: data) else {
            return   // offline or not published yet: try on the next launch
        }
        let fresh = all.filter { $0.build > seen && $0.build <= currentBuild }.sorted { $0.build > $1.build }
        if fresh.isEmpty {
            UserDefaults.standard.set(currentBuild, forKey: Self.seenKey)
        } else {
            entries = fresh
        }
    }

    func done() {
        UserDefaults.standard.set(currentBuild, forKey: Self.seenKey)
        entries = []
    }
}

struct WhatsNewSheet: View {
    @EnvironmentObject private var whatsNew: WhatsNewCenter

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    whatsNew.done()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("סגירה")
            }
            .padding([.top, .horizontal], 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.title)
                            .foregroundStyle(.white)
                            .frame(width: 54, height: 54)
                            .background(LinearGradient(colors: [.teal, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Text(verbatim: "מה חדש בגרסה \(whatsNew.entries.first?.version ?? "")")
                            .font(.title2.weight(.bold))
                    }
                    ForEach(whatsNew.entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            if whatsNew.entries.count > 1 {
                                Text(verbatim: "גרסה \(entry.version)").font(.headline).foregroundStyle(.secondary)
                            }
                            ForEach(entry.notes, id: \.self) { note in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal)
                                    Text(verbatim: note).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            Button {
                whatsNew.done()
            } label: {
                Text("הבנתי").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(20)
        }
        #if os(macOS)
        .frame(width: 480, height: 520)
        #endif
        .presentationDetents([.medium, .large])
    }
}

/// Starts the announcements and shows "what's new" once after an update.
struct AppNews: ViewModifier {
    @ObservedObject var announcements: AnnouncementCenter
    @ObservedObject var whatsNew: WhatsNewCenter

    func body(content: Content) -> some View {
        content
            .task { await announcements.start() }
            .task { await whatsNew.check() }
            .sheet(isPresented: whatsNew.isShown) {
                WhatsNewSheet().environmentObject(whatsNew).hebrew()
            }
    }
}

// MARK: - Update available (Mac)

#if os(macOS)
/// Checks for a new version every 3 hours (besides launch and coming back to the app) and offers it once per version.
struct UpdatePrompt: ViewModifier {
    @EnvironmentObject private var updater: Updater
    @State private var offeredBuild = 0
    @State private var showing = false
    private let timer = Timer.publish(every: 3 * 3600, on: .main, in: .common).autoconnect()

    func body(content: Content) -> some View {
        content
            .onReceive(timer) { _ in updater.check() }
            .onChange(of: updater.latest?.build) { _, _ in offer() }
            .alert(Text(verbatim: "גרסה \(updater.latest?.version ?? "") זמינה"), isPresented: $showing) {
                Button("עדכן עכשיו") { updater.buildAndInstall() }
                Button("אחר כך", role: .cancel) {}
            } message: {
                Text(verbatim: (updater.latest?.notes ?? []).prefix(4).map { "• " + $0 }.joined(separator: "\n"))
            }
    }

    private func offer() {
        // The developer's Mac builds from source; the prompt is for everyone who updates from the site.
        guard updater.updatesFromServer, updater.updateAvailable, !updater.isBusy,
              let build = updater.latest?.build, build != offeredBuild else { return }
        offeredBuild = build
        showing = true
    }
}
#endif
