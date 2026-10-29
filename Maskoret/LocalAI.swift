import Foundation
#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Loads the tokenizer from the model folder with swift-transformers (no macros, no network).
struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(base: tokenizer)
    }
}

/// Adapts swift-transformers' tokenizer to the one mlx-swift-lm expects.
struct TokenizerBridge: MLXLMCommon.Tokenizer, @unchecked Sendable {
    let base: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        base.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        base.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    var bosToken: String? { base.bosToken }
    var eosToken: String? { base.eosToken }
    var unknownToken: String? { base.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try base.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

#endif

/// An MLX model folder on this Mac (config.json + *.safetensors) — e.g. one LM Studio already downloaded.
struct LocalModel: Identifiable, Hashable {
    let path: String
    let name: String
    let sizeGB: Double
    var id: String { path }

    /// Folders searched for MLX models: LM Studio's library, plus folders the user added.
    static var searchRoots: [URL] {
        let home = Platform.homeDirectory
        var roots = [
            home.appendingPathComponent(".lmstudio/models", isDirectory: true),
            home.appendingPathComponent(".cache/lm-studio/models", isDirectory: true)
        ]
        roots += extraFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
        return roots
    }

    static var extraFolders: [String] {
        get { UserDefaults.standard.stringArray(forKey: "aiExtraModelFolders") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "aiExtraModelFolders") }
    }

    static func isMLXModel(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.appendingPathComponent("config.json").path) else { return false }
        let files = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        return files.contains { $0.hasSuffix(".safetensors") }
            && !files.contains { $0.lowercased().contains("whisper") }
            && !url.lastPathComponent.lowercased().contains("whisper")
    }

    static func make(_ url: URL) -> LocalModel {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.filter { $0.pathExtension == "safetensors" }
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(0, +)
        return LocalModel(path: url.path, name: url.lastPathComponent, sizeGB: Double(bytes) / 1_073_741_824)
    }

    /// Finds MLX models up to two levels deep (publisher/model).
    static func scan() -> [LocalModel] {
        let fm = FileManager.default
        var found: [LocalModel] = []
        var seen = Set<String>()
        for root in searchRoots {
            if isMLXModel(root), seen.insert(root.path).inserted { found.append(make(root)) }
            let level1 = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for dir in level1 {
                if isMLXModel(dir) {
                    if seen.insert(dir.path).inserted { found.append(make(dir)) }
                    continue
                }
                let level2 = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                for sub in level2 where isMLXModel(sub) {
                    if seen.insert(sub.path).inserted { found.append(make(sub)) }
                }
            }
        }
        return found.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}

#if canImport(MLXLLM)
/// Runs an MLX model inside the app with Apple's mlx-swift-lm. Keeps one model in memory
/// and frees it after a while without use.
@MainActor
final class LocalModelRunner {
    static let shared = LocalModelRunner()

    private var container: ModelContainer?
    private var loadedPath: String?
    private var unloadTask: Task<Void, Never>?

    var loadedModelPath: String? { loadedPath }

    func container(for path: String) async throws -> ModelContainer {
        unloadTask?.cancel()
        if let container, loadedPath == path { return container }
        container = nil
        loadedPath = nil
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let loaded = try await loadModelContainer(from: url, using: LocalTokenizerLoader())
        container = loaded
        loadedPath = path
        return loaded
    }

    /// Streams the answer. `history` is the earlier conversation (role "user" / "assistant").
    func stream(path: String, system: String, history: [(role: String, text: String)], prompt: String) async throws -> AsyncThrowingStream<String, Error> {
        let model = try await container(for: path)
        var messages: [Chat.Message] = [.system(system)]
        for item in history {
            messages.append(item.role == "user" ? .user(item.text) : .assistant(item.text))
        }
        let session = ChatSession(model, history: messages)
        return session.streamResponse(to: prompt)
    }

    /// Frees the model's memory after 10 minutes without questions.
    func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.container = nil
            self?.loadedPath = nil
        }
    }

    func unload() {
        unloadTask?.cancel()
        container = nil
        loadedPath = nil
    }
}
#else
/// The iPhone/iPad build has no MLX engine — the built-in engine is hidden there.
@MainActor
final class LocalModelRunner {
    static let shared = LocalModelRunner()
    var loadedModelPath: String? { nil }

    struct Unavailable: LocalizedError {
        var errorDescription: String? { "המודל המובנה זמין רק באפליקציית ה-Mac." }
    }

    func stream(path: String, system: String, history: [(role: String, text: String)], prompt: String) async throws -> AsyncThrowingStream<String, Error> {
        throw Unavailable()
    }

    func scheduleUnload() {}
    func unload() {}
}
#endif
