import SwiftUI
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers

struct BackupView: View {
    @EnvironmentObject private var store: Store

    @State private var autoBackup = Store.autoBackupEnabled
    @State private var folder = Store.backupFolder
    @State private var lastBackup = Store.lastBackupAt
    @State private var backups: [URL] = []
    @State private var shareURL: URL?
    @State private var message: String = ""
    @State private var pending: PendingRestore?
    @State private var importing = false

    struct PendingRestore: Identifiable {
        let id = UUID()
        let url: URL
        let backup: BackupFile
    }

    var body: some View {
        NavigationStack {
            Form {
                autoSection
                exportSection
                restoreSection
            }
            .formStyle(.grouped)
            .navigationTitle("גיבוי ושחזור")
            .onAppear(perform: reload)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result { prepareRestore(url) }
            }
            .confirmationDialog(
                "לשחזר את הגיבוי?",
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible,
                presenting: pending
            ) { item in
                Button("שחזר — החלף את כל הנתונים", role: .destructive) {
                    store.restore(item.backup)
                    message = "השחזור הושלם. הנתונים הקודמים נשמרו בגיבוי ״לפני שחזור״."
                    reload()
                }
                Button("ביטול", role: .cancel) {}
            } message: { item in
                Text(verbatim: "גיבוי מ-" + Fmt.date(item.backup.createdAt) + " (גרסה " + item.backup.appVersion + "). "
                     + "\(item.backup.data.money?.accounts.count ?? 0) חשבונות, \(item.backup.data.history.count) חודשים רשומים. "
                     + "כל הנתונים הנוכחיים יוחלפו — לפני כן נשמר גיבוי שלהם.")
            }
        }
    }

    private func reload() {
        folder = Store.backupFolder
        lastBackup = Store.lastBackupAt
        backups = store.listBackups()
        shareURL = store.shareableBackup()
    }

    // MARK: Sections

    private var autoSection: some View {
        Section {
            Toggle("גיבוי אוטומטי פעם ביום", isOn: $autoBackup)
                .onChange(of: autoBackup) { _, on in
                    Store.autoBackupEnabled = on
                    if on { store.autoBackupIfNeeded(); reload() }
                }
            #if os(macOS)
            RateLine(title: "תיקיית הגיבויים", value: folder.path)
            #endif
            HStack {
                #if os(macOS)
                Button("שנה תיקייה…", action: chooseFolder)
                Button("הצג ב-Finder") {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
                Spacer()
                #endif
                Button {
                    do {
                        try store.backupNow()
                        message = "נשמר גיבוי ב-" + folder.lastPathComponent
                    } catch {
                        message = "הגיבוי נכשל: " + error.localizedDescription
                    }
                    reload()
                } label: {
                    Label("גבה עכשיו", systemImage: "externaldrive.fill.badge.checkmark")
                }
                .buttonStyle(.borderedProminent)
            }
            if let lastBackup {
                RateLine(title: "גיבוי אחרון", value: lastBackup.formatted(.dateTime.day().month().year().hour().minute().locale(Fmt.locale)))
            }
            if !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("גיבוי אוטומטי")
        } footer: {
            #if os(iOS)
            Text("הגיבויים נשמרים בטלפון, באפליקציית ״קבצים״ ← ״בטלפון שלי״ ← ״מחשבון שכר״. נשמרים 30 הגיבויים האחרונים. הסנכרון עם המחשב נעשה במסך ״סנכרון iCloud״.")
            #else
            Text(folder.path.contains("Mobile Documents")
                 ? "הגיבויים נשמרים ב-iCloud Drive, כך שהם מגובים גם בענן ומופיעים בכל מכשיר שמחובר לאותו Apple ID. נשמרים 30 הגיבויים האחרונים."
                 : "נשמרים 30 הגיבויים האחרונים. אפשר לבחור תיקייה של Google Drive / Dropbox / iCloud כדי שהגיבוי יעלה לענן.")
            #endif
        }
    }

    private var exportSection: some View {
        Section {
            HStack {
                #if os(macOS)
                Button {
                    saveAs()
                } label: {
                    Label("שמור קובץ גיבוי…", systemImage: "square.and.arrow.down")
                }
                #endif
                if let shareURL {
                    ShareLink(item: shareURL, preview: SharePreview("גיבוי מחשבון שכר")) {
                        Label("שלח גיבוי (WhatsApp, מייל, AirDrop)…", systemImage: "square.and.arrow.up")
                    }
                }
                Spacer()
            }
        } header: {
            Text("ייצוא והעברה")
        } footer: {
            Text("קובץ הגיבוי הוא קובץ אחד שמכיל את כל הנתונים: הכנסות, ניכויים, הוצאות, חשבונות, תנועות, חודשים ומעקב רכישות. כדי לעבור למחשב אחר — שולחים את הקובץ, מתקינים שם את האפליקציה ובוחרים ״שחזר מקובץ״.")
        }
    }

    private var restoreSection: some View {
        Section {
            Button {
                openBackup()
            } label: {
                Label("שחזר מקובץ…", systemImage: "arrow.counterclockwise")
            }
            if backups.isEmpty {
                Text("עוד אין גיבויים בתיקייה.")
                    .foregroundStyle(.secondary)
            }
            ForEach(backups.prefix(10), id: \.self) { url in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.deletingPathExtension().lastPathComponent)
                        Text(verbatim: store.modified(url).formatted(.dateTime.day().month().year().hour().minute().locale(Fmt.locale)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("שחזר") { prepareRestore(url) }
                }
            }
        } header: {
            Text("שחזור")
        } footer: {
            Text("לפני כל שחזור האפליקציה שומרת גיבוי של הנתונים הנוכחיים, כך שאפשר תמיד לחזור אחורה.")
        }
    }

    // MARK: Actions

    #if os(macOS)
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "בחר"
        if panel.runModal() == .OK, let url = panel.url {
            Store.backupFolder = url
            reload()
        }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Store.backupFileName()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try store.backupData().write(to: url, options: [.atomic])
                message = "הגיבוי נשמר: " + url.lastPathComponent
            } catch {
                message = "השמירה נכשלה: " + error.localizedDescription
            }
        }
    }

    private func openBackup() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url {
            prepareRestore(url)
        }
    }
    #else
    private func openBackup() { importing = true }
    #endif

    private func prepareRestore(_ url: URL) {
        do {
            pending = PendingRestore(url: url, backup: try FolderBookmark.access(url) { try Store.readBackup(at: url) })
        } catch {
            message = error.localizedDescription
        }
    }
}
