import SwiftUI

/// "גרסאות קודמות": the household's history on the server (the newest 30 versions). Nothing is backed up
/// on the device or in iCloud any more — every save on the server keeps the version it replaced.
struct BackupView: View {
    @EnvironmentObject private var sync: ServerSync
    @EnvironmentObject private var account: UserAccount

    @State private var versions: [ServerSync.Version] = []
    @State private var loading = false
    @State private var message: String?
    @State private var restoring: ServerSync.Version?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let h = account.activeHousehold {
                        RateLine(title: "משק הבית", value: h.name)
                        RateLine(title: "הגרסה הנוכחית", value: "\(h.revision)")
                    }
                    if let message {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("כל הנתונים נשמרים בשרת. בכל שמירה הגרסה הקודמת נשמרת כאן, ונשמרות 30 הגרסאות האחרונות. שחזור מחזיר גרסה ישנה בכל המכשירים, והגרסה של עכשיו נשמרת גם היא ברשימה, כך שאפשר לחזור אחורה.")
                }

                Section("גרסאות קודמות (\(versions.count))") {
                    if loading { ProgressView().frame(maxWidth: .infinity) }
                    if !loading && versions.isEmpty {
                        Text("עוד אין גרסאות קודמות. הן נוצרות אוטומטית מהשמירה הבאה.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(versions) { v in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: v.date?.formatted(.dateTime.day().month().year().hour().minute().locale(Fmt.locale)) ?? "—")
                                Text(verbatim: "גרסה \(v.revision)" + (v.device.map { " · " + $0 } ?? ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let note = v.note, !note.isEmpty {
                                    Text(verbatim: note).font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Button("שחזר") { restoring = v }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("גרסאות קודמות")
            .task(id: account.activeHouseholdID) { await load() }
            .refreshable { await load() }
            .confirmationDialog("לשחזר את הגרסה הזו?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                                titleVisibility: .visible, presenting: restoring) { v in
                Button("שחזר בכל המכשירים") {
                    Task {
                        do {
                            try await sync.restore(v)
                            message = "הגרסה שוחזרה. הגרסה הקודמת נשמרה ברשימה."
                        } catch {
                            message = UserAccount.describe(error)
                        }
                        await load()
                    }
                }
                Button("ביטול", role: .cancel) {}
            } message: { v in
                Text(verbatim: "הנתונים של עכשיו יוחלפו בגרסה מ-" + (v.date.map { Fmt.date($0) } ?? "") + ", בכל המכשירים של משק הבית. הנתונים של עכשיו יישמרו ברשימה.")
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            versions = try await sync.versions()
        } catch {
            message = UserAccount.describe(error)
        }
    }
}
