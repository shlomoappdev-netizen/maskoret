import Foundation
import Security
import Supabase
import UserNotifications

// MARK: - Providers

enum CloudProvider: String, CaseIterable, Identifiable {
    case openai, anthropic, gemini, openrouter, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openai: return "OpenAI (ChatGPT)"
        case .anthropic: return "Anthropic (Claude)"
        case .gemini: return "Google Gemini"
        case .openrouter: return "OpenRouter"
        case .custom: return "אחר (תואם OpenAI)"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .custom: return ""
        }
    }

    var keyPage: URL? {
        switch self {
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .openrouter: return URL(string: "https://openrouter.ai/keys")
        case .custom: return nil
        }
    }

    var isAnthropic: Bool { self == .anthropic }
}

/// Chat websites for the manual (copy & paste) mode.
struct ManualSite {
    let name: String
    let url: URL

    static let all: [ManualSite] = [
        ManualSite(name: "ChatGPT", url: URL(string: "https://chatgpt.com")!),
        ManualSite(name: "Claude", url: URL(string: "https://claude.ai/new")!),
        ManualSite(name: "Gemini", url: URL(string: "https://gemini.google.com/app")!),
        ManualSite(name: "Perplexity", url: URL(string: "https://www.perplexity.ai")!),
        ManualSite(name: "Copilot", url: URL(string: "https://copilot.microsoft.com")!)
    ]
}

// MARK: - API keys live in the macOS Keychain

enum KeychainStore {
    static let service = "com.shlomodavid.maskoret.ai"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ value: String, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query(account)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrLabel as String] = "מחשבון שכר — מפתח API"
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Cloud & manual engines

extension InsightsEngine {
    private var keyAccount: String { "api-key-" + cloudProvider.rawValue }

    var apiKey: String? {
        if let cachedKey { return cachedKey }
        let key = KeychainStore.load(account: keyAccount)
        cachedKey = key
        return key
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.save(trimmed, account: keyAccount)
        cachedKey = trimmed.isEmpty ? nil : trimmed
        hasCloudKey = !trimmed.isEmpty
        connected = hasCloudKey
        connectionCheck = nil
        refreshStatus()
        let provider = cloudProvider.rawValue
        if trimmed.isEmpty {
            Task { _ = try? await supabase.rpc("ai_key_delete", params: ["p_provider": provider]).execute() }
        } else if keyInAccount {
            pushKeySettings(key: trimmed)
        }
    }

    /// Saves the key (or, without one, only the model and address) in the account.
    func pushKeySettings(key: String? = nil) {
        guard keyInAccount, supabase.auth.currentUser != nil, key != nil || hasCloudKey else { return }
        let params: [String: AnyJSON] = [
            "p_provider": .string(cloudProvider.rawValue),
            "p_key": key.map { .string($0) } ?? .null,
            "p_model": .string(cloudModel.trimmingCharacters(in: .whitespaces)),
            "p_base_url": .string(cloudProvider == .custom ? cloudBaseURL : "")
        ]
        Task { _ = try? await supabase.rpc("ai_key_save", params: params).execute() }
    }

    private struct SavedKey: Decodable {
        let provider: String
        let api_key: String
        let model: String
        let base_url: String
    }

    /// No key on this device: take the one saved in the account (the chosen provider's, else the newest).
    func pullKeyFromAccount() async {
        guard supabase.auth.currentUser != nil,
              let keys = try? await supabase.rpc("ai_keys").decoded([SavedKey].self), !keys.isEmpty else { return }
        let pick = keys.first { $0.provider == cloudProvider.rawValue } ?? keys[0]
        guard let provider = CloudProvider(rawValue: pick.provider), !pick.api_key.isEmpty else { return }
        if provider != cloudProvider { cloudProvider = provider }
        cloudBaseURL = pick.base_url.isEmpty ? provider.defaultBaseURL : pick.base_url
        if !pick.model.isEmpty { cloudModel = pick.model }
        KeychainStore.save(pick.api_key, account: keyAccount)
        cachedKey = pick.api_key
    }

    /// "בדוק חיבור": asks the provider for its models with the key, and says whether the chosen model is there.
    func testConnection() async {
        connectionCheck = nil
        if engine == .manual {
            connectionCheck = (true, "במצב ידני אין חיבור לבדוק — השאלה מועתקת ללוח.")
            return
        }
        guard let key = apiKey, !key.isEmpty else {
            connectionCheck = (false, "אין מפתח API שמור")
            return
        }
        guard let url = URL(string: cloudBase + "/models") else {
            connectionCheck = (false, "כתובת ה-API לא תקינה")
            return
        }
        checkingConnection = true
        defer { checkingConnection = false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        authorize(&request, key: key)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 {
                connectionCheck = (false, "הספק דחה את המפתח (\(code)). בדוק שהעתקת אותו נכון.")
                return
            }
            if code >= 400 {
                connectionCheck = (false, "הספק החזיר שגיאה \(code).")
                return
            }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let ids = (json?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                .map { $0.replacingOccurrences(of: "models/", with: "") }
            if !ids.isEmpty { cloudModels = filteredModels(ids) }
            // Gemini lists its models as "models/…"; either way of writing the name is the same model.
            let model = cloudModel.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "models/", with: "")
            if model.isEmpty {
                connectionCheck = (true, "המפתח תקין ✓ — עכשיו בחר מודל.")
            } else if !ids.isEmpty && !ids.contains(model) {
                connectionCheck = (false, "המפתח תקין, אבל המודל ״\(model)״ לא קיים אצל הספק. בחר מהרשימה.")
            } else {
                connectionCheck = (true, "החיבור תקין ✓")
            }
            hasCloudKey = true
            connected = true
            refreshStatus()
        } catch {
            connectionCheck = (false, "אין חיבור לספק: " + error.localizedDescription)
        }
    }

    private func filteredModels(_ ids: [String]) -> [String] {
        ids.filter { id in
            let l = id.lowercased()
            return !l.contains("embed") && !l.contains("whisper") && !l.contains("tts") && !l.contains("dall")
                && !l.contains("image") && !l.contains("aqa") && !l.contains("imagen") && !l.contains("veo")
        }.sorted()
    }

    private var cloudBase: String {
        var s = cloudBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = cloudProvider.defaultBaseURL }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func authorize(_ request: inout URLRequest, key: String) {
        if cloudProvider.isAnthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
    }

    /// Lists the provider's models (so the name doesn't have to be typed).
    func loadCloudModels() async {
        guard let key = apiKey, !key.isEmpty, let url = URL(string: cloudBase + "/models") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        authorize(&request, key: key)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                status = "המפתח לא התקבל (\(http.statusCode)) — בדוק אותו"
                return
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let ids = (json?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                .map { $0.replacingOccurrences(of: "models/", with: "") }
            cloudModels = filteredModels(ids)
            status = cloudModels.isEmpty ? "לא התקבלה רשימת מודלים — כתוב את שם המודל ידנית" : "נמצאו \(cloudModels.count) מודלים"
        } catch {
            status = "לא הצלחתי להתחבר: " + error.localizedDescription
        }
    }

    private func content(_ turn: AITurn, anthropic: Bool) -> Any {
        guard !turn.images.isEmpty, turn.role == "user" else { return turn.text }
        var parts: [[String: Any]] = turn.images.map { data in
            let b64 = data.base64EncodedString()
            return anthropic
                ? ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]]
                : ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + b64]]
        }
        parts.append(["type": "text", "text": turn.text])
        return parts
    }

    func runCloud(system: String, turns: [AITurn]) {
        guard let key = apiKey, !key.isEmpty else {
            status = "אין מפתח API"
            return
        }
        let anthropic = cloudProvider.isAnthropic
        let endpoint = anthropic ? "/messages" : "/chat/completions"
        guard let url = URL(string: cloudBase + endpoint) else { return }

        var body: [String: Any] = ["model": cloudModel.trimmingCharacters(in: .whitespaces), "stream": true]
        if anthropic {
            // Messages must start with the user and alternate.
            var list = turns
            while list.first?.role == "assistant" { list.removeFirst() }
            body["system"] = system
            body["max_tokens"] = 8192
            body["messages"] = list.map { ["role": $0.role, "content": content($0, anthropic: true)] }
        } else {
            body["messages"] = [["role": "system", "content": system]] + turns.map { ["role": $0.role, "content": content($0, anthropic: false)] }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, key: key)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        isRunning = true
        streaming = ""
        status = "שולח…"
        let name = activeModelName
        task = Task { [weak self] in
            var output = ""
            var failure: String? = nil
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    var errorText = ""
                    for try await line in bytes.lines { errorText += line }
                    throw NSError(domain: "Cloud", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "שגיאה \(http.statusCode): " + String(errorText.prefix(300))])
                }
                self?.status = "חושב…"
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    // Only the answer itself: thinking comes in other fields ("reasoning", "thinking_delta") and is left out.
                    var piece: String?
                    if anthropic {
                        if (json["type"] as? String) == "content_block_delta",
                           let delta = json["delta"] as? [String: Any], (delta["type"] as? String) == "text_delta" {
                            piece = delta["text"] as? String
                        }
                    } else if let choice = (json["choices"] as? [[String: Any]])?.first,
                              let delta = choice["delta"] as? [String: Any] {
                        piece = delta["content"] as? String
                    }
                    if let piece {
                        output += piece
                        self?.streaming = output
                    }
                }
            } catch {
                failure = (error as NSError).code == NSURLErrorCancelled ? nil : error.localizedDescription
            }
            guard let self else { return }
            let answer = InsightSegment.withoutThinking(output).trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty {
                self.messages.append(InsightMessage(role: "assistant", text: answer, model: name))
            }
            self.streaming = ""
            self.isRunning = false
            if self.notifyWhenDone {
                self.notifyWhenDone = false
                if !answer.isEmpty {
                    AINotifier.post(title: "ניתוח פירוט האשראי", body: AINotifier.headline(of: answer))
                } else if let failure {
                    AINotifier.post(title: "ניתוח פירוט האשראי לא הצליח", body: failure)
                }
            }
            if let failure { self.status = "הבקשה נכשלה: " + failure } else { self.refreshStatus() }
        }
    }

    // MARK: Manual

    /// Everything a chat website needs, as one block of text.
    func prepareManual(system: String, turns: [AITurn]) {
        var text = system + "\n\n"
        if turns.count > 1 {
            text += "# השיחה שלנו עד עכשיו\n"
            for t in turns.dropLast() {
                text += (t.role == "user" ? "אני: " : "אתה: ") + t.text + "\n\n"
            }
        }
        text += "# השאלה שלי עכשיו\n" + (turns.last?.text ?? "")
        if turns.last?.images.isEmpty == false { text += "\n(צירפתי תמונה — היא מצורפת להודעה הזו)" }
        manualPrompt = text
        copyManualPrompt()
        awaitingPaste = true
        refreshStatus()
    }

    func copyManualPrompt() {
        Platform.copy(manualPrompt)
    }

    func openManualSite() {
        if let site = ManualSite.all.first(where: { $0.name == manualSite }) {
            Platform.open(site.url)
        }
    }

    /// Saves the answer that was pasted back from the website.
    func submitManualAnswer(_ text: String) {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        messages.append(InsightMessage(role: "assistant", text: InsightSegment.withoutThinking(answer), model: "ידני · " + manualSite))
        awaitingPaste = false
        manualPrompt = ""
        refreshStatus()
    }

    func cancelManual() {
        awaitingPaste = false
        refreshStatus()
    }
}

// MARK: - Notifications

/// The AI's analysis after a card import, as a system notification (Mac; on the iPhone too when allowed).
enum AINotifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "ai-" + UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// The answer's first line without markdown — the summary the model was asked to start with.
    static func headline(of answer: String) -> String {
        let text = InsightSegment.parse(answer).compactMap { seg -> String? in
            if case .text(let t) = seg { return t }
            return nil
        }.joined(separator: "\n")
        let first = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " #*_`>-•")) }
            .first { !$0.isEmpty } ?? ""
        let line = first.isEmpty ? "הניתוח מוכן" : first
        return (line.count > 180 ? String(line.prefix(177)) + "…" : line) + "\nהפרטים בתובנות AI."
    }
}
