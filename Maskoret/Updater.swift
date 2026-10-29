import Foundation
import AppKit

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

    func check() {
        guard !isBusy else { return }
        lastCheck = Date()
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

    private func installBuilt(from releaseDir: URL) {
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
        if /usr/bin/security find-identity -p codesigning | grep -qF "\\"$NAME\\""; then
          /usr/bin/codesign --force --sign "$NAME" "$SRC"
        fi
        for i in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
        rm -rf "$DST"
        /usr/bin/ditto "$SRC" "$DST" && /usr/bin/open "$DST"
        \(Updater.dmgScript(app: "$DST", outDir: "$4", volume: "$5"))
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
            append("מתקין אל \(installURL.path) ופותח מחדש…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
        } catch {
            phase = .failed("ההתקנה נכשלה: \(error.localizedDescription)")
        }
    }
}
