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
    // Admin: the conversation with Claude beside the subscriber's — every proposal and question, in order.
    @State private var proposals: [SupportProposal] = []
    @State private var questions: [SupportAIQuestion] = []
    /// The option whose reply is in the message box (its action runs when it is sent).
    @State private var chosen: SupportProposal.Option?
    /// The option shown open in Claude's card ("<proposal>-<option>"; nil opens the recommended one).
    @State private var openOption: String?
    /// Admin: the message box writes to Claude instead of the subscriber.
    @State private var toClaude = false

    private enum Item: Identifiable {
        case message(SupportMessage)
        case question(SupportAIQuestion)
        case proposal(SupportProposal)

        var id: String {
            switch self {
            case .message(let m): "m\(m.id)"
            case .question(let q): "q\(q.id)"
            case .proposal(let p): "p\(p.id)"
            }
        }

        var date: Date {
            switch self {
            case .message(let m): m.date ?? .distantPast
            case .question(let q): q.date ?? .distantPast
            case .proposal(let p): p.date ?? .distantPast
            }
        }
    }

    private var items: [Item] {
        (messages.map(Item.message) + questions.map(Item.question) + proposals.map(Item.proposal))
            .sorted { $0.date < $1.date }
    }

    private var openProposal: SupportProposal? { proposals.last(where: \.isPending) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if let thread {
                            Text(verbatim: SupportThread.title(of: thread.category) + " · נפתחה "
                                 + (ISO8601DateFormatter.flexible(thread.created_at).map(Self.shortDate) ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                        ForEach(items) { item in
                            switch item {
                            case .message(let message): bubble(message)
                            case .question(let question): questionBubble(question)
                            case .proposal(let proposal): claudeCard(proposal)
                            }
                        }
                        if asAdmin { claudeStatus }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
                .onChange(of: items.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: thread?.ai_pending) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
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

    // MARK: Claude (admin only)

    /// One of Claude's turns: what it understood, and — while it is open — the options as large cards.
    private func claudeCard(_ proposal: SupportProposal) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ClaudeBadge()
                Text("Claude").font(.subheadline.weight(.semibold))
                Text("· רק אתה רואה").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: proposal.date.map(Self.shortDate) ?? "").font(.caption2).foregroundStyle(.secondary)
            }
            Text(verbatim: proposal.summary)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if proposal.isPending {
                ForEach(Array(proposal.options.enumerated()), id: \.element.id) { index, option in
                    optionCard(option, in: proposal, recommended: index == 0 && proposal.options.count > 1)
                }
                HStack(spacing: 16) {
                    Button {
                        chosen = nil
                        toClaude = false
                        aiRun { try await AdminAPI.decide(proposal.id, status: "dismissed") }
                    } label: {
                        Label("אכתוב בעצמי", systemImage: "pencil")
                    }
                    Button {
                        toClaude = true
                    } label: {
                        Label("לשאול את Claude", systemImage: "questionmark.bubble")
                    }
                    Spacer()
                    Button(role: .destructive) {
                        chosen = nil
                        aiRun { try await AdminAPI.setAIMode(thread: threadID, on: false) }
                    } label: {
                        Label("בלי AI בפנייה הזו", systemImage: "nosign")
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            } else {
                decidedFooter(proposal)
            }
        }
        .padding(14)
        .background(LinearGradient(colors: [Color.purple.opacity(0.11), Color.indigo.opacity(0.05)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), in: shape)
        .overlay(shape.strokeBorder(Color.purple.opacity(proposal.isPending ? 0.3 : 0.15)))
    }

    private func optionCard(_ option: SupportProposal.Option, in proposal: SupportProposal, recommended: Bool) -> some View {
        let key = "\(proposal.id)-\(option.id)"
        let current = openOption.flatMap { $0.hasPrefix("\(proposal.id)-") ? $0 : nil }
            ?? proposal.options.first.map { "\(proposal.id)-\($0.id)" }
        let isOpen = current == key
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { openOption = isOpen ? "\(proposal.id)-" : key }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: Self.icon(option.action))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Self.tint(option.action).gradient, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(verbatim: option.title).font(.callout.weight(.semibold))
                            if recommended {
                                Text("מומלץ")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.purple)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.purple.opacity(0.15), in: Capsule())
                            }
                        }
                        if !option.explanation.isEmpty {
                            Text(verbatim: option.explanation)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                if let reply = option.reply {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("התשובה שתישלח למנוי").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(verbatim: reply)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if let label = option.actionLabel {
                    Label(label, systemImage: "bolt.fill").font(.caption).foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    Button {
                        Task { await carryOut(option, reply: option.reply) }
                    } label: {
                        Label(Self.goTitle(option), systemImage: option.reply == nil ? "bolt.fill" : "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    if option.reply != nil {
                        Button {
                            chosen = option
                            draft = option.reply ?? ""
                            toClaude = false
                        } label: {
                            Label("עריכה לפני שליחה", systemImage: "pencil").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .controlSize(.large)
                .disabled(sending)
            }
        }
        .padding(12)
        .background(.background.opacity(isOpen ? 0.95 : 0.6), in: shape)
        .overlay(shape.strokeBorder(isOpen ? Color.purple.opacity(0.5) : Color.secondary.opacity(0.15), lineWidth: isOpen ? 1.5 : 1))
    }

    /// What became of an earlier proposal, with its options folded away.
    @ViewBuilder private func decidedFooter(_ proposal: SupportProposal) -> some View {
        switch proposal.status {
        case "chosen":
            Label {
                Text(verbatim: "בחרת: " + (proposal.chosen?.title ?? ""))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.green)
            if proposal.chosen?.action == "dev_task" {
                Label("נרשמה משימת פיתוח: היא תופיע כשתפתח את Claude Code בפרויקט, ובלשונית \"משימות פיתוח\".",
                      systemImage: "hammer")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case "dismissed":
            Label("ענית בעצמך", systemImage: "pencil.circle").font(.caption).foregroundStyle(.secondary)
        default:
            Label("הוחלפה: הגיעה אחריה תשובה או הודעה חדשה", systemImage: "arrow.uturn.down.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
        if !proposal.options.isEmpty {
            DisclosureGroup("האפשרויות שהוצעו (\(proposal.options.count))") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(proposal.options) { option in
                        Label {
                            Text(verbatim: option.title + (option.explanation.isEmpty ? "" : " · " + option.explanation))
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: Self.icon(option.action)).foregroundStyle(Self.tint(option.action))
                        }
                    }
                }
                .font(.caption)
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }

    /// A question the admin asked Claude (the subscriber does not see it).
    private func questionBubble(_ question: SupportAIQuestion) -> some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .leading, spacing: 4) {
                Label("שאלה ל-Claude", systemImage: "sparkles")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.purple)
                Text(verbatim: question.body).textSelection(.enabled)
                Text(verbatim: (question.date.map(Self.shortDate) ?? "") + (question.answered_at == nil ? " · ממתינה לתשובה" : ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.purple.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// The bottom of the conversation: Claude at work, or Claude turned off for this thread.
    @ViewBuilder private var claudeStatus: some View {
        if let thread {
            if thread.ai_pending == true {
                HStack(spacing: 10) {
                    ClaudeBadge()
                    ProgressView().controlSize(.small)
                    Text(questions.contains { $0.answered_at == nil } ? "Claude בודק את השאלה שלך…" : "Claude מנתח את הפנייה…")
                        .font(.callout)
                    Spacer()
                    Text("רץ על המק כשהוא דלוק").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if thread.ai_mode == "off" {
                HStack(spacing: 6) {
                    Image(systemName: "nosign")
                    Text("Claude לא מטפל בפנייה הזו.")
                    Spacer()
                    Button("להפעיל ולבקש הצעה") { aiRun { try await AdminAPI.requestProposal(thread: threadID) } }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
            }
        }
    }

    private static func icon(_ action: String) -> String {
        switch action {
        case "confirm_email": "checkmark.seal.fill"
        case "sign_out_user": "rectangle.portrait.and.arrow.right"
        case "dev_task": "hammer.fill"
        default: "text.bubble.fill"
        }
    }

    private static func tint(_ action: String) -> Color {
        switch action {
        case "confirm_email": .green
        case "sign_out_user": .orange
        case "dev_task": .indigo
        default: .blue
        }
    }

    private static func goTitle(_ option: SupportProposal.Option) -> String {
        switch (option.actionLabel != nil, option.reply != nil) {
        case (true, true): "ביצוע ושליחה"
        case (true, false): "ביצוע"
        default: "שליחה למנוי"
        }
    }

    /// Runs the option's action, records the decision, then sends the reply (if any).
    private func carryOut(_ option: SupportProposal.Option, reply: String?) async {
        guard let thread, let proposal = openProposal else { return }
        sending = true
        defer { sending = false }
        do {
            try await AdminAPI.perform(option, thread: thread)
            try await AdminAPI.decide(proposal.id, status: "chosen", option: option.id)
            if let reply { try await support.send(thread: threadID, body: reply, log: nil) }
            chosen = nil
            draft = ""
            error = nil
            await load()
        } catch {
            self.error = UserAccount.describe(error)
        }
    }

    private func aiRun(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                await load()
            } catch {
                self.error = UserAccount.describe(error)
            }
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
            if asAdmin {
                HStack {
                    Picker("", selection: $toClaude) {
                        Text("תשובה למנוי").tag(false)
                        Text("שאלה ל-Claude").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Menu {
                        Button("הצעה חדשה מ-Claude", systemImage: "arrow.clockwise") {
                            aiRun { try await AdminAPI.requestProposal(thread: threadID) }
                        }
                        if thread?.ai_mode == "off" {
                            Button("להפעיל את Claude בפנייה הזו", systemImage: "sparkles") {
                                aiRun { try await AdminAPI.setAIMode(thread: threadID, on: true) }
                            }
                        } else {
                            Button("בלי AI בפנייה הזו", systemImage: "nosign") {
                                chosen = nil
                                aiRun { try await AdminAPI.setAIMode(thread: threadID, on: false) }
                            }
                        }
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
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
                TextField(toClaude ? "שאלה ל-Claude על הפנייה (המנוי לא רואה)" : "הודעה", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.purple.opacity(toClaude ? 0.6 : 0), lineWidth: 1.5))
                    .onSubmit(send)
                Button {
                    send()
                } label: {
                    Image(systemName: toClaude ? "sparkles.rectangle.stack.fill" : "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .tint(toClaude ? .purple : .accentColor)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            }
            if attachLog {
                Text("היומן הטכני יצורף להודעה").font(.caption2).foregroundStyle(.secondary)
            }
            if let chosen, !toClaude {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text(verbatim: "הצעה נבחרה: \(chosen.title)" + (chosen.actionLabel.map { " · בשליחה יבוצע גם: \($0)" } ?? ""))
                        .lineLimit(2)
                    Spacer()
                    Button {
                        self.chosen = nil
                        draft = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private func start() async {
        await load()
        let filter = "thread_id=eq.\(threadID.uuidString.lowercased())"
        let channel = supabase.channel("support-thread-\(threadID.uuidString.lowercased())")
        let inserts = channel.postgresChange(InsertAction.self, schema: "public", table: "support_messages", filter: filter)
        self.channel = channel
        // The admin also follows Claude's proposals, their own questions to it and the thread's AI state.
        let proposals = channel.postgresChange(AnyAction.self, schema: "public", table: "support_proposals", filter: filter)
        let questions = channel.postgresChange(AnyAction.self, schema: "public", table: "support_ai_questions", filter: filter)
        let threadChanges = channel.postgresChange(UpdateAction.self, schema: "public", table: "support_threads",
                                                   filter: "id=eq.\(threadID.uuidString.lowercased())")
        await channel.subscribe()
        let changes = AsyncStream<Void> { continuation in
            Task { for await _ in inserts { continuation.yield() } }
            Task { for await _ in proposals { continuation.yield() } }
            Task { for await _ in questions { continuation.yield() } }
            Task { for await _ in threadChanges { continuation.yield() } }
        }
        for await _ in changes {
            await load()
        }
    }

    private func load() async {
        do {
            async let t = SupportCenter.thread(threadID)
            async let m = SupportCenter.messages(in: threadID)
            (thread, messages) = try await (t, m)
            if asAdmin {
                async let p = AdminAPI.proposals(thread: threadID)
                async let q = AdminAPI.questions(thread: threadID)
                (proposals, questions) = try await (p, q)
                if let chosen, !(openProposal?.options.contains(chosen) ?? false) { self.chosen = nil }
            }
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
        if asAdmin, toClaude {
            sending = true
            Task {
                defer { sending = false }
                do {
                    try await AdminAPI.ask(thread: threadID, question: text)
                    draft = ""
                    error = nil
                    await load()
                } catch {
                    self.error = UserAccount.describe(error)
                }
            }
            return
        }
        if asAdmin, let chosen {
            Task { await carryOut(chosen, reply: text) }
            return
        }
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

/// Claude's mark in the admin's conversation.
private struct ClaudeBadge: View {
    var body: some View {
        Image(systemName: "sparkles")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: Circle())
    }
}
