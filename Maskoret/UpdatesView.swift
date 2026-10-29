import SwiftUI
import AppKit

struct UpdatesView: View {
    @EnvironmentObject private var updater: Updater

    var body: some View {
        NavigationStack {
            Form {
                versionSection
                updateSection
                SigningSection()
                ShareAppSection()
                folderSection
                if !updater.log.isEmpty {
                    logSection
                }
            }
            .formStyle(.grouped)
            .navigationTitle("עדכונים")
        }
        .onAppear { updater.check() }
    }

    // MARK: Sections

    private var versionSection: some View {
        Section("הגרסה שלך") {
            RateLine(title: "גרסה", value: "\(updater.currentVersion) (\(updater.currentBuild))")
            RateLine(title: "מיקום", value: Bundle.main.bundleURL.path)
            if !updater.isInApplications {
                VStack(alignment: .leading, spacing: 8) {
                    Label("האפליקציה עדיין לא מותקנת בתיקיית Applications", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("ההתקנה בונה גרסה סופית מהקוד בתיקיית הפרויקט, מעתיקה אותה ל-Applications ופותחת אותה משם. הנתונים שלך נשמרים.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        updater.buildAndInstall()
                    } label: {
                        Label("התקן לתיקיית Applications", systemImage: "square.and.arrow.down.on.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.isBusy)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var updateSection: some View {
        Section {
            if let latest = updater.latest, updater.updateAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    Label("גרסה \(latest.version) זמינה", systemImage: "sparkles")
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                    if let date = latest.date {
                        Text(verbatim: date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(latest.notes, id: \.self) { note in
                        Text(verbatim: "• " + note)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        updater.buildAndInstall()
                    } label: {
                        Label("עדכן עכשיו", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(updater.isBusy)
                    .padding(.top, 4)
                }
                .padding(.vertical, 4)
            } else if !updater.message.isEmpty {
                Label(updater.message, systemImage: updater.latest == nil ? "questionmark.folder" : "checkmark.seal.fill")
                    .foregroundStyle(updater.latest == nil ? Color.secondary : Color.green)
            }

            phaseView

            HStack {
                Button {
                    updater.check()
                } label: {
                    Label("בדוק עכשיו", systemImage: "arrow.clockwise")
                }
                .disabled(updater.isBusy)
                Spacer()
                if let last = updater.lastCheck {
                    Text(verbatim: "נבדק " + last.formatted(.dateTime.hour().minute().locale(Fmt.locale)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("עדכון")
        } footer: {
            Text("כש-Claude מכין גרסה חדשה הוא מעדכן את הקוד בתיקיית הפרויקט. האפליקציה בודקת את התיקייה בכל פעם שהיא נפתחת, ובלחיצה על ״עדכן עכשיו״ בונה את הגרסה החדשה עם Xcode שמותקן אצלך (כדקה), מחליפה את עצמה ונפתחת מחדש.")
        }
    }

    @ViewBuilder
    private var phaseView: some View {
        switch updater.phase {
        case .idle:
            EmptyView()
        case .building:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("בונה את הגרסה החדשה… זה לוקח בערך דקה.")
            }
        case .installing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("מתקין ופותח מחדש…")
            }
        case .failed(let reason):
            Label(reason, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var folderSection: some View {
        Section {
            RateLine(title: "תיקיית הפרויקט", value: updater.folder.path)
            HStack {
                Button("שנה תיקייה…") { updater.chooseFolder() }
                Button("הצג ב-Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([updater.folder])
                }
                Spacer()
                if !updater.hasProject {
                    Label("לא נמצא Maskoret.xcodeproj", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
        } header: {
            Text("מקור העדכונים")
        }
    }

    private var logSection: some View {
        Section {
            DisclosureGroup("יומן בנייה") {
                ScrollView {
                    Text(verbatim: updater.log.suffix(120).joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .environment(\.layoutDirection, .leftToRight)
                }
                .frame(height: 220)
            }
        }
    }
}

/// Stable signature, so macOS stops asking for file access after every update.
struct SigningSection: View {
    @EnvironmentObject private var updater: Updater
    @State private var hasCertificate = false
    @State private var signed = false

    var body: some View {
        Section {
            if signed {
                Label("האפליקציה חתומה בחתימה קבועה — macOS זוכר את ההרשאות גם אחרי עדכונים", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else if hasCertificate {
                HStack {
                    Label("התעודה ״\(Updater.signingName)״ נמצאה", systemImage: "checkmark.circle")
                    Spacer()
                    Button("חתום עכשיו ופתח מחדש") { updater.signNowAndRelaunch() }
                        .buttonStyle(.borderedProminent)
                }
                Text("אם macOS שואל ״codesign רוצה להשתמש במפתח״ — הקלד את סיסמת המחשב ובחר ״אפשר תמיד״. אחרי הפתיחה מחדש תאשר פעם אחת אחרונה את הגישה לקבצים.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Label("עדיין אין תעודת חתימה — לכן כל עדכון שואל שוב על גישה לקבצים", systemImage: "exclamationmark.shield")
                VStack(alignment: .leading, spacing: 4) {
                    Text("יצירת תעודה (פעם אחת, דקה):").font(.headline)
                    Text("1. פתח את ״גישה למחזיק מפתחות״ (Keychain Access) — ⌘ רווח והקלד Keychain.")
                    Text("2. בתפריט: Keychain Access ← Certificate Assistant ← Create a Certificate…")
                    Text("3. Name: \(Updater.signingName) · Identity Type: Self-Signed Root · Certificate Type: Code Signing")
                    Text("4. Create ← Continue ← Done. אחר כך חזור לכאן ולחץ ״בדוק שוב״.")
                }
                .font(.callout)
                .textSelection(.enabled)
                HStack {
                    Button("פתח את Keychain Access") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") {
                            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("בדוק שוב", action: refresh)
                }
            }
        } header: {
            Text("עדכונים חלקים")
        } footer: {
            Text("macOS זוכר הרשאות (Documents, iCloud Drive) לפי החתימה של האפליקציה. בלי חתימה קבועה כל עדכון נראה כמו אפליקציה חדשה. התעודה נשמרת רק אצלך במחשב, בלי חשבון אפל.")
        }
        .task { refresh() }
    }

    private func refresh() {
        hasCertificate = Updater.hasSigningIdentity
        signed = updater.isStableSigned
    }
}

/// A ready-to-send DMG of the app, replaced after every update.
struct ShareAppSection: View {
    @EnvironmentObject private var updater: Updater
    @State private var info: (date: Date, size: Int64)?

    var body: some View {
        Section {
            if let info {
                RateLine(title: "מחשבון שכר.dmg",
                         value: Fmt.date(info.date) + " · " + ByteCountFormatter.string(fromByteCount: info.size, countStyle: .file))
            } else {
                Text("עוד לא נוצר DMG — הוא ייווצר לבד בעדכון הבא, או עכשיו בכפתור.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(updater.dmgBusy ? "יוצר…" : "צור DMG עכשיו") { updater.makeDMG() }
                    .disabled(updater.dmgBusy)
                Button("הצג ב-Finder") {
                    let fm = FileManager.default
                    if fm.fileExists(atPath: updater.dmgURL.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([updater.dmgURL])
                    } else {
                        try? fm.createDirectory(at: updater.distributionFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(updater.distributionFolder)
                    }
                }
                if info != nil {
                    ShareLink(item: updater.dmgURL) {
                        Label("שלח (WhatsApp, AirDrop, מייל)…", systemImage: "square.and.arrow.up")
                    }
                }
                Spacer()
            }
            if !updater.dmgMessage.isEmpty {
                Text(updater.dmgMessage).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("שיתוף האפליקציה לחברים")
        } footer: {
            Text("אחרי כל עדכון נוצר בתיקייה ״להפצה״ קובץ ״מחשבון שכר.dmg״ חדש במקום הקודם. החבר פותח אותו וגורר את האפליקציה ל-Applications. בפתיחה הראשונה macOS יגיד שהמפתח לא מאומת — קליק ימני על האפליקציה ← ״פתח״ (או הגדרות המערכת ← פרטיות ואבטחה ← ״פתח בכל זאת״). הנתונים שלך לא נכללים בקובץ — אצל החבר האפליקציה מתחילה ריקה.")
        }
        .task { refresh() }
        .onChange(of: updater.dmgBusy) { _, busy in if !busy { refresh() } }
    }

    private func refresh() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: updater.dmgURL.path)
        if let date = attrs?[.modificationDate] as? Date, let size = attrs?[.size] as? NSNumber {
            info = (date, size.int64Value)
        } else {
            info = nil
        }
    }
}
