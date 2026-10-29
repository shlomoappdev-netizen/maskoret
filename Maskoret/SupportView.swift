import SwiftUI
import Supabase

/// "תמיכה ודיווח תקלות": the user's conversations with support, a new report, and their subscriber number.
struct SupportView: View {
    @EnvironmentObject private var account: UserAccount
    @EnvironmentObject private var support: SupportCenter
    @State private var composing = false
    @State private var openThread: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MemberNumberRow()
                    Button {
                        composing = true
                    } label: {
                        Label("פנייה חדשה", systemImage: "square.and.pencil")
                    }
                } footer: {
                    Text("כותבים לנו כאן על תקלה, שאלה או רעיון, ומקבלים תשובה בתוך האפליקציה. כדאי לצרף את היומן הטכני כשמשהו לא עובד — הוא עוזר לנו להבין מה קרה.")
                }

                Section("הפניות שלי") {
                    if support.threads.isEmpty {
                        Text("עוד לא פתחת פניות.").foregroundStyle(.secondary)
                    }
                    ForEach(support.threads) { thread in
                        NavigationLink(value: thread.id) {
                            ThreadRow(thread: thread, unread: thread.user_unread)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("תמיכה ודיווח תקלות")
            .navigationDestination(for: UUID.self) { id in
                SupportChatView(threadID: id, asAdmin: false)
            }
            .navigationDestination(isPresented: Binding(get: { openThread != nil }, set: { if !$0 { openThread = nil } })) {
                if let openThread { SupportChatView(threadID: openThread, asAdmin: false) }
            }
            .task { await support.refresh(isAdmin: account.isAdmin) }
            .refreshable { await support.refresh(isAdmin: account.isAdmin) }
            .sheet(isPresented: $composing) {
                NewSupportThreadSheet { id in openThread = id }
            }
        }
    }
}

/// The subscriber number, with a copy button — users quote it when they write to support.
struct MemberNumberRow: View {
    @EnvironmentObject private var account: UserAccount
    @State private var copied = false

    var body: some View {
        LabeledContent("מספר מנוי") {
            HStack(spacing: 8) {
                Text(verbatim: account.memberNo.map(String.init) ?? "—")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .textSelection(.enabled)
                if let no = account.memberNo {
                    Button {
                        Platform.copy(String(no))
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("העתקה")
                }
            }
        }
    }
}

struct ThreadRow: View {
    let thread: SupportThread
    let unread: Int
    var subtitle: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: SupportThread.icon(of: thread.category))
                .foregroundStyle(thread.isOpen ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: thread.subject).font(.body.weight(unread > 0 ? .semibold : .regular)).lineLimit(1)
                Text(verbatim: [subtitle, SupportThread.title(of: thread.category), thread.isOpen ? "פתוחה" : "סגורה",
                                thread.lastMessageDate.map(SupportChatView.shortDate)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if unread > 0 {
                Text(verbatim: "\(unread)")
                    .font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
            }
        }
    }
}

// MARK: - New report

struct NewSupportThreadSheet: View {
    @EnvironmentObject private var account: UserAccount
    @EnvironmentObject private var sync: ServerSync
    @EnvironmentObject private var support: SupportCenter
    @Environment(\.dismiss) private var dismiss

    var onCreated: (UUID) -> Void

    @State private var category = "bug"
    @State private var subject = ""
    @State private var message = ""
    @State private var attachLog = true
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        SheetContainer(title: "פנייה חדשה", saveTitle: sending ? "שולח…" : "שליחה", onSave: send) {
            Section {
                Picker("סוג", selection: $category) {
                    ForEach(SupportThread.categories, id: \.id) { c in
                        Label(c.title, systemImage: c.icon).tag(c.id)
                    }
                }
                FormTextField("נושא", text: $subject, prompt: Text("במשפט אחד"))
            }
            Section("מה קרה?") {
                TextEditor(text: $message)
                    .frame(minHeight: 140)
            }
            Section {
                Toggle("לצרף יומן טכני", isOn: $attachLog)
                if let error {
                    Text(error).foregroundStyle(.orange).font(.callout)
                }
            } footer: {
                Text("היומן כולל את גרסת האפליקציה, סוג המכשיר, מצב הסנכרון ושגיאות אחרונות. הנתונים הכספיים שלך לא נשלחים.")
            }
        }
        .onChange(of: category) { _, c in attachLog = (c == "bug") }
    }

    private func send() {
        let subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty, !body.isEmpty else { error = "צריך למלא נושא ותיאור."; return }
        guard !sending else { return }
        sending = true
        let log = attachLog ? Diagnostics.report(account: account, sync: sync) : nil
        Task {
            defer { sending = false }
            do {
                let id = try await support.openThread(subject: subject, category: category, body: body, log: log,
                                                      memberNo: account.memberNo)
                await support.refresh(isAdmin: account.isAdmin)
                dismiss()
                onCreated(id)
            } catch {
                self.error = UserAccount.describe(error)
            }
        }
    }
}

// MARK: - Conversation

/// One support conversation, live. The admin sees the same screen with the user's details and the attached logs.
struct SupportChatView: View {
    let threadID: UUID
    let asAdmin: Bool

    @EnvironmentObject private var account: UserAccount
    @EnvironmentObject private var sync: ServerSync
    @EnvironmentObject private var support: SupportCenter

    @State private var thread: SupportThread?
    @State private var messages: [SupportMessage] = []
    @State private var draft = ""
    @State private var attachLog = false
    @State private var sending = false
    @State private var error: String?
    @State private var shownLog: String?
    @State private var channel: RealtimeChannelV2?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if let thread {
                            Text(verbatim: SupportThread.title(of: thread.category) + " · נפתחה "
                                 + (ISO8601DateFormatter.flexible(thread.created_at).map(Self.shortDate) ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                        ForEach(messages) { message in
                            bubble(message).id(message.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider()
            composer
        }
        .navigationTitle(thread?.subject ?? "פנייה")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let thread {
                ToolbarItem {
                    Button(thread.isOpen ? "סגירת הפנייה" : "פתיחה מחדש") {
                        Task {
                            try? await support.setStatus(thread: threadID, open: !thread.isOpen)
                            await load()
                        }
                    }
                }
            }
        }
        .task { await start() }
        .onDisappear {
            if let channel { Task { await supabase.removeChannel(channel) } }
        }
        .sheet(isPresented: Binding(get: { shownLog != nil }, set: { if !$0 { shownLog = nil } })) {
            LogSheet(text: shownLog ?? "")
        }
    }

    private func bubble(_ message: SupportMessage) -> some View {
        // My messages on one side, the other party's on the other (support for the user; the user for the admin).
        let mine = message.from_admin == asAdmin
        return HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: message.from_admin ? (asAdmin ? "אתה (תמיכה)" : "צוות התמיכה") : (asAdmin ? "המנוי" : "אתה"))
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(verbatim: message.body).textSelection(.enabled)
                if let log = message.log, !log.isEmpty {
                    Button {
                        shownLog = log
                    } label: {
                        Label("יומן טכני מצורף", systemImage: "doc.text.magnifyingglass").font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                Text(verbatim: message.date.map(Self.shortDate) ?? "")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(mine ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !mine { Spacer(minLength: 40) }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if !asAdmin {
                    Button {
                        attachLog.toggle()
                    } label: {
                        Image(systemName: attachLog ? "paperclip.circle.fill" : "paperclip")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .help(attachLog ? "היומן הטכני יצורף להודעה" : "לצרף יומן טכני")
                }
                TextField("הודעה", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            }
            if attachLog {
                Text("היומן הטכני יצורף להודעה").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private func start() async {
        await load()
        let channel = supabase.channel("support-thread-\(threadID.uuidString.lowercased())")
        let inserts = channel.postgresChange(InsertAction.self, schema: "public", table: "support_messages",
                                             filter: "thread_id=eq.\(threadID.uuidString.lowercased())")
        self.channel = channel
        await channel.subscribe()
        for await _ in inserts {
            await load()
        }
    }

    private func load() async {
        do {
            async let t = SupportCenter.thread(threadID)
            async let m = SupportCenter.messages(in: threadID)
            (thread, messages) = try await (t, m)
            let unread = asAdmin ? (thread?.admin_unread ?? 0) : (thread?.user_unread ?? 0)
            if unread > 0 {
                await support.markRead(thread: threadID)
                await support.refresh(isAdmin: account.isAdmin)
            }
        } catch is CancellationError {
        } catch {
            self.error = UserAccount.describe(error)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        let log = attachLog ? Diagnostics.report(account: account, sync: sync) : nil
        Task {
            defer { sending = false }
            do {
                try await support.send(thread: threadID, body: text, log: log)
                draft = ""
                attachLog = false
                error = nil
                await load()
            } catch {
                self.error = UserAccount.describe(error)
            }
        }
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month().hour().minute().locale(Fmt.locale))
    }
}

/// An attached log, readable and copyable.
struct LogSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(verbatim: text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("יומן טכני")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("סגור") { dismiss() } }
                ToolbarItem { Button("העתקה") { Platform.copy(text) } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
    }
}
