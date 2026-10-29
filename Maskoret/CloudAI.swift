import Foundation
import Security

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
        refreshStatus()
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
            cloudModels = ids.filter { id in
                let l = id.lowercased()
                return !l.contains("embed") && !l.contains("whisper") && !l.contains("tts") && !l.contains("dall") && !l.contains("image")
            }.sorted()
            status = cloudModels.isEmpty ? "לא התקבלה רשימת מודלים — כתוב את שם המודל ידנית" : "נמצאו \(cloudModels.count) מודלים"
        } catch {
            status = "לא הצלחתי להתחבר: " + error.localizedDescription
        }
    }

    func runCloud(system: String, turns: [(role: String, text: String)]) {
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
            body["max_tokens"] = 4096
            body["messages"] = list.map { ["role": $0.role, "content": $0.text] }
        } else {
            body["messages"] = [["role": "system", "content": system]] + turns.map { ["role": $0.role, "content": $0.text] }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, key: key)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        isRunning = true
        streaming = ""
        status = "שולח ל-" + cloudProvider.title + "…"
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
                self?.status = "המודל עונה…"
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    var piece: String?
                    if anthropic {
                        if (json["type"] as? String) == "content_block_delta",
                           let delta = json["delta"] as? [String: Any] {
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
            if !output.isEmpty {
                self.messages.append(InsightMessage(role: "assistant", text: output, model: name))
            }
            self.streaming = ""
            self.isRunning = false
            if let failure { self.status = "הבקשה נכשלה: " + failure } else { self.refreshStatus() }
        }
    }

    // MARK: Manual

    /// Everything a chat website needs, as one block of text.
    func prepareManual(system: String, turns: [(role: String, text: String)]) {
        var text = system + "\n\n"
        if turns.count > 1 {
            text += "# השיחה שלנו עד עכשיו\n"
            for t in turns.dropLast() {
                text += (t.role == "user" ? "אני: " : "אתה: ") + t.text + "\n\n"
            }
        }
        text += "# השאלה שלי עכשיו\n" + (turns.last?.text ?? "")
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
        messages.append(InsightMessage(role: "assistant", text: answer, model: "ידני · " + manualSite))
        awaitingPaste = false
        manualPrompt = ""
        refreshStatus()
    }

    func cancelManual() {
        awaitingPaste = false
        refreshStatus()
    }
}
