import Foundation
import SwiftUI

// MARK: - Messages & charts

/// A chart the model asks to draw:
/// ```chart
/// {"type":"bar","title":"...","data":[{"label":"אוכל","value":420}]}
/// ```
struct ChartSpec: Codable, Equatable {
    struct Point: Codable, Equatable {
        var label: String
        var value: Double

        init(label: String, value: Double) {
            self.label = label
            self.value = value
        }

        /// Accepts a value written as text too ("1,234", "₪420").
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = (try? c.decode(String.self, forKey: .label)) ?? (try? c.decode(Double.self, forKey: .label)).map { Fmt.number($0) } ?? ""
            if let number = try? c.decode(Double.self, forKey: .value) {
                value = number
            } else {
                let text = try c.decode(String.self, forKey: .value)
                let cleaned = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
                guard let number = Double(cleaned) else {
                    throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "not a number")
                }
                value = number
            }
        }
    }

    var type: String = "bar"
    var title: String? = nil
    var data: [Point] = []

    init(type: String = "bar", title: String? = nil, data: [Point] = []) {
        self.type = type
        self.title = title
        self.data = data
    }

    /// "type" may be missing (→ bar); points that can't be read are skipped instead of failing the whole chart.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decode(String.self, forKey: .type)) ?? "bar"
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        var list = try c.nestedUnkeyedContainer(forKey: .data)
        var points: [Point] = []
        while !list.isAtEnd {
            if let p = try? list.decode(Point.self) { points.append(p) } else { _ = try? list.decode(Skip.self) }
        }
        data = points
    }

    private struct Skip: Decodable {}
}

struct InsightMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    var role: String          // "user" | "assistant"
    var text: String
    var date: Date = Date()
    var auto: Bool? = nil
    var model: String? = nil
    /// What the conversation shows instead of the text sent to the model (e.g. a quick action's long prompt).
    var label: String? = nil
    /// Pictures the user attached (JPEG). They stay on this device; other devices see only how many there were.
    var images: [Data]? = nil
    var imageCount: Int? = nil
    /// Proposed changes (```actions) the user applied, by index, or dismissed.
    var applied: [Int]? = nil
    var dismissed: Bool? = nil
    var actionError: String? = nil

    var shownText: String {
        if auto == true { return "✨ תובנות אוטומטיות" }
        return label ?? text
    }

    var pictureCount: Int { max(images?.count ?? 0, imageCount ?? 0) }
}

enum InsightSegment: Identifiable {
    case text(String)
    case chart(ChartSpec)
    case actions(AIActionPlan, String)
    case broken(String)

    var id: String {
        switch self {
        case .text(let t): return "t" + String(t.hashValue)
        case .chart(let c): return "c" + String((c.title ?? "").hashValue) + String(c.data.count)
        case .actions(_, let raw): return "a" + String(raw.hashValue)
        case .broken(let t): return "b" + String(t.hashValue)
        }
    }

    /// The tags reasoning models wrap their thinking in (Gemini: <thought>, others: <think> / <thinking>).
    static let thinkingTags = ["think", "thinking", "thought"]

    /// The reply without the model's thinking — that isn't part of the answer. An unfinished thinking section
    /// (still streaming) is removed to the end.
    static func withoutThinking(_ raw: String) -> String {
        var text = raw
        for tag in thinkingTags {
            while let start = text.range(of: "<\(tag)>", options: .caseInsensitive) {
                if let end = text.range(of: "</\(tag)>", options: .caseInsensitive, range: start.upperBound..<text.endIndex) {
                    text.removeSubrange(start.lowerBound..<end.upperBound)
                } else {
                    text.removeSubrange(start.lowerBound..<text.endIndex)
                }
            }
        }
        return text
    }

    /// Splits a reply into text, ```chart and ```actions blocks; leaves out the model's thinking.
    static func parse(_ raw: String) -> [InsightSegment] {
        let text = withoutThinking(raw)
        var result: [InsightSegment] = []
        var rest = Substring(text)
        while let open = rest.range(of: "```") {
            appendText(String(rest[..<open.lowerBound]), to: &result)
            let afterOpen = rest[open.upperBound...]
            let lineEnd = afterOpen.firstIndex(of: "\n") ?? afterOpen.endIndex
            let language = afterOpen[..<lineEnd].trimmingCharacters(in: .whitespaces).lowercased()
            guard let close = afterOpen[lineEnd...].range(of: "```") else {
                // Still streaming (or never closed): hide an unfinished chart or change list, keep anything else as text.
                if language != "chart" && language != "actions" { appendText(String(rest[open.lowerBound...]), to: &result) }
                rest = ""
                break
            }
            let body = String(afterOpen[lineEnd..<close.lowerBound])
            if language == "actions" {
                if let plan = AIActionPlan.decode(body) {
                    result.append(.actions(plan, body))
                } else {
                    result.append(.broken(body.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            } else if let spec = decodeChart(body) {
                result.append(.chart(spec))
            } else if language == "chart" {
                result.append(.broken(body.trimmingCharacters(in: .whitespacesAndNewlines)))
            } else {
                // An ordinary code block — the markdown view shows it as code.
                appendRawText(String(rest[open.lowerBound..<close.upperBound]), to: &result)
            }
            rest = afterOpen[close.upperBound...]
        }
        appendText(String(rest), to: &result)
        return mergeText(result)
    }

    // MARK: Charts pasted from chat websites

    /// Lines a chat website leaves above a code block when the answer is copied by selecting it.
    private static let codeHeaderLines: Set<String> = [
        "chart", "json", "code", "copy", "copy code", "העתק", "העתק קוד", "קוד", "העתקה", "הועתק", "copied!", "copied"
    ]

    /// Text that may still contain charts without the ``` fences (when the answer was copied by selecting it):
    /// any JSON object with "data" that reads as a chart is drawn, together with the "chart" / "Copy code" lines above it.
    private static func appendText(_ text: String, to result: inout [InsightSegment]) {
        var rest = Substring(text)
        while let found = findChartJSON(in: rest) {
            var before = String(rest[..<found.range.lowerBound])
            // Drop the code-box header lines that came along with the copy.
            var lines = before.components(separatedBy: "\n")
            while let last = lines.last {
                let t = last.trimmingCharacters(in: .whitespaces).lowercased()
                if t.isEmpty || codeHeaderLines.contains(t) { lines.removeLast() } else { break }
            }
            before = lines.joined(separator: "\n")
            appendRawText(before, to: &result)
            result.append(.chart(found.spec))
            rest = rest[found.range.upperBound...]
        }
        appendRawText(String(rest), to: &result)
    }

    private static func appendRawText(_ text: String, to result: inout [InsightSegment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(.text(trimmed)) }
    }

    /// Neighbouring text pieces become one, so the markdown (lists, tables) isn't cut in the middle.
    private static func mergeText(_ segments: [InsightSegment]) -> [InsightSegment] {
        var out: [InsightSegment] = []
        for seg in segments {
            if case .text(let t) = seg, let last = out.last, case .text(let prev) = last {
                out[out.count - 1] = .text(prev + "\n\n" + t)
            } else {
                out.append(seg)
            }
        }
        return out
    }

    /// The first `{ … }` in the text that is a chart.
    private static func findChartJSON(in text: Substring) -> (range: Range<Substring.Index>, spec: ChartSpec)? {
        var searchFrom = text.startIndex
        while let open = text[searchFrom...].firstIndex(where: { $0 == "{" }) {
            if let close = matchingBrace(in: text, from: open) {
                let candidate = text[open...close]
                if candidate.contains("data"), let spec = decodeChart(String(candidate)) {
                    return (open..<text.index(after: close), spec)
                }
            }
            searchFrom = text.index(after: open)
        }
        return nil
    }

    private static func matchingBrace(in text: Substring, from open: Substring.Index) -> Substring.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = open
        while i < text.endIndex {
            let ch = text[i]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if isQuote(ch) { inString = false }
            } else if isQuote(ch) {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func isQuote(_ ch: Character) -> Bool { ch == "\"" || ch == "\u{201C}" || ch == "\u{201D}" || ch == "\u{201E}" }

    /// Reads a chart, forgiving what websites and phones do to the JSON on the way
    /// (curly quotes, a "json" line on top, numbers written as "1,234 ₪").
    static func decodeChart(_ raw: String) -> ChartSpec? {
        var json = raw
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{201E}", with: "\"")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let brace = json.firstIndex(of: "{"), let last = json.lastIndex(of: "}"), brace < last {
            json = String(json[brace...last])
        }
        guard let data = json.data(using: .utf8),
              let spec = try? JSONDecoder().decode(ChartSpec.self, from: data),
              !spec.data.isEmpty else { return nil }
        return spec
    }

    /// The model is in the middle of thinking (an opened thinking tag that isn't closed yet).
    static func isThinking(_ raw: String) -> Bool {
        for tag in thinkingTags {
            if let start = raw.range(of: "<\(tag)>", options: [.backwards, .caseInsensitive]),
               raw.range(of: "</\(tag)>", options: .caseInsensitive, range: start.upperBound..<raw.endIndex) == nil {
                return true
            }
        }
        return false
    }
}

// MARK: - Engine (a cloud model with the user's API key, or copy-paste to a chat website)

enum AIEngine: String, CaseIterable, Identifiable {
    case cloud
    case manual

    var id: String { rawValue }

    static var available: [AIEngine] { allCases }

    var title: String {
        switch self {
        case .cloud: return "מודל בענן (מפתח API)"
        case .manual: return "ידני — העתק והדבק מאתר צ׳אט"
        }
    }
}

/// One turn of the conversation as the model gets it.
struct AITurn {
    var role: String
    var text: String
    var images: [Data] = []
}

@MainActor
final class InsightsEngine: ObservableObject {
    @Published var engine: AIEngine { didSet { UserDefaults.standard.set(engine.rawValue, forKey: "aiEngine"); Task { await loadModels() } } }

    // Cloud (API key)
    @Published var cloudProvider: CloudProvider { didSet { UserDefaults.standard.set(cloudProvider.rawValue, forKey: "aiCloudProvider"); cloudModels = []; cachedKey = nil; refreshStatus() } }
    @Published var cloudBaseURL: String { didSet { UserDefaults.standard.set(cloudBaseURL, forKey: "aiCloudBase") } }
    @Published var cloudModel: String { didSet { UserDefaults.standard.set(cloudModel, forKey: "aiCloudModel"); refreshStatus() } }
    @Published var cloudModels: [String] = []
    @Published var hasCloudKey = false
    /// Save the key in the account too, so the user's other devices get it.
    @Published var keyInAccount: Bool { didSet { UserDefaults.standard.set(keyInAccount, forKey: "aiKeyInAccount") } }
    /// After a card statement is imported, the model looks at the situation and the answer comes as a notification.
    @Published var analyzeAfterImport: Bool { didSet { UserDefaults.standard.set(analyzeAfterImport, forKey: "aiAfterImport") } }
    /// The answer on its way should also come as a notification.
    var notifyWhenDone = false
    /// The result of "בדוק חיבור", shown under the button.
    @Published var connectionCheck: (ok: Bool, text: String)? = nil
    @Published var checkingConnection = false
    var cachedKey: String?

    // Manual (copy the prompt to a chat website, paste the answer back)
    @Published var manualSite: String { didSet { UserDefaults.standard.set(manualSite, forKey: "aiManualSite") } }
    @Published var awaitingPaste = false
    @Published var manualPrompt = ""

    @Published var connected: Bool? = nil
    @Published var status = ""
    @Published var messages: [InsightMessage] = [] { didSet { save() } }
    @Published var streaming = ""
    @Published var isRunning = false
    /// Undo of the last applied change list: the message, and the data from before it.
    @Published var undo: (message: UUID, budget: Budget, money: MoneyData)? = nil

    var task: Task<Void, Never>?
    /// When the conversation was last cleared (on any device) — older messages don't come back from another device.
    var clearedAt: Date? {
        get { UserDefaults.standard.object(forKey: "aiClearedAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "aiClearedAt") }
    }
    var pushTaskHolder: Task<Void, Never>?
    private var applyingRemote = false

    /// Messages that came from another device: saved here, not sent back.
    func setMessagesFromSync(_ list: [InsightMessage]) {
        applyingRemote = true
        messages = list
        applyingRemote = false
    }

    var lastAutoAt: Date? {
        get { UserDefaults.standard.object(forKey: "aiLastAuto") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "aiLastAuto") }
    }

    init() {
        let savedEngine = AIEngine(rawValue: UserDefaults.standard.string(forKey: "aiEngine") ?? "") ?? AIEngine.available[0]
        engine = AIEngine.available.contains(savedEngine) ? savedEngine : AIEngine.available[0]
        let provider = CloudProvider(rawValue: UserDefaults.standard.string(forKey: "aiCloudProvider") ?? "") ?? .openai
        cloudProvider = provider
        cloudBaseURL = UserDefaults.standard.string(forKey: "aiCloudBase") ?? provider.defaultBaseURL
        cloudModel = UserDefaults.standard.string(forKey: "aiCloudModel") ?? ""
        keyInAccount = UserDefaults.standard.object(forKey: "aiKeyInAccount") as? Bool ?? true
        analyzeAfterImport = UserDefaults.standard.object(forKey: "aiAfterImport") as? Bool ?? true
        manualSite = UserDefaults.standard.string(forKey: "aiManualSite") ?? ManualSite.all[0].name
        if let data = SecureFile.read(InsightsEngine.fileURL),
           let saved = try? JSONDecoder().decode([InsightMessage].self, from: data) {
            applyingRemote = true
            messages = saved
            applyingRemote = false
        }
        // The AI conversation talks about the previous account's money — it goes with it.
        NotificationCenter.default.addObserver(forName: ServerSync.deviceDataCleared, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stop()
                self.applyingRemote = true
                self.messages = []
                self.applyingRemote = false
                self.clearedAt = nil
                self.cachedKey = nil
                try? FileManager.default.removeItem(at: InsightsEngine.fileURL)
            }
        }
    }

    nonisolated static var fileURL: URL {
        Store.fileURL.deletingLastPathComponent().appendingPathComponent("insights.json")
    }

    private func save() {
        let trimmed = Array(messages.suffix(200))
        if let data = try? JSONEncoder().encode(trimmed) {
            try? SecureFile.write(data, to: InsightsEngine.fileURL)
        }
        if !applyingRemote { schedulePush() }
    }

    // MARK: Models

    func loadModels() async {
        if engine == .cloud {
            if (apiKey ?? "").isEmpty { await pullKeyFromAccount() }
            hasCloudKey = !(apiKey ?? "").isEmpty
            connected = hasCloudKey
            refreshStatus()
            return
        }
        connected = true
        refreshStatus()
    }

    /// Only the chosen default model may answer — no automatic fallback to another one.
    var canSend: Bool {
        switch engine {
        case .cloud: return hasCloudKey && !cloudModel.trimmingCharacters(in: .whitespaces).isEmpty
        case .manual: return !awaitingPaste
        }
    }

    /// The name shown next to answers and in the header.
    var activeModelName: String {
        switch engine {
        case .cloud: return cloudModel.isEmpty ? "" : cloudModel
        case .manual: return "ידני · " + manualSite
        }
    }

    func refreshStatus() {
        if engine == .cloud {
            if !hasCloudKey { status = "הכנס מפתח API בהגדרות" }
            else if cloudModel.isEmpty { status = "בחר מודל בהגדרות" }
            else { status = cloudProvider.title }
            return
        }
        status = awaitingPaste ? "הדבק ב-\(manualSite) את מה שהועתק, ואז הדבק כאן את התשובה" : "ידני · " + manualSite
    }

    // MARK: Chat

    static let systemPrompt = """
    אתה העוזר הפיננסי של המשתמש בתוך האפליקציה ״מחשבון שכר״. ענה תמיד בעברית, קצר, ברור וממוקד, בלי הקדמות.
    השתמש רק בנתונים שמופיעים למטה, במה שהמשתמש כתב ובתמונות שצירף. אל תמציא מספרים. סכומים בשקלים (₪).
    הנתונים מגיעים מהאפליקציה: נטו, ניכויים, הוצאות קבועות, חשבונות וחיסכון, חיובי אשראי לפי חודש וקטגוריה, תשלומים, מגמות ותחזית.
    חיוב אשראי ש״מצומד״ להוצאה קבועה כבר נספר בהוצאה הקבועה — אל תספור אותו פעמיים.

    ## תרשימים
    כשתרשים עוזר להבין, הוסף בלוק בדיוק בפורמט הזה (JSON תקין, עד 8 נקודות, עד 2 תרשימים בתשובה):
    ```chart
    {"type":"bar","title":"כותרת","data":[{"label":"שם","value":123}]}
    ```
    type: bar, line או pie.

    ## פעולות באפליקציה
    אתה יכול להציע שינויים בנתונים, והמשתמש מאשר אותם בלחיצה לפני שהם מתבצעים. הצע שינוי כשהמשתמש מבקש להכניס או לעדכן
    נתונים (למשל מצילום מסך של חיסכון — העתק בדיוק את מה שמופיע בתמונה), או כשההמלצה שלך דורשת שינוי (תקרה למגמה,
    הפקדה לחיסכון, הוצאה מתוכננת). כתוב קודם במשפט או שניים מה אתה מציע ולמה, ואז בלוק אחד בפורמט הזה (JSON תקין):
    ```actions
    {"summary":"תיאור קצר","actions":[{"type":"update_account","account":"שם החשבון","balance":12500}]}
    ```
    הסוגים והשדות (רק השדות שמשתנים; תאריכים בפורמט YYYY-MM-DD; שמות בדיוק כמו בנתונים):
    - add_account: name, kind (savings=חיסכון נזיל, deposit=פיקדון/תוכנית חיסכון, pension=פנסיה), balance, balance_date, annual_rate (אחוז), rate_type (fixed/prime), prime_minus, monthly_contribution, contribution_day, start_date, maturity_date, note
    - update_account: account (השם הקיים), new_name, ואותם שדות כמו add_account. balance = יתרה עדכנית (נרשמת כעדכון יתרה).
    - add_trend: name, emoji, monthly_limit
    - update_trend: trend (השם הקיים), monthly_limit (0 = בלי תקרה), new_name, emoji
    - add_expense: name, amount, charge_day, to_account (אם זו הפקדה קבועה לחיסכון)
    - update_expense: expense (השם הקיים), amount, active (true/false), charge_day, new_name
    - add_transaction: title, amount, date, kind (expense/income/transfer), account (מאיזה חשבון; ברירת מחדל עו״ש), to_account (בהעברה), paid_by_card (true/false), installments, note
    לכל פעולה אפשר להוסיף why — משפט קצר למה.
    כשמשתמש צריך לקנות משהו יקר ולא צפוי: בדוק מאיפה כדאי לממן (עו״ש, חיסכון נזיל, תשלומים באשראי), מה ההשפעה על התחזית,
    והצע את השינויים: הוצאה מתוכננת, העברה מחיסכון אם צריך, והורדת תקרות במגמות לחודשים הקרובים.
    אל תציע פעולות בלי סיבה, ואל תחזור על פעולות שכבר בוצעו.

    אם חסר לך מידע חשוב — שאל שאלה אחת ממוקדת בסוף התשובה.
    """

    static let defaultAnalysis = "תסתכל על כל הנתונים ותן לי 3–5 תובנות חשובות על המצב הכספי שלי החודש: מה בולט, איפה אני חורג, ואיפה אפשר לשפר. הוסף תרשים אחד שממחיש את הנקודה הכי חשובה, ואם יש שינוי שכדאי לעשות — הצע אותו כפעולה."

    static let importAnalysis = """
    ייבאתי עכשיו פירוט אשראי חדש. תן ניתוח קצר של המצב: האם אני בתקציב החודש, מה בולט בחיובים (בתי עסק, קטגוריות, \
    חריגות לעומת החודשים הקודמים), איך זה משפיע על מה שיישאר בסוף החודש ועל המגמות עם תקרה, ומה כדאי לעשות. \
    אם יש שינוי שכדאי לעשות — הצע אותו כפעולה.
    השורה הראשונה בתשובה: משפט אחד קצר (עד 100 תווים, בלי כותרת ובלי עיצוב) שמסכם את הדבר הכי חשוב — הוא יוצג בהתראה.
    """

    /// After a card statement was imported: the analysis runs by itself, and its first line comes as a notification.
    /// Only with a cloud model that is set up (the manual mode needs the user), and only when it's turned on.
    func analyzeCardImport(context: String) {
        guard analyzeAfterImport, engine == .cloud, canSend, !isRunning else { return }
        AINotifier.requestPermission()
        notifyWhenDone = true
        send(InsightsEngine.importAnalysis, label: "📊 ניתוח אחרי ייבוא פירוט אשראי", context: context)
    }

    /// `label` is what the conversation shows instead of a long prompt.
    func send(_ prompt: String, label: String? = nil, images: [Data] = [], context: String, auto: Bool = false) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty, !isRunning, canSend else { return }
        var message = InsightMessage(role: "user", text: text.isEmpty ? "מצורפת תמונה." : text, auto: auto ? true : nil, label: label)
        if !images.isEmpty { message.images = images; message.imageCount = images.count }
        messages.append(message)
        if auto { lastAutoAt = Date() }
        run(context: context)
    }

    func stop() {
        task?.cancel()
    }

    func clear() {
        stop()
        messages = []
        undo = nil
        clearedAt = Date()
    }

    private func run(context: String) {
        let system = InsightsEngine.systemPrompt + "\n\n# הנתונים\n" + context
        var turns: [AITurn] = []
        let recent = Array(messages.suffix(12))
        for (index, m) in recent.enumerated() {
            var content = InsightSegment.parse(m.text).compactMap { seg -> String? in
                switch seg {
                case .text(let t): return t
                case .chart(let c): return "[תרשים: \(c.title ?? "")]"
                case .actions(let plan, let raw):
                    let state = m.dismissed == true ? "המשתמש דחה" : (m.applied?.isEmpty == false ? "בוצע" : "ממתין לאישור")
                    return "```actions\n" + raw.trimmingCharacters(in: .whitespacesAndNewlines) + "\n```\n[" + state + (plan.summary.isEmpty ? "" : ": " + plan.summary) + "]"
                case .broken: return nil
                }
            }.joined(separator: "\n")
            if content.isEmpty { content = m.text }
            // Pictures go with the newest question only; earlier ones are already described in the answers.
            let isLast = index == recent.count - 1
            let images = isLast ? (m.images ?? []) : []
            if m.role == "user", m.pictureCount > 0, images.isEmpty { content += "\n[צורפה תמונה]" }
            turns.append(AITurn(role: m.role, text: content, images: images))
        }
        if engine == .manual {
            prepareManual(system: system, turns: turns)
        } else {
            runCloud(system: system, turns: turns)
        }
    }

    // MARK: Changes the model proposed

    /// Applies the chosen changes of one answer to the member being edited; keeps an undo.
    /// `raw` is the block as the model wrote it; when the user polished the plan, the conversation keeps the edited one.
    func apply(_ plan: AIActionPlan, only chosen: Set<Int>, in messageID: UUID, store: Store, replacing raw: String? = nil) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        if let raw, let range = messages[index].text.range(of: raw) {
            messages[index].text.replaceSubrange(range, with: "\n" + plan.json + "\n")
        }
        let before = (store.budget, store.money)
        var done: [Int] = []
        var errors: [String] = []
        for action in plan.actions where chosen.contains(action.id) {
            do {
                try store.apply(action)
                done.append(action.id)
            } catch {
                errors.append(action.title + ": " + error.localizedDescription)
            }
        }
        messages[index].applied = done
        messages[index].actionError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if !done.isEmpty { undo = (messageID, before.0, before.1) }
    }

    func dismiss(_ messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].dismissed = true
    }

    func undoLast(store: Store) {
        guard let undo, let index = messages.firstIndex(where: { $0.id == undo.message }) else { return }
        store.budget = undo.budget
        store.money = undo.money
        messages[index].applied = nil
        messages[index].actionError = nil
        self.undo = nil
    }
}

// MARK: - Everything the model gets to see

extension Store {
    /// A compact text summary of the whole app, for the AI model.
    func aiContext() -> String {
        let now = Date()
        func m(_ v: Double) -> String { Fmt.money(v) }
        // One member, or the family members in view merged together.
        let d = dashboard
        let budget = d.budget
        let money = d.money
        let history = d.history
        var lines: [String] = []
        lines.append("תאריך היום: " + Fmt.date(now))
        if isCombined {
            lines.append("תצוגה משפחתית משותפת של: " + viewedMembers.map(\.title).joined(separator: ", ")
                         + ". כל אחד מחושב בנפרד (מס לפי התלוש שלו) ואז הכל מצורף יחד. שם של פריט מתחיל באימוג׳י של בן המשפחה שלו.")
        } else if hasFamily, let me = activeMember {
            lines.append("הנתונים של: " + me.title + " (בן משפחה אחד מתוך \(members.count))")
        }

        // This month
        let p = monthPicture
        lines.append("\n## החודש (\(p.title))")
        lines.append("נטו: \(m(p.net))" + (p.isActual ? " (בפועל)" : " (הערכה)"))
        lines.append("נשאר בפועל מההכנסה האחרונה (מה שכבר ירד): \(m(p.remainingActual)) · ימים עד המשכורת הבאה: \(p.daysLeft)")
        lines.append("צפוי להישאר אחרי חיוב האשראי (כולל הערכה לפי ממוצע החודשים הקודמים): \(m(p.remaining))")
        for l in p.spending { lines.append("- הוצאה קבועה: \(l.title) \(m(l.amount))") }
        if p.periodic > 0 { lines.append("- רכישות תקופתיות (ממוצע): \(m(p.periodic))") }
        for l in p.toSavings { lines.append("- לחיסכון: \(l.title) \(m(l.amount))") }
        for l in p.card { lines.append("- אשראי משתנות: \(l.title) \(m(l.amount))" + (p.cardEstimated ? " (הערכה)" : "")) }
        for l in p.installments { lines.append("- תשלום שיורד החודש: \(l.title) \(m(l.amount)) · \(l.detail)") }
        for l in p.laterInstallmentPurchases {
            lines.append("- נקנה החודש בתשלומים (לא יורד החודש): \(l.merchant) \(m(l.total)) ב-\(l.count) תשלומים")
        }
        if p.installmentsAfterThisMonth > 0 { lines.append("סה״כ תשלומים שעוד ירדו בחודשים הבאים: \(m(p.installmentsAfterThisMonth))") }
        for l in p.oneOffs { lines.append("- תנועה חריגה: \(l.title) \(m(l.amount))") }

        // Payslip
        lines.append("\n## תלוש")
        for i in budget.incomes where i.isActive {
            lines.append("- הכנסה: \(i.name) \(m(i.monthlyTotal))" + (i.isNet ? " (נטו)" : " (ברוטו)"))
        }
        lines.append("ברוטו: \(m(budget.gross)) · ניכויים: \(m(budget.totalDeductions)) · נטו משוער: \(m(budget.net))")
        let actuals = history.filter { $0.actualNet != nil }.sorted { $0.sortKey > $1.sortKey }.prefix(6)
        if !actuals.isEmpty {
            lines.append("נטו בפועל בחודשים קודמים: " + actuals.map { "\($0.shortTitle): \(m($0.actualNet ?? 0))" }.joined(separator: ", "))
        }

        // Accounts
        lines.append("\n## חשבונות")
        for a in money.accounts {
            var s = "- \(a.name) (\(a.kind.title)): \(m(money.balance(of: a, on: now, budget: budget, history: history)))"
            if a.kind.hasInterest { s += " · ריבית: " + a.rateDescription }
            if a.monthlyContribution > 0 { s += " · הפקדה חודשית \(m(a.monthlyContribution))" }
            if let maturity = a.maturityDate { s += " · סיום " + Fmt.date(maturity) }
            lines.append(s)
        }

        // Card by billing month
        let keys = money.cardBillingKeys.prefix(6)
        if !keys.isEmpty {
            lines.append("\n## כרטיס אשראי (לפי חודש חיוב)")
            for key in keys {
                let txs = money.cardTransactions(billingKey: key)
                let s = CardMonthSummary.of(txs)
                lines.append("### \(Fmt.monthTitle(year: key / 100, month: key % 100)): סה״כ \(m(s.total)) · מצומד להוצאות קבועות \(m(s.fixedLinked)) · משתנות \(m(s.variable))" + (s.pending != 0 ? " · מתוכן ממתין \(m(s.pending))" : ""))
                if !s.byCategory.isEmpty {
                    lines.append("קטגוריות: " + s.byCategory.prefix(8).map { "\($0.name) \(m($0.amount))" }.joined(separator: ", "))
                }
                let merchants = Dictionary(grouping: txs.filter { $0.isVariable }, by: { $0.merchant })
                    .map { ($0.key, $0.value.reduce(0) { $0 + $1.amount }, $0.value.count) }
                    .sorted { $0.1 > $1.1 }
                    .prefix(6)
                if !merchants.isEmpty {
                    lines.append("בתי עסק מובילים: " + merchants.map { "\($0.0) \(m($0.1)) (\($0.2) עסקאות)" }.joined(separator: ", "))
                }
            }
            let avg = money.averageCardVariable()
            if avg > 0 { lines.append("ממוצע משתנות לחודש (בלי תשלומים): \(m(avg))") }
        }

        // Installments
        let plans = money.installmentPlans.filter { $0.isActive }
        if !plans.isEmpty {
            lines.append("\n## תשלומים פעילים")
            for plan in plans {
                lines.append("- \(plan.merchant): \(m(plan.total)) ב-\(plan.count) תשלומים · "
                             + plan.payments.map { "\($0.number)/\(plan.count) \(Fmt.date($0.chargeDate)) \(m($0.amount))" }.joined(separator: ", "))
            }
        }

        // Trends
        if !money.trends.isEmpty {
            lines.append("\n## מגמות (קבוצות הוצאה שהמשתמש הגדיר)")
            for t in money.trends {
                let s = money.stats(of: t)
                lines.append("- \(t.emoji) \(t.name): החודש \(m(s.thisMonth)) · חודש שעבר \(m(s.lastMonth)) · ממוצע \(m(s.monthlyAverage)) · סה״כ \(m(s.total))"
                             + (t.monthlyLimit > 0 ? " · תקרה \(m(t.monthlyLimit))" : ""))
            }
        }

        // Owed to me
        let debtors = money.debtors.filter { $0.amount > 0.005 }
        if !debtors.isEmpty {
            lines.append("\n## חייבים לי (שילמתי בשביל אחרים — לא הוצאה שלי)")
            for d in debtors { lines.append("- \(d.person): \(m(d.amount))") }
        }

        // Maaser
        let maaser = familyMaaser
        if !maaser.isEmpty {
            lines.append("\n## מעשרות")
            for row in maaser {
                let b = row.status.balance
                lines.append("- \(row.member.title): " + (b >= 0 ? "חוב " : "זכות ") + m(abs(b))
                             + " · ניתן החודש \(m(row.status.thisMonthPaid)) · ניתן השנה \(m(row.status.paidThisYear))")
            }
        }

        // Tracked purchases
        let tracked = budget.trackedItems
        if !tracked.isEmpty {
            lines.append("\n## מעקב רכישות")
            for t in tracked {
                var s = "- \(t.name): \(t.purchases.count) רכישות"
                if let last = t.lastPurchase { s += " · אחרונה \(Fmt.date(last.date)) ב-\(m(last.price))" }
                if t.monthlyCost > 0 { s += " · עלות חודשית ממוצעת \(m(t.monthlyCost))" }
                lines.append(s)
            }
        }

        // Forecast
        let f = forecast()
        if f.count > 1 {
            lines.append("\n## תחזית")
            for month in f.dropFirst() {
                lines.append("- \(month.label): עו״ש \(m(month.checking)) · חיסכון \(m(month.savings))"
                             + (month.events.isEmpty ? "" : " · " + month.events.joined(separator: "; ")))
            }
        }
        return lines.joined(separator: "\n")
    }
}
