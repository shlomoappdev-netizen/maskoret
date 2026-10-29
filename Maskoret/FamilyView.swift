import SwiftUI

/// Sidebar block: who is in the view (checkboxes) and who is being edited (✏️).
struct FamilySwitcher: View {
    @EnvironmentObject private var store: Store
    @State private var editing: FamilyMember?
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("משפחה")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if store.hasFamily {
                    Button(store.isCombined && store.viewMemberIDs.count == store.members.count ? "כל אחד לבד" : "כולם יחד") {
                        if store.viewMemberIDs.count == store.members.count {
                            store.showOnly(store.activeMemberID)
                        } else {
                            store.showEveryone()
                        }
                    }
                    .linkButtonStyle()
                    .font(.caption)
                }
                Button {
                    adding = true
                } label: {
                    Image(systemName: "person.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("הוספת בן משפחה")
            }
            ForEach(store.members) { member in
                row(member)
            }
            if store.isCombined {
                Text("הסיכום, התחזית והתובנות מציגים את המסומנים יחד. העריכה — של ✏️.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .sheet(item: $editing) { member in
            MemberSheet(member: member, isNew: false) { store.updateMember($0) }
                .environmentObject(store)
        }
        .sheet(isPresented: $adding) {
            MemberSheet(member: FamilyMember(), isNew: true) { store.addMember(name: $0.name, emoji: $0.emoji) }
                .environmentObject(store)
        }
    }

    private func row(_ member: FamilyMember) -> some View {
        let isEditing = member.id == store.activeMemberID
        let inView = store.viewMemberIDs.contains(member.id)
        return HStack(spacing: 6) {
            if store.hasFamily {
                Toggle("", isOn: Binding(get: { inView }, set: { _ in store.toggleInView(member.id) }))
                    .checkboxToggle()
                    .labelsHidden()
                    .help("להציג בסיכום, בתחזית ובתובנות")
            }
            Button {
                if store.isCombined { store.setEditing(member.id) } else { store.showOnly(member.id) }
            } label: {
                HStack {
                    Text(verbatim: member.title)
                        .fontWeight(isEditing ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer()
                    if isEditing && store.hasFamily {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(isEditing && store.hasFamily ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button("רק \(member.name)") { store.showOnly(member.id) }
            Button("עריכת הפרטים של \(member.name)…") { editing = member }
            if member.id != store.primaryMemberID {
                Divider()
                Button("מחיקת \(member.name) והנתונים שלו", role: .destructive) { store.deleteMember(member.id) }
            }
        }
    }
}

/// Add / rename a family member.
struct MemberSheet: View {
    @State var member: FamilyMember
    let isNew: Bool
    let onSave: (FamilyMember) -> Void

    private let presets: [(String, String)] = [("👨", "אבא"), ("👩", "אמא"), ("🏠", "משותף"), ("🧒", "ילד"), ("👴", "סבא"), ("👵", "סבתא")]

    var body: some View {
        SheetContainer(title: isNew ? "בן משפחה חדש" : "עריכת בן משפחה", saveTitle: isNew ? "הוספה" : "שמירה", minHeight: 360,
                       onSave: { onSave(member) }) {
            Section {
                FormTextField("שם", text: $member.name, prompt: Text("למשל: נועה"))
                FormTextField("אימוג׳י", text: $member.emoji)
            } footer: {
                Text(isNew
                     ? "לכל בן משפחה יש תלוש, ניכויים, הוצאות קבועות, חשבונות, כרטיס אשראי, מגמות וחודשים משלו. אפשר לראות כל אחד לבד או כמה יחד (סימון ✓ בסרגל הצד). טיפ: בן משפחה בשם ״🏠 משותף״ מתאים לחשבון משותף ולהוצאות של הבית כמו שכירות."
                     : "")
            }
            if isNew {
                Section("הצעות") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
                        ForEach(presets, id: \.1) { p in
                            Button(p.0 + " " + p.1) {
                                member.emoji = p.0
                                if member.name.isEmpty || presets.contains(where: { $0.1 == member.name }) { member.name = p.1 }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Thin bar above every page: who is being edited, and who the dashboards show.
struct FamilyContextBar: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        if store.hasFamily, let me = store.activeMember {
            HStack(spacing: 14) {
                Label {
                    Text(verbatim: "עריכה: " + me.title)
                } icon: {
                    Image(systemName: "pencil")
                }
                if store.isCombined {
                    Label {
                        Text(verbatim: "סיכום, תחזית ותובנות: " + store.viewedMembers.map(\.title).joined(separator: " + "))
                    } icon: {
                        Image(systemName: "person.2.fill")
                    }
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}
