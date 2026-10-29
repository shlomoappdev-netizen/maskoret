import SwiftUI
#if os(macOS)
import AppKit
#endif
import Charts

struct InsightsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ai: InsightsEngine
    @State private var input = ""
    @State private var showSettings = false
    @State private var keyInput = ""
    @State private var pasted = ""

    private let quickPrompts: [String] = [
        "סכם לי את החודש",
        "איפה אפשר לחסוך?",
        "תרשים של ההוצאות המשתנות לפי קטגוריה",
        "האם אני בכיוון טוב לפי התחזית?",
        "שאל אותי שאלות כדי לבנות תקציב מסודר"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PageBar(title: "תובנות AI", subtitle: subtitle) {
                    if !ai.activeModelName.isEmpty {
                        Label(ai.activeModelName, systemImage: ai.canSend ? "star.fill" : "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(ai.canSend ? Color.secondary : Color.orange)
                            .lineLimit(1)
                            .help("מודל ברירת המחדל — רק הוא מקבל את הנתונים")
                    }
                    Button {
                        showSettings.toggle()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) { settings }
                    Button {
                        ai.send(InsightsEngine.defaultAnalysis, context: store.aiContext())
                    } label: {
                        Label("תובנות חדשות", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(ai.isRunning || !ai.canSend)
                }
                Divider()
                if ai.connected == true && !ai.canSend && !ai.awaitingPaste {
                    HStack {
                        Image(systemName: "star.circle.fill").foregroundStyle(.orange)
                        Text(ai.model.isEmpty
                             ? "בחר מודל ברירת מחדל — רק הוא יקבל את הנתונים שלך."
                             : "מודל ברירת המחדל (\(ai.activeModelName)) לא זמין. בחר מודל אחר בהגדרות.")
                        Spacer()
                        Button("בחירת מודל…") { showSettings = true }
                        Button("בדוק שוב") { Task { await ai.loadModels() } }
                    }
                    .font(.callout)
                    .padding(12)
                    .background(Color.orange.opacity(0.12))
                }
                if ai.connected == false && ai.messages.isEmpty {
                    setupHelp
                } else {
                    conversation
                }
                Divider()
                if ai.awaitingPaste { pastePanel; Divider() }
                composer
            }
            .navigationTitle("תובנות AI")
            .task {
                await ai.loadModels()
                // Automatic insights only with models that run on this Mac.
                if ai.autoInsights, ai.engine == .builtIn || ai.engine == .lmStudio,
                   ai.canSend, !ai.isRunning, store.insightsDue(lastAuto: ai.lastAutoAt) {
                    ai.send(InsightsEngine.defaultAnalysis, context: store.aiContext(), auto: true)
                }
            }
        }
    }

    private var subtitle: String {
        if ai.isRunning { return "המודל חושב… (מודל מקומי יכול לקחת קצת זמן)" }
        return ai.status.isEmpty ? "מודל מקומי דרך LM Studio — הנתונים לא יוצאים מהמחשב" : ai.status
    }

    // MARK: Setup

    private var setupHelp: some View {
        ScrollView {
            Card {
                Label(ai.engine == .builtIn ? "לא נמצאו מודלים במחשב" : (ai.engine == .cloud ? "חסר מפתח API — הוסף אותו בהגדרות (⚙︎)" : "אין חיבור ל-LM Studio"), systemImage: "bolt.horizontal.circle")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. פתח את LM Studio וטען מודל (מומלץ מודל שמבין עברית, 7B ומעלה).")
                    Text("2. בלשונית Developer (או ״Local Server״) לחץ Start Server — ברירת המחדל היא פורט 1234.")
                    Text("3. חזור לכאן ולחץ ״בדוק חיבור״.")
                    Text(verbatim: "כתובת נוכחית: " + ai.serverURL)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                HStack {
                    Button("בדוק חיבור") { Task { await ai.loadModels() } }
                        .buttonStyle(.borderedProminent)
                    Button("הגדרות…") { showSettings = true }
                }
                Text("כל הנתונים נשלחים רק למודל שרץ אצלך במחשב — שום דבר לא יוצא לאינטרנט.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.window)
    }

    private var settings: some View {
        Form {
            Picker("מנוע", selection: $ai.engine) {
                ForEach(AIEngine.available) { Text($0.title).tag($0) }
            }
            if ai.engine == .builtIn {
                Picker("מודל ברירת מחדל", selection: $ai.localModelPath) {
                    Text("— בחר —").tag("")
                    ForEach(ai.localModels) { m in
                        Text(verbatim: m.name + " · " + Fmt.number((m.sizeGB * 10).rounded() / 10) + " GB").tag(m.path)
                    }
                }
#if os(macOS)
                Button("הוסף תיקיית מודל…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.prompt = "בחר"
                    panel.message = "בחר תיקייה של מודל MLX (או תיקייה שמכילה כמה מודלים)"
                    if panel.runModal() == .OK, let url = panel.url { ai.addModelFolder(url) }
                }
                #endif
                Text("המודל רץ בתוך האפליקציה עם MLX של Apple — בלי LM Studio ובלי אינטרנט. המודלים שכבר הורדת ב-LM Studio (בפורמט MLX) מופיעים כאן לבד. הטעינה הראשונה לוקחת כמה שניות, והמודל משתחרר מהזיכרון אחרי 10 דקות בלי שימוש. רק המודל שנבחר מקבל את הנתונים.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if ai.engine == .cloud {
                cloudSettings
            } else if ai.engine == .manual {
                Picker("אתר", selection: $ai.manualSite) {
                    ForEach(ManualSite.all, id: \.name) { Text($0.name).tag($0.name) }
                }
                Text("כשאתה שואל, כל הנתונים והשאלה מועתקים ללוח כפרומפט אחד. מדביקים אותו באתר (בלי מפתח API, גם בחשבון חינמי), ואז מדביקים כאן את התשובה — היא נשמרת בשיחה עם תרשימים ועיצוב, והשיחה ממשיכה משם.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
            Picker("מודל ברירת מחדל", selection: $ai.model) {
                Text("— בחר —").tag("")
                if !ai.model.isEmpty && !ai.models.contains(ai.model) {
                    Text(verbatim: ai.model + " (לא זמין כרגע)").tag(ai.model)
                }
                ForEach(ai.models, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            Text("רק המודל הזה מקבל את הנתונים. אם הוא לא זמין ב-LM Studio — שום דבר לא נשלח, גם לא למודל אחר.")
                .font(.caption)
                .foregroundStyle(.secondary)
            FormTextField("כתובת השרת", text: $ai.serverURL)
            }
            Toggle("תובנות אוטומטיות (פעם בשבוע, ואחרי ייבוא אשראי)", isOn: $ai.autoInsights)
            HStack {
                Button("בדוק חיבור") { Task { await ai.loadModels() } }
                Button("ברירת מחדל") { ai.serverURL = InsightsEngine.defaultURL }
                Spacer()
                Button("נקה שיחה", role: .destructive) { ai.clear() }
            }
        }
        .formStyle(.grouped)
        .regularWidth(440)
        .hebrew()
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if ai.messages.isEmpty && !ai.isRunning {
                        Card {
                            Text("שאל כל שאלה על הכסף שלך, או לחץ ״תובנות חדשות״.")
                                .font(.headline)
                            Text("המודל מקבל סיכום של כל מה שיש באפליקציה: התלוש, ההוצאות הקבועות, החשבונות, האשראי לפי קטגוריה, התשלומים, המגמות והתחזית. הוא יכול לצייר תרשימים ולשאול אותך שאלות — התשובות שלך נשמרות בשיחה וממשיכות איתו הלאה.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach(ai.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if ai.isRunning {
                        MessageBubble(message: InsightMessage(role: "assistant", text: ai.streaming), live: true)
                            .id("live")
                    }
                }
                .padding(20)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.window)
            .onChange(of: ai.messages.count) { _, _ in
                if let last = ai.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .onChange(of: ai.streaming) { _, _ in
                proxy.scrollTo("live", anchor: .bottom)
            }
        }
    }

    // MARK: Composer

    // MARK: Cloud settings

    @ViewBuilder
    private var cloudSettings: some View {
        Picker("ספק", selection: $ai.cloudProvider) {
            ForEach(CloudProvider.allCases) { Text($0.title).tag($0) }
        }
        .onChange(of: ai.cloudProvider) { _, p in
            ai.cloudBaseURL = p.defaultBaseURL
            keyInput = ""
            Task { await ai.loadModels() }
        }
        HStack {
            SecureField("", text: $keyInput, prompt: Text(ai.hasCloudKey ? "•••••••• (שמור)" : "הדבק כאן את מפתח ה-API"))
                .labelsHidden()
            Button("שמור מפתח") {
                ai.saveAPIKey(keyInput)
                keyInput = ""
                Task { await ai.loadCloudModels() }
            }
            .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            if ai.hasCloudKey {
                Button("מחק", role: .destructive) { ai.saveAPIKey("") }
            }
        }
        if let page = ai.cloudProvider.keyPage {
            Link("איפה מקבלים מפתח?", destination: page)
                .font(.caption)
        }
        if ai.cloudProvider == .custom {
            FormTextField("כתובת ה-API", text: $ai.cloudBaseURL, prompt: Text("https://…/v1"))
        }
        HStack {
            FormTextField("מודל", text: $ai.cloudModel, prompt: Text(ai.cloudProvider.isAnthropic ? "למשל: claude-sonnet-5-5" : "שם המודל"))
            if !ai.cloudModels.isEmpty {
                Menu("בחר") {
                    ForEach(ai.cloudModels, id: \.self) { m in Button(m) { ai.cloudModel = m } }
                }
                .fixedSize()
            }
            Button("טען רשימה") { Task { await ai.loadCloudModels() } }
                .disabled(!ai.hasCloudKey)
        }
        Text("שים לב: במצב הזה הנתונים הכספיים שלך נשלחים לשרת של הספק שבחרת. המפתח נשמר במחזיק המפתחות (Keychain) של המחשב. תובנות אוטומטיות לא נשלחות לענן — רק כשאתה שואל.")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    // MARK: Manual paste

    private var pastePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            AdaptiveStack(spacing: 8, wideAlignment: .center) {
                Label("הפרומפט הועתק ללוח (\(ai.manualPrompt.count) תווים)", systemImage: "doc.on.clipboard.fill")
                    .font(.callout.weight(.semibold))
                if !Platform.isMac { Spacer(minLength: 0).frame(height: 0) } else { Spacer() }
                HStack {
                    Button("העתק שוב") { ai.copyManualPrompt() }
                    Button("פתח את \(ai.manualSite)") { ai.openManualSite() }
                        .buttonStyle(.borderedProminent)
                }
            }
            Text(Platform.isMac
                 ? "הדבק את הפרומפט באתר (⌘V). כשהתשובה מגיעה, העתק אותה עם כפתור ההעתקה שמתחת לתשובה (לא בסימון), כדי שגם הגרפים והעיצוב יעברו, והדבק כאן:"
                 : "הדבק את הפרומפט באתר או באפליקציה. כשהתשובה מגיעה, העתק אותה עם כפתור ההעתקה שמתחת לתשובה (לא בסימון), כדי שגם הגרפים והעיצוב יעברו, והדבק כאן:")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $pasted)
                .font(.callout)
                .frame(minHeight: 70, maxHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            HStack {
                Button("הדבק מהלוח") {
                    pasted = Platform.pastedString()
                }
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

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(quickPrompts, id: \.self) { prompt in
                        Button(prompt) { ask(prompt) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
            HStack {
                TextField("", text: $input, prompt: Text("כתוב שאלה או תשובה לשאלה של המודל…"), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { ask(input) }
                if ai.isRunning {
                    Button("עצור") { ai.stop() }
                } else {
                    Button {
                        ask(input)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || !ai.canSend)
                }
            }
        }
        .padding(14)
    }

    private func ask(_ text: String) {
        guard ai.canSend, !ai.isRunning else { return }
        ai.send(text, context: store.aiContext())
        input = ""
    }
}

// MARK: - Bubble

struct MessageBubble: View {
    let message: InsightMessage
    var live: Bool = false

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                if isUser {
                    Text(verbatim: message.auto == true ? "✨ תובנות אוטומטיות" : message.text)
                        .textSelection(.enabled)
                } else {
                    if live && (message.text.isEmpty || InsightSegment.isThinking(message.text)) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("חושב…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(InsightSegment.parse(message.text)) { segment in
                        switch segment {
                        case .text(let t):
                            MarkdownView(text: t)
                        case .chart(let spec):
                            InsightChart(spec: spec)
                        case .broken:
                            if !live {
                                Text("(המודל ניסה לצייר תרשים, אבל הנתונים שלו לא היו תקינים)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let model = message.model, !live {
                        Text(verbatim: model + " · " + message.date.formatted(.dateTime.day().month().hour().minute().locale(Fmt.locale)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: isUser ? 560 : .infinity, alignment: .leading)
            .background(isUser ? Color.accentColor.opacity(0.16) : Palette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(isUser ? 0 : 0.08)))
            if isUser { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .leading : .trailing)
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
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

    static let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .yellow, .red, .indigo, .mint, .brown, .cyan]

    private var points: [ChartSpec.Point] { Array(spec.data.prefix(12)) }
    private var slices: [Slice] { points.enumerated().map { Slice(id: $0.offset, label: $0.element.label, value: $0.element.value) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = spec.title, !title.isEmpty {
                Text(verbatim: title).font(.headline)
            }
            switch spec.type.lowercased() {
            case "pie", "donut":
                AdaptiveStack(spacing: 16, compactAlignment: .center, wideAlignment: .center) {
                    Chart(slices) { s in
                        SectorMark(angle: .value("סכום", max(s.value, 0)), innerRadius: .ratio(0.55), angularInset: 1.5)
                            .foregroundStyle(InsightChart.colors[s.id % InsightChart.colors.count])
                    }
                    .frame(width: 180, height: 180)
                    legend
                }
            case "line":
                Chart(points, id: \.label) { p in
                    LineMark(x: .value("שם", p.label), y: .value("סכום", p.value))
                    PointMark(x: .value("שם", p.label), y: .value("סכום", p.value))
                        .annotation(position: .top) {
                            Text(verbatim: Fmt.compact(p.value)).font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .frame(height: 200)
            default:
                Chart(points, id: \.label) { p in
                    BarMark(x: .value("שם", p.label), y: .value("סכום", p.value))
                        .foregroundStyle(Color.accentColor.gradient)
                        .annotation(position: .top) {
                            Text(verbatim: Fmt.compact(p.value)).font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .frame(height: 220)
            }
        }
        .padding(12)
        .background(Palette.window.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private var legend: some View {
        let total = max(points.reduce(0) { $0 + max($1.value, 0) }, 1)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(slices) { p in
                HStack {
                    Circle().fill(InsightChart.colors[p.id % InsightChart.colors.count]).frame(width: 8, height: 8)
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
