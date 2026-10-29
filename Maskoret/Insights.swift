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
}

enum InsightSegment: Identifiable {
    case text(String)
    case chart(ChartSpec)
    case broken(String)

    var id: String {
        switch self {
        case .text(let t): return "t" + String(t.hashValue)
        case .chart(let c): return "c" + String((c.title ?? "").hashValue) + String(c.data.count)
        case .broken(let t): return "b" + String(t.hashValue)
        }
    }

    /// Splits a reply into text and ```chart blocks; hides <think> sections of reasoning models.
    static func parse(_ raw: String) -> [InsightSegment] {
        var text = raw
        while let start = text.range(of: "<think>") {
            if let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                text.removeSubrange(start.lowerBound..<text.endIndex)
            }
        }
        var result: [InsightSegment] = []
        var rest = Substring(text)
        while let open = rest.range(of: "```") {
            appendText(String(rest[..<open.lowerBound]), to: &result)
            let afterOpen = rest[open.upperBound...]
            let lineEnd = afterOpen.firstIndex(of: "\n") ?? afterOpen.endIndex
            let language = afterOpen[..<lineEnd].trimmingCharacters(in: .whitespaces).lowercased()
            guard let close = afterOpen[lineEnd...].range(of: "```") else {
                // Still streaming (or never closed): hide an unfinished chart, keep anything else as text.
                if language != "chart" { appendText(String(rest[open.lowerBound...]), to: &result) }
                rest = ""
                break
            }
            let body = String(afterOpen[lineEnd..<close.lowerBound])
            if let spec = decodeChart(body) {
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

    static func isThinking(_ raw: String) -> Bool {
        guard let start = raw.range(of: "<think>", options: .backwards) else { return false }
        return raw.range(of: "</think>", range: start.upperBound..<raw.endIndex) == nil
    }
}

// MARK: - Engine (built-in MLX, or LM Studio's OpenAI-compatible API)

enum AIEngine: String, CaseIterable, Identifiable {
    case builtIn
    case lmStudio
    case cloud
    case manual

    var id: String { rawValue }

    /// The engines this device can run (no built-in MLX model on iPhone/iPad).
    static var available: [AIEngine] {
        Platform.isMac ? allCases : [.cloud, .manual, .lmStudio]
    }

    var title: String {
        switch self {
        case .builtIn: return "מובנה באפליקציה (MLX של Apple)"
        case .lmStudio: return "LM Studio"
        case .cloud: return "מודל בענן (מפתח API)"
        case .manual: return "ידני — העתק והדבק מאתר צ׳אט"
        }
    }
}

@MainActor
final class InsightsEngine: ObservableObject {
    static let defaultURL = "http://127.0.0.1:1234/v1"

    @Published var engine: AIEngine { didSet { UserDefaults.standard.set(engine.rawValue, forKey: "aiEngine"); Task { await loadModels() } } }
    /// Built-in engine: the default model's folder. Nothing is ever sent to any other model.
    @Published var localModelPath: String { didSet { UserDefaults.standard.set(localModelPath, forKey: "aiLocalModel"); refreshStatus() } }
    @Published var localModels: [LocalModel] = []

    // Cloud (API key)
    @Published var cloudProvider: CloudProvider { didSet { UserDefaults.standard.set(cloudProvider.rawValue, forKey: "aiCloudProvider"); cloudModels = []; cachedKey = nil; refreshStatus() } }
    @Published var cloudBaseURL: String { didSet { UserDefaults.standard.set(cloudBaseURL, forKey: "aiCloudBase") } }
    @Published var cloudModel: String { didSet { UserDefaults.standard.set(cloudModel, forKey: "aiCloudModel"); refreshStatus() } }
    @Published var cloudModels: [String] = []
    @Published var hasCloudKey = false
    var cachedKey: String?

    // Manual (copy the prompt to a chat website, paste the answer back)
    @Published var manualSite: String { didSet { UserDefaults.standard.set(manualSite, forKey: "aiManualSite") } }
    @Published var awaitingPaste = false
    @Published var manualPrompt = ""

    @Published var serverURL: String { didSet { UserDefaults.standard.set(serverURL, forKey: "aiServerURL") } }
    /// The default model. Nothing is ever sent to any other model.
    @Published var model: String { didSet { UserDefaults.standard.set(model, forKey: "aiModel"); refreshStatus() } }
    @Published var autoInsights: Bool { didSet { UserDefaults.standard.set(autoInsights, forKey: "aiAuto") } }
    @Published var models: [String] = []
    @Published var connected: Bool? = nil
    @Published var status = ""
    @Published var messages: [InsightMessage] = [] { didSet { save() } }
    @Published var streaming = ""
    @Published var isRunning = false

    var task: Task<Void, Never>?

    var lastAutoAt: Date? {
        get { UserDefaults.standard.object(forKey: "aiLastAuto") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "aiLastAuto") }
    }

    init() {
        serverURL = UserDefaults.standard.string(forKey: "aiServerURL") ?? InsightsEngine.defaultURL
        model = UserDefaults.standard.string(forKey: "aiModel") ?? ""
        let savedEngine = AIEngine(rawValue: UserDefaults.standard.string(forKey: "aiEngine") ?? "") ?? AIEngine.available[0]
        engine = AIEngine.available.contains(savedEngine) ? savedEngine : AIEngine.available[0]
        localModelPath = UserDefaults.standard.string(forKey: "aiLocalModel") ?? ""
        let provider = CloudProvider(rawValue: UserDefaults.standard.string(forKey: "aiCloudProvider") ?? "") ?? .openai
        cloudProvider = provider
        cloudBaseURL = UserDefaults.standard.string(forKey: "aiCloudBase") ?? provider.defaultBaseURL
        cloudModel = UserDefaults.standard.string(forKey: "aiCloudModel") ?? ""
        manualSite = UserDefaults.standard.string(forKey: "aiManualSite") ?? ManualSite.all[0].name
        autoInsights = UserDefaults.standard.object(forKey: "aiAuto") as? Bool ?? true
        if let data = try? Data(contentsOf: InsightsEngine.fileURL),
           let saved = try? JSONDecoder().decode([InsightMessage].self, from: data) {
            messages = saved
        }
    }

    static var fileURL: URL {
        Store.fileURL.deletingLastPathComponent().appendingPathComponent("insights.json")
    }

    private func save() {
        let trimmed = Array(messages.suffix(200))
        if let data = try? JSONEncoder().encode(trimmed) {
            try? data.write(to: InsightsEngine.fileURL, options: .atomic)
        }
    }

    private var base: String {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    // MARK: Models

    func loadModels() async {
        if engine == .cloud {
            hasCloudKey = !(apiKey ?? "").isEmpty
            connected = hasCloudKey
            if !hasCloudKey { status = "הכנס מפתח API בהגדרות (⚙︎)" } else { refreshStatus() }
            return
        }
        if engine == .manual {
            connected = true
            refreshStatus()
            return
        }
        if engine == .builtIn {
            localModels = LocalModel.scan()
            connected = !localModels.isEmpty
            if localModels.isEmpty { status = "לא נמצאו מודלים בפורמט MLX — הוסף תיקיית מודל בהגדרות (⚙︎)" }
            refreshStatus()
            return
        }
        guard let url = URL(string: base + "/models") else {
            connected = false
            status = "כתובת השרת לא תקינה"
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let ids = (json?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            models = ids.filter { !$0.lowercased().contains("embed") }
            connected = true
            refreshStatus()
        } catch {
            connected = false
            status = "אין חיבור ל-LM Studio"
        }
    }

    /// Only the chosen default model may answer — no automatic fallback to another one.
    var canSend: Bool {
        switch engine {
        case .builtIn: return !localModelPath.isEmpty && localModels.contains { $0.path == localModelPath }
        case .lmStudio: return connected == true && !model.isEmpty && models.contains(model)
        case .cloud: return hasCloudKey && !cloudModel.trimmingCharacters(in: .whitespaces).isEmpty
        case .manual: return !awaitingPaste
        }
    }

    /// The name shown next to answers and in the header.
    var activeModelName: String {
        switch engine {
        case .builtIn: return localModelPath.isEmpty ? "" : URL(fileURLWithPath: localModelPath).lastPathComponent
        case .lmStudio: return model
        case .cloud: return cloudModel.isEmpty ? "" : cloudModel + " · " + cloudProvider.title
        case .manual: return "ידני · " + manualSite
        }
    }

    func addModelFolder(_ url: URL) {
        var extra = LocalModel.extraFolders
        if !extra.contains(url.path) { extra.append(url.path) }
        LocalModel.extraFolders = extra
        localModels = LocalModel.scan()
        connected = !localModels.isEmpty
        if LocalModel.isMLXModel(url) { localModelPath = url.path }
        refreshStatus()
    }

    func refreshStatus() {
        if engine == .cloud {
            if !hasCloudKey { status = "הכנס מפתח API בהגדרות (⚙︎)" }
            else if cloudModel.isEmpty { status = "כתוב איזה מודל להשתמש בהגדרות (⚙︎)" }
            else { status = "מחובר ל-" + cloudProvider.title + " · הנתונים נשלחים לשרת שלהם" }
            return
        }
        if engine == .manual {
            status = awaitingPaste ? "הפרומפט הועתק — הדבק אותו ב-\(manualSite), ואז הדבק כאן את התשובה" : "ידני: השאלה תועתק ללוח, ואת התשובה מדביקים כאן"
            return
        }
        if engine == .builtIn {
            guard !localModels.isEmpty else { return }
            if localModelPath.isEmpty {
                status = "בחר מודל ברירת מחדל בהגדרות (⚙︎)"
            } else if !canSend {
                status = "מודל ברירת המחדל לא נמצא במחשב — לא נשלח כלום"
            } else {
                status = "מודל מובנה · רץ אצלך במחשב"
            }
            return
        }
        guard connected == true else { return }
        if models.isEmpty {
            status = "השרת פועל, אבל אין מודלים זמינים"
        } else if model.isEmpty {
            status = "בחר מודל ברירת מחדל בהגדרות (⚙︎)"
        } else if !models.contains(model) {
            status = "מודל ברירת המחדל לא נמצא ב-LM Studio — לא נשלח כלום"
        } else {
            status = "מחובר ל-LM Studio"
        }
    }

    // MARK: Chat

    static let systemPrompt = """
    אתה יועץ תקציב אישי של המשתמש, בתוך האפליקציה ״מחשבון שכר״. ענה תמיד בעברית, קצר, ברור וממוקד.
    השתמש רק בנתונים שמופיעים למטה ובמה שהמשתמש כתב בשיחה. אל תמציא מספרים. סכומים בשקלים (₪).
    הנתונים מגיעים מהאפליקציה: נטו, ניכויים, הוצאות קבועות, חשבונות וחיסכון, חיובי אשראי לפי חודש וקטגוריה, תשלומים, מגמות ותחזית.
    חיוב אשראי ש״מצומד״ להוצאה קבועה כבר נספר בהוצאה הקבועה — אל תספור אותו פעמיים.

    כשתרשים יעזור להבין — הוסף תרשים בבלוק בדיוק בפורמט הזה (JSON תקין, עד 8 נקודות):
    ```chart
    {"type":"bar","title":"כותרת","data":[{"label":"שם","value":123}]}
    ```
    type יכול להיות bar, line או pie. אל תוסיף יותר מ-2 תרשימים בתשובה.

    בסוף כל תשובה שאל שאלה אחת או שתיים ממוקדות שיעזרו לנהל את התקציב טוב יותר בהמשך
    (למשל: מטרה לחיסכון, הוצאה שלא ברורה, תקרה למגמה). כתוב אותן אחרי הכותרת ״שאלות:״.
    """

    static let defaultAnalysis = "תסתכל על כל הנתונים ותן לי 3–5 תובנות חשובות על המצב הכספי שלי החודש: מה בולט, איפה אני חורג, ואיפה אפשר לשפר. הוסף תרשים אחד שממחיש את הנקודה הכי חשובה."

    func send(_ prompt: String, context: String, auto: Bool = false) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning, canSend else { return }
        messages.append(InsightMessage(role: "user", text: text, auto: auto ? true : nil))
        if auto { lastAutoAt = Date() }
        run(context: context)
    }

    func stop() {
        task?.cancel()
    }

    // MARK: Built-in engine

    private func runLocal(system: String, history: [(role: String, text: String)], prompt: String) {
        isRunning = true
        streaming = ""
        let path = localModelPath
        let name = activeModelName
        status = LocalModelRunner.shared.loadedModelPath == path ? "המודל חושב…" : "טוען את המודל לזיכרון… (כמה שניות)"
        task = Task { [weak self] in
            var output = ""
            var failure: String? = nil
            do {
                let stream = try await LocalModelRunner.shared.stream(path: path, system: system, history: history, prompt: prompt)
                self?.status = "המודל חושב…"
                for try await piece in stream {
                    if Task.isCancelled { break }
                    output += piece
                    self?.streaming = output
                }
            } catch {
                if !(error is CancellationError) { failure = error.localizedDescription }
            }
            LocalModelRunner.shared.scheduleUnload()
            guard let self else { return }
            if !output.isEmpty {
                self.messages.append(InsightMessage(role: "assistant", text: output, model: name + " · מובנה"))
            }
            self.streaming = ""
            self.isRunning = false
            if let failure {
                self.status = "המודל לא נטען: " + failure + " — נסה מודל אחר בהגדרות"
            } else {
                self.refreshStatus()
            }
        }
    }

    func clear() {
        stop()
        messages = []
    }

    private func run(context: String) {
        let system = InsightsEngine.systemPrompt + "\n\n# הנתונים\n" + context
        var turns: [(role: String, text: String)] = []
        for m in messages.suffix(12) {
            let content = InsightSegment.parse(m.text).compactMap { seg -> String? in
                if case .text(let t) = seg { return t }
                if case .chart(let c) = seg { return "[תרשים: \(c.title ?? "")]" }
                return nil
            }.joined(separator: "\n")
            turns.append((m.role, content.isEmpty ? m.text : content))
        }
        if engine == .builtIn, let last = turns.popLast() {
            runLocal(system: system, history: turns, prompt: last.text)
            return
        }
        if engine == .manual {
            prepareManual(system: system, turns: turns)
            return
        }
        if engine == .cloud {
            runCloud(system: system, turns: turns)
            return
        }
        guard let url = URL(string: base + "/chat/completions") else { return }
        var history: [[String: String]] = [["role": "system", "content": system]]
        for t in turns { history.append(["role": t.role, "content": t.text]) }
        var body: [String: Any] = ["messages": history, "stream": true, "temperature": 0.4]
        body["model"] = model

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 900
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        isRunning = true
        streaming = ""
        status = "המודל חושב…"
        let usedModel = model
        task = Task { [weak self] in
            var output = ""
            var failure: String? = nil
            var answeredBy: String? = nil
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    var errorText = ""
                    for try await line in bytes.lines { errorText += line }
                    throw NSError(domain: "LMStudio", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "שגיאה \(http.statusCode): " + String(errorText.prefix(300))])
                }
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if answeredBy == nil, let m = json["model"] as? String, !m.isEmpty { answeredBy = m }
                    guard let choice = (json["choices"] as? [[String: Any]])?.first,
                          let delta = choice["delta"] as? [String: Any],
                          let piece = delta["content"] as? String else { continue }
                    output += piece
                    self?.streaming = output
                }
            } catch {
                failure = (error as NSError).code == NSURLErrorCancelled ? nil : error.localizedDescription
            }
            do {
                guard let self else { return }
                if !output.isEmpty {
                    // Flag it if LM Studio answered with a different model than the default.
                    var shown = usedModel
                    if let answeredBy, !answeredBy.contains(usedModel), !usedModel.contains(answeredBy) {
                        shown = answeredBy + " ⚠︎ לא מודל ברירת המחדל"
                    }
                    self.messages.append(InsightMessage(role: "assistant", text: output, model: shown))
                }
                self.streaming = ""
                self.isRunning = false
                if let failure {
                    self.connected = false
                    self.status = "הבקשה נכשלה: " + failure
                } else {
                    self.status = "מחובר ל-LM Studio"
                }
            }
        }
    }
}

// MARK: - Everything the model gets to see

extension Store {
    /// A compact text summary of the whole app, for the local model.
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
        lines.append("נשאר בסוף החודש (לפי האפליקציה): \(m(p.remaining)) · ימים שנשארו: \(p.daysLeft)")
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
            var s = "- \(a.name) (\(a.kind.title)): \(m(MoneyCalc.value(of: a, on: now, transactions: money.transactions)))"
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

    /// New data since the last automatic insight (or a week passed).
    func insightsDue(lastAuto: Date?) -> Bool {
        guard let lastAuto else { return true }
        if Date().timeIntervalSince(lastAuto) > 7 * 86_400 { return true }
        if let imported = money.cardImports.first?.importedAt, imported > lastAuto { return true }
        return false
    }
}
