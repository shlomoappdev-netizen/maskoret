import Foundation
import AppKit
import CryptoKit

/// Describes the version waiting in the project folder (written together with the new source code).
struct ReleaseInfo: Codable, Equatable {
    var version: String
    var build: Int
    var date: String?
    var notes: [String]
}

/// Self-updater: new versions arrive as source code in the project folder on this Mac.
/// The app builds them with the locally installed Xcode, replaces itself in /Applications and relaunches.
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case building
        case installing
        case failed(String)
    }

    static let folderKey = "updateSourceFolder"

    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("מחשבון שכר", isDirectory: true)
    }

    /// The project folder that holds Maskoret.xcodeproj, version.json and rates/.
    static var sourceFolder: URL {
        if let path = UserDefaults.standard.string(forKey: folderKey) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultFolder
    }

    @Published var folder: URL = Updater.sourceFolder
    @Published var latest: ReleaseInfo?
    @Published var phase: Phase = .idle
    @Published var log: [String] = []
    @Published var lastCheck: Date?
    @Published var message: String = ""

    let currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let currentBuild: Int = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0

    var updateAvailable: Bool { (latest?.build ?? 0) > currentBuild }

    var isBusy: Bool { phase == .building || phase == .installing }

    var isInApplications: Bool {
        Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications"
    }

    var installURL: URL {
        URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
    }

    var projectURL: URL { folder.appendingPathComponent("Maskoret.xcodeproj") }

    var hasProject: Bool { FileManager.default.fileExists(atPath: projectURL.path) }

    // MARK: Checking

    /// Where everyone else's Mac gets updates: the public releases page.
    static let releasesManifest = URL(string: "https://shlomoappdev-netizen.github.io/maskoret-releases/latest.json")!

    private struct Manifest: Decodable {
        /// Each platform goes out as soon as its build is ready, so it carries its own version and build
        /// (the top-level ones are the oldest of them).
        struct Asset: Decodable {
            let url: URL; let sha256: String; let size: Int?; let version: String?; let build: Int?
            /// Ed25519 signature of the release key (UpdateTrust); an entry without a valid one is never installed.
            let sig: String?

            var isTrusted: Bool {
                UpdateTrust.isAllowedDownload(url)
                    && UpdateTrust.isSigned(platform: "mac", version: version, build: build, sha256: sha256, signature: sig)
            }
        }
        let version: String
        let build: Int
        let date: String?
        let notes: [String]
        let platforms: [String: Asset]
    }

    /// The Mac download of the newest release (when updating from the server).
    private var remoteMac: Manifest.Asset?

    static let buildFromSourceKey = "updateBuildFromSource"

    /// Developer option: build updates from the source in the project folder instead of downloading them.
    @Published var buildFromSource: Bool = UserDefaults.standard.bool(forKey: Updater.buildFromSourceKey) {
        didSet {
            UserDefaults.standard.set(buildFromSource, forKey: Updater.buildFromSourceKey)
            latest = nil
            check()
        }
    }

    /// Updates come from the server — the same signed build everyone gets — unless the developer option is on.
    var updatesFromServer: Bool { !(buildFromSource && hasProject) }

    func check() {
        guard !isBusy else { return }
        lastCheck = Date()
        if updatesFromServer {
            checkServer()
            return
        }
        let url = folder.appendingPathComponent("version.json")
        guard let data = try? Data(contentsOf: url),
              let info = try? JSONDecoder().decode(ReleaseInfo.self, from: data) else {
            latest = nil
            message = hasProject
                ? "לא נמצא קובץ version.json בתיקיית הפרויקט"
                : "תיקיית הפרויקט לא נמצאה — בחר אותה למטה"
            return
        }
        latest = info
        message = updateAvailable
            ? "גרסה \(info.version) מוכנה להתקנה"
            : "יש לך את הגרסה העדכנית"
    }

    private func checkServer() {
        var request = URLRequest(url: Updater.releasesManifest)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let manifest = data.flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                guard let manifest, let mac = manifest.platforms["mac"] else {
                    self.message = "לא ניתן לבדוק עדכונים כרגע (אין חיבור לשרת)"
                    return
                }
                // Not signed with the release key (or not from this project's releases): not offered at all.
                guard mac.isTrusted else {
                    self.remoteMac = nil
                    self.latest = nil
                    self.message = "לא ניתן לאמת את העדכון שבשרת — הוא לא יותקן. נסה שוב מאוחר יותר."
                    return
                }
                self.remoteMac = mac
                self.latest = ReleaseInfo(version: mac.version ?? manifest.version, build: mac.build ?? manifest.build,
                                          date: manifest.date, notes: manifest.notes)
                self.message = self.updateAvailable ? "גרסה \(manifest.version) זמינה להורדה" : "יש לך את הגרסה העדכנית"
            }
        }.resume()
    }

    /// Downloads the newest Mac build, checks it's the exact published file, and installs it like a local build.
    private func downloadAndInstall() {
        guard let asset = remoteMac, asset.isTrusted else {
            phase = .failed("לא נמצאה גרסה להורדה. נסה ״בדוק עכשיו״.")
            return
        }
        phase = .installing
        log = ["מוריד את הגרסה החדשה…"]
        download(asset.url, attempt: 1) { [weak self] file, response, error in
            guard let self else { return }
            let fail: (String) -> Void = { text in DispatchQueue.main.async { self.phase = .failed(text) } }
            // GitHub sometimes answers with an error page (e.g. 504) instead of the file.
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                fail("שרת ההורדות של GitHub לא זמין כרגע (שגיאה \(status)). נסה שוב בעוד כמה דקות.")
                return
            }
            guard let file, error == nil, let data = try? Data(contentsOf: file) else {
                fail("ההורדה נכשלה: " + (error?.localizedDescription ?? "בדוק את החיבור לאינטרנט"))
                return
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == asset.sha256.lowercased() else {
                fail("הקובץ שהורד לא תואם לגרסה שפורסמה — ההתקנה בוטלה.")
                return
            }
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("maskoret-update-\(UUID().uuidString)", isDirectory: true)
            let mount = work.appendingPathComponent("mnt", isDirectory: true)
            let stage = work.appendingPathComponent("app", isDirectory: true)
            let dmg = work.appendingPathComponent("update.dmg")
            do {
                try fm.createDirectory(at: mount, withIntermediateDirectories: true)
                try fm.createDirectory(at: stage, withIntermediateDirectories: true)
                try data.write(to: dmg)
            } catch {
                fail("לא ניתן לשמור את ההורדה: " + error.localizedDescription)
                return
            }
            _ = Updater.output("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
            let apps = ((try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
            if let app = apps.first {
                _ = Updater.output("/usr/bin/ditto", [app.path, stage.appendingPathComponent(app.lastPathComponent).path])
            }
            _ = Updater.output("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            // The app itself must carry the owner's signature, unchanged.
            let staged = apps.first.map { stage.appendingPathComponent($0.lastPathComponent) }
            let trusted = staged.map { UpdateTrust.isTrustedApp(at: $0) } ?? false
            DispatchQueue.main.async {
                if apps.isEmpty {
                    self.phase = .failed("לא נמצאה אפליקציה בקובץ שהורד.")
                } else if !trusted {
                    try? fm.removeItem(at: work)
                    self.phase = .failed("האפליקציה שהורדה לא חתומה בחתימה של מחשבון שכר — ההתקנה בוטלה.")
                } else {
                    self.installBuilt(from: stage, downloaded: true)
                }
            }
        }
    }

    /// Downloads a file, trying again a few times when the server answers with a temporary error (5xx) or the
    /// connection drops. The handler runs inside the download's own callback, while the file still exists.
    /// When the regular link keeps failing, the same file is fetched once more through the GitHub API
    /// (a different server, which kept working when the download links answered 504).
    private func download(_ url: URL, attempt: Int, viaAPI: Bool = false,
                          completion: @escaping (URL?, URLResponse?, Error?) -> Void) {
        URLSession.shared.downloadTask(with: url) { [weak self] file, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let temporary = error != nil || (500...599).contains(status)
            if temporary, attempt < 3, let self {
                DispatchQueue.main.async { self.log.append("השרת לא ענה — מנסה שוב (\(attempt + 1)/3)…") }
                DispatchQueue.global().asyncAfter(deadline: .now() + Double(attempt * 10)) {
                    self.download(url, attempt: attempt + 1, completion: completion)
                }
                return
            }
            if temporary, !viaAPI, let self {
                DispatchQueue.main.async { self.log.append("מנסה דרך שרת אחר של GitHub…") }
                self.downloadViaAPI(url) { file2, response2, error2 in
                    // Whatever the API gave; if it also failed, report the original failure.
                    if file2 != nil, (response2 as? HTTPURLResponse)?.statusCode == 200 {
                        completion(file2, response2, error2)
                    } else {
                        completion(file, response, error)
                    }
                }
                return
            }
            completion(file, response, error)
        }.resume()
    }

    /// github.com/<owner>/<repo>/releases/download/<tag>/<name> → the same asset through api.github.com.
    private func downloadViaAPI(_ url: URL, completion: @escaping (URL?, URLResponse?, Error?) -> Void) {
        let parts = url.pathComponents   // ["/", owner, repo, "releases", "download", tag, name]
        guard url.host == "github.com", parts.count == 7, parts[3] == "releases", parts[4] == "download",
              let release = URL(string: "https://api.github.com/repos/\(parts[1])/\(parts[2])/releases/tags/\(parts[5])")
        else { completion(nil, nil, nil); return }
        var request = URLRequest(url: release)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            struct Release: Decodable { struct Asset: Decodable { let name: String; let url: URL }; let assets: [Asset] }
            guard let data, let info = try? JSONDecoder().decode(Release.self, from: data),
                  let asset = info.assets.first(where: { $0.name == parts[6] }) else {
                completion(nil, nil, nil)
                return
            }
            var fileRequest = URLRequest(url: asset.url)
            fileRequest.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            URLSession.shared.downloadTask(with: fileRequest) { file, response, error in
                completion(file, response, error)
            }.resume()
        }.resume()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "בחר"
        panel.message = "בחר את התיקייה שבה נמצא Maskoret.xcodeproj"
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
            UserDefaults.standard.set(url.path, forKey: Updater.folderKey)
            check()
        }
    }

    // MARK: Stable signature (permissions survive updates)

    /// macOS remembers file-access permissions per code signature. Ad-hoc builds get a new signature
    /// every time, so each update looks like a new app. A certificate with this name keeps it fixed.
    static let signingName = "Maskoret Signing"

    static func output(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The certificate exists in the keychain.
    static var hasSigningIdentity: Bool {
        output("/usr/bin/security", ["find-identity", "-p", "codesigning"]).contains("\"\(signingName)\"")
    }

    /// This running copy is already signed with it.
    var isStableSigned: Bool {
        Updater.output("/usr/bin/codesign", ["-dvv", Bundle.main.bundlePath]).contains("Authority=\(Updater.signingName)")
    }

    /// Signs the installed app with the user's certificate now and relaunches it (no rebuild).
    func signNowAndRelaunch() {
        let target = isInApplications ? installURL.path : Bundle.main.bundlePath
        let script = """
        #!/bin/bash
        PID="$1"; APP="$2"
        for i in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
        /usr/bin/codesign --force --sign "\(Updater.signingName)" "$APP"
        /usr/bin/open "$APP"
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maskoret-sign.sh")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/bash")
            helper.arguments = [url.path, String(ProcessInfo.processInfo.processIdentifier), target]
            try helper.run()
            KeychainHandoff.export()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        } catch {
            message = "החתימה נכשלה: " + error.localizedDescription
        }
    }

    // MARK: DMG for friends

    /// After every update a fresh "מחשבון שכר.dmg" replaces the old one here.
    var distributionFolder: URL { folder.appendingPathComponent("להפצה", isDirectory: true) }
    var dmgURL: URL { distributionFolder.appendingPathComponent("מחשבון שכר.dmg") }
    @Published var dmgBusy = false
    @Published var dmgMessage = ""

    /// Bash that packs APP into a drag-to-Applications DMG and swaps it in for the previous one.
    static func dmgScript(app: String, outDir: String, volume: String) -> String {
        """
        OUT_DIR=\(outDir); VOL=\(volume); APP_PATH=\(app)
        mkdir -p "$OUT_DIR"
        STAGE="$(mktemp -d)"
        /usr/bin/ditto "$APP_PATH" "$STAGE/$(basename "$APP_PATH")"
        ln -s /Applications "$STAGE/Applications"
        if /usr/bin/hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$OUT_DIR/.new.dmg"; then
          mv -f "$OUT_DIR/.new.dmg" "$OUT_DIR/מחשבון שכר.dmg"
        fi
        rm -rf "$STAGE"
        """
    }

    /// Builds the DMG now from the installed app.
    func makeDMG() {
        guard !dmgBusy else { return }
        dmgBusy = true
        dmgMessage = "יוצר DMG…"
        let script = "#!/bin/bash\n" + Updater.dmgScript(app: "\"$1\"", outDir: "\"$2\"", volume: "\"$3\"")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maskoret-dmg.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [url.path, Bundle.main.bundlePath, distributionFolder.path, "מחשבון שכר " + currentVersion]
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.dmgBusy = false
                self?.dmgMessage = p.terminationStatus == 0 ? "ה-DMG מוכן" : "יצירת ה-DMG נכשלה"
            }
        }
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try process.run()
        } catch {
            dmgBusy = false
            dmgMessage = error.localizedDescription
        }
    }

    // MARK: Building & installing

    static func developerDir() -> String? {
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        let xcodes = apps
            .filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
            .sorted { lhs, rhs in
                if lhs == "Xcode.app" { return true }
                if rhs == "Xcode.app" { return false }
                return lhs < rhs
            }
        for name in xcodes {
            let path = "/Applications/\(name)/Contents/Developer"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    private func append(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        log.append(contentsOf: lines)
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    /// Builds the source in the project folder (Release) and installs it to /Applications.
    func buildAndInstall() {
        guard !isBusy else { return }
        if updatesFromServer {
            downloadAndInstall()
            return
        }
        guard hasProject else {
            phase = .failed("לא נמצא Maskoret.xcodeproj בתיקייה \(folder.path)")
            return
        }
        guard let developerDir = Updater.developerDir() else {
            phase = .failed("לא נמצא Xcode בתיקיית Applications — הוא נחוץ כדי לבנות את הגרסה החדשה.")
            return
        }

        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Maskoret-build", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let productsDir = cache.appendingPathComponent("products", isDirectory: true)
        let releaseDir = productsDir.appendingPathComponent("Release", isDirectory: true)
        try? FileManager.default.removeItem(at: releaseDir)

        var args = [
            "-project", projectURL.path,
            "-target", "Maskoret",
            "-configuration", "Release",
            "SYMROOT=\(productsDir.path)",
            "OBJROOT=\(cache.appendingPathComponent("obj").path)",
            "CODE_SIGN_IDENTITY=-",
            // Swift packages (the built-in AI engine): keep their checkout in the cache and allow their macros.
            "-clonedSourcePackagesDirPath", cache.appendingPathComponent("packages").path,
            "-skipMacroValidation",
            "-skipPackagePluginValidation"
        ]
        if let info = latest {
            args.append("MARKETING_VERSION=\(info.version)")
            args.append("CURRENT_PROJECT_VERSION=\(info.build)")
        }
        args.append("build")

        log = ["$ xcodebuild " + args.joined(separator: " "), ""]
        phase = .building

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = args
        process.environment = [
            "DEVELOPER_DIR": developerDir,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LANG": "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory()
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.append(text) }
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                guard let self else { return }
                if status == 0 {
                    self.installBuilt(from: releaseDir)
                } else {
                    self.phase = .failed("הבנייה נכשלה (קוד \(status)). הפרטים ביומן הבנייה למטה.")
                }
            }
        }

        do {
            try process.run()
        } catch {
            phase = .failed("לא ניתן להפעיל את xcodebuild: \(error.localizedDescription)")
        }
    }

    /// `downloaded`: a release from the server, already checked by UpdateTrust — installed exactly as it is.
    /// Otherwise a build made on this Mac from the project folder, which is signed here with the local certificate.
    private func installBuilt(from releaseDir: URL, downloaded: Bool = false) {
        phase = .installing
        let items = (try? FileManager.default.contentsOfDirectory(at: releaseDir, includingPropertiesForKeys: nil)) ?? []
        guard let builtApp = items.first(where: { $0.pathExtension == "app" }) else {
            phase = .failed("הבנייה הצליחה אבל לא נמצאה האפליקציה שנבנתה.")
            return
        }

        // A tiny helper waits for this app to quit, swaps the bundle and opens the new one.
        // When the user created the "Maskoret Signing" certificate, the build is signed with it,
        // so macOS keeps the file permissions between updates.
        let script = """
        #!/bin/bash
        PID="$1"; SRC="$2"; DST="$3"; NAME="\(Updater.signingName)"
        # Only a local build is signed here; a downloaded one must stay exactly as published (checked before).
        if [ "\(downloaded ? 1 : 0)" = 0 ] && ! /usr/bin/codesign -dvv "$SRC" 2>&1 | grep -qF "Authority=$NAME" \\
            && /usr/bin/security find-identity -p codesigning | grep -qF "\\"$NAME\\""; then
          /usr/bin/codesign --force --sign "$NAME" "$SRC"
        fi
        for i in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
        rm -rf "$DST"
        /usr/bin/ditto "$SRC" "$DST" && /usr/bin/open "$DST"
        \(hasProject ? Updater.dmgScript(app: "$DST", outDir: "$4", volume: "$5") : "")
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("maskoret-install.sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/bash")
            helper.arguments = [
                scriptURL.path,
                String(ProcessInfo.processInfo.processIdentifier),
                builtApp.path,
                installURL.path,
                distributionFolder.path,
                "מחשבון שכר " + (latest?.version ?? currentVersion)
            ]
            try helper.run()
            KeychainHandoff.export()
            append("מתקין אל \(installURL.path) ופותח מחדש…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
        } catch {
            phase = .failed("ההתקנה נכשלה: \(error.localizedDescription)")
        }
    }
}

// MARK: - Keychain handoff between versions

/// macOS ties every keychain item this app saves to the exact build that saved it ("cdhash" partition), because the
/// app is signed with a personal certificate and has no Apple team ID. So each update asked for the login password,
/// once per item. Instead, the running version — which already has access — hands its items to the next one:
/// it moves them into a file only this user can read, right before the update replaces it, and the new version
/// adds them back to the keychain as its own (adding needs no password) and deletes the file at once.
enum KeychainHandoff {
    static let services = ["com.shlomodavid.maskoret.auth", "com.shlomodavid.maskoret.ai", "com.shlomodavid.maskoret.cache"]

    private struct Item: Codable {
        let service: String
        let account: String
        let label: String?
        let data: Data
    }

    private static var file: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.shlomodavid.maskoret", isDirectory: true)
        return support.appendingPathComponent("keychain-handoff.json")
    }

    /// The old version, just before it quits for the update.
    static func export() {
        var items: [Item] = []
        for service in services {
            let list: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: service,
                                       kSecReturnAttributes as String: true,
                                       kSecMatchLimit as String: kSecMatchLimitAll]
            var out: CFTypeRef?
            guard SecItemCopyMatching(list as CFDictionary, &out) == errSecSuccess,
                  let rows = out as? [[String: Any]] else { continue }
            for account in Set(rows.compactMap { $0[kSecAttrAccount as String] as? String }) {
                let one: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                          kSecAttrService as String: service,
                                          kSecAttrAccount as String: account,
                                          kSecReturnData as String: true,
                                          kSecReturnAttributes as String: true,
                                          kSecMatchLimit as String: kSecMatchLimitOne]
                var value: CFTypeRef?
                guard SecItemCopyMatching(one as CFDictionary, &value) == errSecSuccess,
                      let row = value as? [String: Any], let data = row[kSecValueData as String] as? Data else { continue }
                items.append(Item(service: service, account: account, label: row[kSecAttrLabel as String] as? String, data: data))
            }
        }
        guard !items.isEmpty, let json = try? JSONEncoder().encode(items) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Created readable by this user only, before any secret is written into it.
        guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: file) else { return }
        do {
            try handle.write(contentsOf: json)
            try handle.close()
        } catch {
            try? fm.removeItem(at: file)
            return
        }
        // The old copies would ask for the password again in the new version; this version may still delete them.
        for item in items {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: item.service,
                           kSecAttrAccount as String: item.account] as CFDictionary)
        }
    }

    /// The new version, first thing at launch.
    static func importIfNeeded() {
        guard let data = try? Data(contentsOf: file) else { return }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let items = try? JSONDecoder().decode([Item].self, from: data) else { return }
        for item in items where services.contains(item.service) {
            var add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: item.service,
                                      kSecAttrAccount as String: item.account,
                                      kSecValueData as String: item.data]
            if let label = item.label { add[kSecAttrLabel as String] = label }
            if SecItemAdd(add as CFDictionary, nil) == errSecDuplicateItem {
                // An older copy is still there (the old version couldn't delete it): replace it if allowed.
                SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                               kSecAttrService as String: item.service,
                               kSecAttrAccount as String: item.account] as CFDictionary)
                SecItemAdd(add as CFDictionary, nil)
            }
        }
    }
}
