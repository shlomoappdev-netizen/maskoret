import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Charts
import PhotosUI
import UniformTypeIdentifiers

/// A one-tap request on the start screen: the conversation shows `label`; the model gets `prompt`.
struct AIQuickAction: Identifiable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    var prompt: String = ""
    /// Starts the sentence in the text box instead of sending (the user completes it).
    var draft: String? = nil
    /// Asks for a picture first.
    var needsImage = false

    static let all: [AIQuickAction] = [
        AIQuickAction(id: "insights", icon: "sparkles", title: "תובנות על החודש",
                      subtitle: "מה בולט, איפה חורגים ומה לשפר", color: .purple, prompt: InsightsEngine.defaultAnalysis),
        AIQuickAction(id: "savings-photo", icon: "camera.viewfinder", title: "חיסכון מצילום מסך",
                      subtitle: "צלם את פרטי החיסכון וה-AI יכניס אותם", color: .blue,
                      prompt: "בתמונה יש פרטים של חיסכון / פיקדון / פנסיה. הכנס אותם לאפליקציה בדיוק כפי שהם מופיעים בתמונה: אם החשבון כבר קיים — עדכן אותו (יתרה, ריבית, תאריכים, הפקדה חודשית), ואם לא — הוסף חשבון חדש. אם משהו לא ברור בתמונה, שאל.",
                      needsImage: true),
        AIQuickAction(id: "purchase", icon: "cart.fill", title: "צריך לקנות משהו יקר",
                      subtitle: "איך לממן בלי לפגוע בתקציב", color: .orange,
                      draft: "אני צריך לקנות עכשיו "),
        AIQuickAction(id: "limits", icon: "slider.horizontal.3", title: "המלצות למגמות ולחיסכון",
                      subtitle: "תקרות והפקדות שמתאימות למצב", color: .green,
                      prompt: "תסתכל על המגמות, החסכונות וההוצאות הקבועות, והמלץ על תקרות חודשיות למגמות ועל הפקדות לחיסכון שמתאימות להכנסה שלי. הצע את השינויים כפעולות."),
        AIQuickAction(id: "save", icon: "leaf.fill", title: "איפה אפשר לחסוך?",
                      subtitle: "הוצאות שאפשר לצמצם", color: .teal,
                      prompt: "איפה אני יכול לחסוך? תסתכל על ההוצאות הקבועות, האשראי לפי קטגוריה ובתי העסק, ותן לי הצעות קונקרטיות עם סכומים."),
        AIQuickAction(id: "forecast", icon: "chart.line.uptrend.xyaxis", title: "אני בכיוון טוב?",
                      subtitle: "לפי התחזית לחודשים הבאים", color: .pink,
                      prompt: "לפי התחזית לחודשים הבאים — אני בכיוון טוב? מה הסיכונים ומה כדאי לשנות? הוסף תרשים של היתרה הצפויה.")
    ]
}

struct InsightsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ai: InsightsEngine
    @State private var input = ""
    @State private var showSettings = false
    @State private var keyInput = ""
    @State private var pasted = ""
    @State private var attachments: [Data] = []
    @State private var pickingFile = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pickingPhoto = false
    /// A quick action waiting for its picture.
    @State private var pendingAction: AIQuickAction?
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PageBar(title: SidebarItem.insights.title, subtitle: subtitle, guide: .insights) {
                    if !ai.messages.isEmpty {
                        Button {
                            ai.clear()
                        } label: {
                            Label("שיחה חדשה", systemImage: "square.and.pencil")
                        }
                        .disabled(ai.isRunning)
                    }
                    Button {
                        showSettings.toggle()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("הגדרות AI")
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) { settings }
                }
                Divider()
                if ai.connected == false && ai.engine == .cloud {
                    setupBanner
                }
                if ai.messages.isEmpty && !ai.isRunning {
                    welcome
                } else {
                    conversation
                }
                if let undo = ai.undo, ai.messages.contains(where: { $0.id == undo.message }) {
                    undoBar
                }
                if ai.awaitingPaste { pastePanel }
                composer
            }
            .background(Palette.window)
            .navigationTitle("תובנות AI")
            .task {
                await ai.loadModels()
                await ai.pullConversation()
            }
            .onReceive(NotificationCenter.default.publisher(for: Platform.didBecomeActive)) { _ in
                Task { await ai.pullConversation() }
            }
            .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { pendingAction = nil; return }
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) { addImage(data) }
                }
                sendPendingAction()
            }
            .photosPicker(isPresented: $pickingPhoto, selection: $photoItems, maxSelectionCount: 4, matching: .images)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self) { addImage(data) }
                    }
                    photoItems = []
                    sendPendingAction()
                }
            }
        }
    }

    private var subtitle: String {
        if ai.isRunning { return "חושב…" }
        if ai.engine == .cloud, ai.canSend { return ai.activeModelName + " · " + ai.cloudProvider.title }
        return ai.status
    }

    // MARK: Setup

    private var setupBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill").foregroundStyle(.orange)
            Text("כדי לדבר עם ה-AI צריך מפתח API (או לבחור ״ידני״ בהגדרות).")
                .font(.callout)
            Spacer()
            Button("הגדרות…") { showSettings = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: Start screen

    private var welcome: some View {
        ScrollView {
            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 64, height: 64)
                    Image(systemName: "sparkles")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.top, 28)
                VStack(spacing: 6) {
                    Text("במה אפשר לעזור?")
                        .font(.title2.weight(.bold))
                    Text("ה-AI רואה את כל הנתונים באפליקציה, יכול לקרוא צילומי מסך, ומציע שינויים שמתבצעים רק אחרי שתאשר.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(AIQuickAction.all) { action in
                        Button { run(action) } label: { QuickActionTile(action: action) }
                            .buttonStyle(.plain)
                            .disabled(!ai.canSend || ai.isRunning)
                    }
                }
                .frame(maxWidth: 760)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
    }

    private func run(_ action: AIQuickAction) {
        if let draft = action.draft {
            input = draft
            inputFocused = true
            return
        }
        if action.needsImage && attachments.isEmpty {
            pendingAction = action
            #if os(macOS)
            pickingFile = true
            #else
            pickingPhoto = true
            #endif
            return
        }
        ai.send(action.prompt, label: action.title, images: attachments, context: store.aiContext())
        attachments = []
    }

    private func sendPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        guard !attachments.isEmpty else { return }
        run(action)
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(ai.messages) { message in
                        ChatRow(message: message)
                            .id(message.id)
                    }
                    if ai.isRunning {
                        ChatRow(message: InsightMessage(role: "assistant", text: ai.streaming), live: true)
                            .id("live")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                if let last = ai.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: ai.messages.count) { _, _ in
                if let last = ai.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .onChange(of: ai.streaming) { _, _ in
                proxy.scrollTo("live", anchor: .bottom)
            }
        }
    }

    private var undoBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("השינויים בוצעו")
                .font(.callout.weight(.medium))
            Spacer()
            Button("בטל את השינויים") { ai.undoLast(store: store) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.1))
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !ai.messages.isEmpty && !ai.isRunning {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AIQuickAction.all) { action in
                            Button { run(action) } label: {
                                Label(action.title, systemImage: action.icon)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(action.color.opacity(0.12), in: Capsule())
                                    .foregroundStyle(action.color)
                            }
                            .buttonStyle(.plain)
                            .disabled(!ai.canSend)
                        }
                    }
                }
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { index, data in
                            ZStack(alignment: .topLeading) {
                                ImageThumb(data: data, size: 64)
                                Button {
                                    attachments.remove(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                                .padding(3)
                            }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button { pickingPhoto = true } label: { Label("מהתמונות", systemImage: "photo.on.rectangle") }
                    Button { pickingFile = true } label: { Label("מקובץ", systemImage: "folder") }
                    if Platform.hasPastedImage {
                        Button { if let d = Platform.pastedImage() { addImage(d) } } label: { Label("הדבק תמונה", systemImage: "doc.on.clipboard") }
                    }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.title3)
                        .frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("צרף צילום מסך או תמונה")

                TextField("", text: $input, prompt: Text("שאל, בקש שינוי, או צרף צילום מסך…"), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit { ask() }
                    .padding(.vertical, 6)

                if ai.isRunning {
                    Button { ai.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 28))
                    }
                    .buttonStyle(.plain)
                    .help("עצור")
                } else {
                    Button { ask() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(canAsk ? Color.accentColor : Color.secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAsk)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.primary.opacity(0.12)))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: 892)
        .frame(maxWidth: .infinity)
        #if os(macOS)
        .onPasteCommand(of: [.image, .png, .tiff]) { _ in
            if let d = Platform.pastedImage() { addImage(d) }
        }
        #endif
    }

    private var canAsk: Bool {
        ai.canSend && !ai.isRunning && (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private func ask() {
        guard canAsk else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        ai.send(text.isEmpty ? "מה יש בתמונה? אם יש בה נתונים שצריך להכניס לאפליקציה — הצע אותם כפעולות." : text,
                label: text.isEmpty ? "📷 תמונה" : nil, images: attachments, context: store.aiContext())
        input = ""
        attachments = []
    }

    private func addImage(_ data: Data) {
        guard attachments.count < 4, let jpeg = AttachedImage.jpeg(from: data) else { return }
        attachments.append(jpeg)
    }

    // MARK: Manual paste

    private var pastePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            AdaptiveStack(spacing: 8, wideAlignment: .center) {
                Label("השאלה והנתונים הועתקו ללוח", systemImage: "doc.on.clipboard.fill")
                    .font(.callout.weight(.semibold))
                if !Platform.isMac { Spacer(minLength: 0).frame(height: 0) } else { Spacer() }
                HStack {
                    Button("העתק שוב") { ai.copyManualPrompt() }
                    Button("פתח את \(ai.manualSite)") { ai.openManualSite() }
                        .buttonStyle(.borderedProminent)
                }
            }
            Text((ai.messages.last?.pictureCount ?? 0) > 0
                 ? "הדבק באתר, צרף שם גם את התמונה, ואחרי שהתשובה מגיעה העתק אותה עם כפתור ההעתקה והדבק כאן:"
                 : "הדבק באתר. כשהתשובה מגיעה, העתק אותה עם כפתור ההעתקה שמתחת לתשובה והדבק כאן:")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $pasted)
                .font(.callout)
                .frame(minHeight: 70, maxHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            HStack {
                Button("הדבק מהלוח") { pasted = Platform.pastedString() }
                Spacer()
                Button("ביטול") { ai.cancelManual(); pasted = "" }
                Button("שמור תשובה") {
                    ai.submitManualAnswer(pasted)
                    pasted = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pasted == ai.manualPrompt)
            }
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08))
    }

    // MARK: Settings

    private var settings: some View {
        Form {
            Section {
                Picker("מנוע", selection: $ai.engine) {
                    ForEach(AIEngine.available) { Text($0.title).tag($0) }
                }
            }
            if ai.engine == .cloud {
                cloudSettings
            } else {
                Section {
                    Picker("אתר", selection: $ai.manualSite) {
                        ForEach(ManualSite.all, id: \.name) { Text($0.name).tag($0.name) }
                    }
                    Text("כשאתה שואל, השאלה והנתונים מועתקים ללוח. מדביקים באתר (גם בחשבון חינמי), ואת התשובה מדביקים כאן — עם התרשימים והשינויים המוצעים.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Button("בדוק חיבור") { Task { await ai.testConnection() } }
                        .disabled(ai.checkingConnection)
                    if ai.checkingConnection { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("נקה שיחה", role: .destructive) { ai.clear() }
                        .disabled(ai.messages.isEmpty)
                }
                if let check = ai.connectionCheck {
                    Label(check.text, systemImage: check.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(check.ok ? Color.green : Color.orange)
                }
            }
        }
        .formStyle(.grouped)
        .regularWidth(460)
        .hebrew()
        .onDisappear { ai.pushKeySettings() }
    }

    @ViewBuilder
    private var cloudSettings: some View {
        Section("ספק ומפתח") {
            Picker("ספק", selection: $ai.cloudProvider) {
                ForEach(CloudProvider.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: ai.cloudProvider) { _, p in
                ai.cloudBaseURL = p.defaultBaseURL
                ai.cloudModel = ""
                ai.connectionCheck = nil
                keyInput = ""
                Task { await ai.loadModels() }
            }
            HStack {
                SecureField("", text: $keyInput, prompt: Text(ai.hasCloudKey ? "•••••••• (שמור)" : "הדבק כאן את מפתח ה-API"))
                    .labelsHidden()
                    .onSubmit { saveKey() }
                Button("שמור") { saveKey() }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                if ai.hasCloudKey {
                    Button("מחק", role: .destructive) { ai.saveAPIKey("") }
                }
            }
            Toggle("שמור את המפתח בחשבון — זמין בכל המכשירים שלך", isOn: $ai.keyInAccount)
                .onChange(of: ai.keyInAccount) { _, on in
                    if on, let key = ai.apiKey { ai.pushKeySettings(key: key) }
                }
            if let page = ai.cloudProvider.keyPage {
                Link("איפה מקבלים מפתח?", destination: page)
                    .font(.caption)
            }
            if ai.cloudProvider == .custom {
                FormTextField("כתובת ה-API", text: $ai.cloudBaseURL, prompt: Text("https://…/v1"))
            }
        }
        Section("מודל") {
            HStack {
                FormTextField("מודל", text: $ai.cloudModel, prompt: Text(modelHint))
                    .onSubmit { ai.pushKeySettings() }
                if !ai.cloudModels.isEmpty {
                    Menu("בחר") {
                        ForEach(ai.cloudModels, id: \.self) { m in
                            Button(m) { ai.cloudModel = m; ai.pushKeySettings() }
                        }
                    }
                    .fixedSize()
                }
                Button("טען רשימה") { Task { await ai.loadCloudModels() } }
                    .disabled(!ai.hasCloudKey)
            }
            Text("הנתונים הכספיים נשלחים לספק שבחרת רק כשאתה שואל. המפתח נשמר במכשיר" + (ai.keyInAccount ? ", ומוצפן גם בחשבון שלך." : "."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modelHint: String {
        switch ai.cloudProvider {
        case .anthropic: return "למשל: claude-sonnet-5-5"
        case .gemini: return "למשל: gemini-2.5-flash"
        case .openai: return "למשל: gpt-5-mini"
        default: return "שם המודל"
        }
    }

    private func saveKey() {
        let key = keyInput.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        ai.saveAPIKey(key)
        keyInput = ""
        Task {
            await ai.loadCloudModels()
            await ai.testConnection()
        }
    }
}

// MARK: - Start screen tile

private struct QuickActionTile: View {
    let action: AIQuickAction

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: action.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(action.color.gradient, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(action.title).font(.callout.weight(.semibold))
                Text(action.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
    }
}

// MARK: - One message

struct ChatRow: View {
    @EnvironmentObject private var ai: InsightsEngine
    let message: InsightMessage
    var live: Bool = false

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        if isUser { userRow } else { assistantRow }
    }

    private var userRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                if let images = message.images, !images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, data in ImageThumb(data: data, size: 110) }
                    }
                } else if message.pictureCount > 0 {
                    Label(message.pictureCount == 1 ? "תמונה" : "\(message.pictureCount) תמונות", systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                if !(message.label == "📷 תמונה" && message.pictureCount > 0) {
                    Text(verbatim: message.shownText)
                        .textSelection(.enabled)
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 18))
            .frame(maxWidth: 560, alignment: .leading)
            Spacer(minLength: 60)
        }
    }

    private var assistantRow: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 28, height: 28)
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 12) {
                let segments = InsightSegment.parse(message.text)
                if live && (segments.isEmpty || InsightSegment.isThinking(message.text)) {
                    TypingDots()
                }
                ForEach(segments) { segment in
                    switch segment {
                    case .text(let t):
                        MarkdownView(text: t)
                    case .chart(let spec):
                        InsightChart(spec: spec)
                    case .actions(let plan, _):
                        if !live { ActionPlanCard(plan: plan, message: message) }
                    case .broken:
                        if !live {
                            Text("(ה-AI ניסה להוסיף תרשים או שינוי, אבל הנתונים שלו לא היו תקינים)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !live {
                    HStack(spacing: 12) {
                        Button {
                            Platform.copy(InsightSegment.withoutThinking(message.text))
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("העתק")
                        Text(verbatim: (message.model.map { $0 + " · " } ?? "") + message.date.formatted(.dateTime.day().month().hour().minute().locale(Fmt.locale)))
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Three dots that pulse while the model is working.
private struct TypingDots: View {
    @State private var phase = 0.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.15)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 7, height: 7)
                        .opacity(0.3 + 0.7 * max(0, sin(t * 4 - Double(i) * 0.8)))
                }
            }
            .padding(.vertical, 6)
        }
    }
}

struct ImageThumb: View {
    let data: Data
    var size: CGFloat

    var body: some View {
        Group {
            #if os(macOS)
            if let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFill() } else { Color.secondary }
            #else
            if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill() } else { Color.secondary }
            #endif
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Proposed changes

struct ActionPlanCard: View {
    @EnvironmentObject private var ai: InsightsEngine
    @EnvironmentObject private var store: Store
    let plan: AIActionPlan
    let message: InsightMessage
    @State private var chosen: Set<Int>? = nil

    private var applied: [Int]? { message.applied }
    private var isOpen: Bool { applied == nil && message.dismissed != true }
    private var selection: Set<Int> { chosen ?? Set(plan.actions.map(\.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "wand.and.stars").foregroundStyle(.purple)
                Text(plan.summary.isEmpty ? "שינויים מוצעים" : plan.summary)
                    .font(.callout.weight(.semibold))
                Spacer()
                if let applied {
                    Label(applied.isEmpty ? "לא בוצע" : "בוצע", systemImage: applied.isEmpty ? "xmark.circle" : "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(applied.isEmpty ? Color.orange : Color.green)
                } else if message.dismissed == true {
                    Text("נדחה").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(plan.actions) { action in
                HStack(alignment: .top, spacing: 10) {
                    if isOpen {
                        Button {
                            var s = selection
                            if s.contains(action.id) { s.remove(action.id) } else { s.insert(action.id) }
                            chosen = s
                        } label: {
                            Image(systemName: selection.contains(action.id) ? "checkmark.square.fill" : "square")
                                .font(.title3)
                                .foregroundStyle(selection.contains(action.id) ? Color.purple : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    } else if applied?.contains(action.id) == true {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Image(systemName: "circle").foregroundStyle(.tertiary)
                    }
                    Image(systemName: action.icon)
                        .foregroundStyle(.white)
                        .font(.caption)
                        .frame(width: 24, height: 24)
                        .background(Color.purple.gradient, in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: action.title).font(.callout.weight(.medium))
                        ForEach(action.details, id: \.self) { line in
                            Text(verbatim: line).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            if let error = message.actionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if isOpen {
                if store.isCombined, let me = store.activeMember {
                    Text(verbatim: "השינויים יחולו על הנתונים של " + me.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        ai.apply(plan, only: selection, in: message.id, store: store)
                    } label: {
                        Label(selection.count == plan.actions.count ? "אשר ובצע" : "בצע \(selection.count) מתוך \(plan.actions.count)",
                              systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(selection.isEmpty)
                    Button("לא עכשיו") { ai.dismiss(message.id) }
                }
            }
        }
        .padding(14)
        .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.purple.opacity(0.25)))
    }
}

// MARK: - Chart

struct InsightChart: View {
    let spec: ChartSpec

    struct Slice: Identifiable {
        let id: Int
        let label: String
        let value: Double
    }

    static let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .yellow, .red, .indigo, .mint, .brown, .cyan]

    private var points: [ChartSpec.Point] { Array(spec.data.prefix(12)) }
    private var slices: [Slice] { points.enumerated().map { Slice(id: $0.offset, label: $0.element.label, value: $0.element.value) } }
    private func color(_ i: Int) -> Color { InsightChart.colors[i % InsightChart.colors.count] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = spec.title, !title.isEmpty {
                Text(verbatim: title).font(.headline)
            }
            switch spec.type.lowercased() {
            case "pie", "donut":
                AdaptiveStack(spacing: 16, compactAlignment: .center, wideAlignment: .center) {
                    Chart(slices) { s in
                        SectorMark(angle: .value("סכום", max(s.value, 0)), innerRadius: .ratio(0.58), angularInset: 2)
                            .cornerRadius(4)
                            .foregroundStyle(color(s.id).gradient)
                    }
                    .frame(width: 180, height: 180)
                    legend
                }
            case "line":
                Chart(points, id: \.label) { p in
                    AreaMark(x: .value("שם", p.label), y: .value("סכום", p.value))
                        .foregroundStyle(LinearGradient(colors: [Color.blue.opacity(0.35), Color.blue.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("שם", p.label), y: .value("סכום", p.value))
                        .foregroundStyle(Color.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .interpolationMethod(.catmullRom)
                    PointMark(x: .value("שם", p.label), y: .value("סכום", p.value))
                        .foregroundStyle(Color.blue)
                        .annotation(position: .top) {
                            Text(verbatim: Fmt.compact(p.value)).font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .frame(height: 210)
            default:
                Chart(slices) { s in
                    BarMark(x: .value("שם", s.label), y: .value("סכום", s.value))
                        .cornerRadius(6)
                        .foregroundStyle(color(s.id).gradient)
                        .annotation(position: .top) {
                            Text(verbatim: Fmt.compact(s.value)).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        }
                }
                .frame(height: 230)
            }
        }
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var legend: some View {
        let total = max(points.reduce(0) { $0 + max($1.value, 0) }, 1)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(slices) { p in
                HStack {
                    Circle().fill(color(p.id)).frame(width: 9, height: 9)
                    Text(verbatim: p.label)
                    Spacer()
                    Text(verbatim: Fmt.money(p.value) + " · " + Fmt.percent((p.value / total * 100).rounded()))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }
}
