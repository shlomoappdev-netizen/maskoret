import SwiftUI

/// Purchases outside the payslip that repeat every so often (shoes, clothes, a phone…).
struct TrackedItemsView: View {
    @EnvironmentObject private var store: Store
    @State private var newItem: TrackedItem?
    @State private var selectedID: UUID?
    @Environment(\.isCompactWidth) private var compact

    private var items: [TrackedItem] { store.budget.trackedItems }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            PageBar(title: "מעקב רכישות", subtitle: "רכישות מחוץ לתלוש שחוזרות מדי פעם") {
                Menu {
                    Button("פריט חדש…") {
                        newItem = TrackedItem()
                    }
                    Section("הצעות") {
                        ForEach(TrackedItem.presets, id: \.name) { preset in
                            Button(preset.emoji + " " + preset.name) {
                                newItem = TrackedItem(name: preset.name, emoji: preset.emoji, expectedMonths: preset.months)
                            }
                        }
                    }
                } label: {
                    Label("פריט חדש", systemImage: "plus")
                }
                .fixedSize()
            }
            Divider()
            if compact {
                // iPhone: the list, and tapping an item opens it.
                itemList
                    .navigationDestination(item: $selectedID) { id in
                        TrackedItemDetailView(itemID: id)
                    }
            } else {
            HStack(spacing: 0) {
                itemList
                    .frame(width: 340)
                Divider()
                Group {
                    if let id = selectedID, items.contains(where: { $0.id == id }) {
                        TrackedItemDetailView(itemID: id)
                    } else {
                        ContentUnavailableView(
                            "בחר פריט",
                            systemImage: "bag",
                            description: Text("בחר פריט מהרשימה כדי לראות כמה זמן הוא מחזיק לך ולרשום קנייה חדשה.")
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }
            }
            .navigationTitle("מעקב רכישות")
            .sheet(item: $newItem) { item in
                TrackedItemEditor(item: item, isNew: true) { saved, firstPurchase in
                    var saved = saved
                    if let firstPurchase { saved.purchases.append(firstPurchase) }
                    store.upsertTracked(saved)
                    selectedID = saved.id
                }
            }
            .onAppear {
                if selectedID == nil, !compact { selectedID = items.first?.id }
            }
        }
    }

    private var itemList: some View {
        List(selection: $selectedID) {
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("מעקב רכישות")
                        .font(.headline)
                    Text("הוסף דברים שאתה קונה שוב מדי פעם — נעליים, בגדים, טלפון, תספורת. בכל פעם שאתה קונה חדש, רשום את זה, והאפליקציה תחשב כמה זמן זה מחזיק לך וכמה זה עולה לך בחודש.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("הוסף פריט ראשון") { newItem = TrackedItem() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 8)
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("עולה לך בממוצע בחודש")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(verbatim: Fmt.moneyRounded(store.budget.periodicTotal))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(verbatim: "≈ " + Fmt.moneyRounded(store.budget.periodicTotal * 12) + " בשנה · נכלל ביתרה בסיכום")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .selectionDisabled()
                }

                Section("פריטים") {
                    ForEach(items) { item in
                        TrackedRow(item: item)
                            .tag(item.id)
                            .contextMenu {
                                Button(role: .destructive) {
                                    if selectedID == item.id { selectedID = nil }
                                    store.budget.trackedItems.removeAll { $0.id == item.id }
                                } label: {
                                    Label("מחיקת פריט", systemImage: "trash")
                                }
                            }
                    }
                    .onMove { store.budget.trackedItems.move(fromOffsets: $0, toOffset: $1) }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Row

struct TrackedRow: View {
    let item: TrackedItem

    var body: some View {
        HStack(spacing: 10) {
            Text(item.emoji)
                .font(.title2)
                .frame(width: 36, height: 36)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.name)
                        .font(.body.weight(.medium))
                    Spacer()
                    Text(verbatim: Fmt.moneyRounded(item.monthlyCost) + "/חודש")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(item.includeInBudget ? Color.primary : Color.secondary)
                }
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let wear = item.wear {
                    ProgressView(value: min(wear, 1))
                        .tint(wearColor(wear))
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        guard let life = item.averageLifespan else {
            return item.purchases.isEmpty ? "עוד לא נרשמה קנייה" : "הוסף הערכה כמה זמן זה מחזיק"
        }
        let prefix = item.isLifespanMeasured ? "מחזיק בממוצע " : "הערכה: "
        var text = prefix + Fmt.duration(months: life)
        if let age = item.ageMonths {
            text += " · בשימוש " + Fmt.duration(months: age)
        }
        return text
    }
}

func wearColor(_ wear: Double) -> Color {
    if wear >= 1 { return .red }
    if wear >= 0.8 { return .orange }
    return .green
}

// MARK: - Detail

struct TrackedItemDetailView: View {
    @EnvironmentObject private var store: Store
    let itemID: UUID

    @State private var editingPurchase: Purchase?
    @State private var editingItem = false

    private var item: TrackedItem? {
        store.budget.trackedItems.first { $0.id == itemID }
    }

    var body: some View {
        if let item {
            content(item)
        } else {
            ContentUnavailableView("הפריט נמחק", systemImage: "trash")
        }
    }

    private func content(_ item: TrackedItem) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    Text(item.emoji).font(.system(size: 54))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name).font(.title.weight(.bold))
                        if let wear = item.wear, let next = item.nextReplacement {
                            ProgressView(value: min(wear, 1))
                                .tint(wearColor(wear))
                                .frame(maxWidth: 260)
                            Text(verbatim: wear >= 1
                                 ? "עבר את הזמן הממוצע — אולי הגיע הזמן להחליף"
                                 : "החלפה צפויה בערך ב-" + Fmt.date(next))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(spacing: 8) {
                        Button {
                            editingPurchase = Purchase(price: item.lastPurchase?.price ?? 0)
                        } label: {
                            Label("קניתי חדש", systemImage: "cart.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Button("עריכת פריט") { editingItem = true }
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    StatTile(
                        title: item.isLifespanMeasured ? "מחזיק בממוצע" : "הערכת משך שימוש",
                        value: item.averageLifespan.map { Fmt.duration(months: $0) } ?? "—",
                        icon: "hourglass"
                    )
                    StatTile(title: "עלות לחודש", value: Fmt.money((item.monthlyCost * 100).rounded() / 100), icon: "calendar")
                    StatTile(title: "עלות לשנה", value: Fmt.moneyRounded(item.monthlyCost * 12), icon: "calendar.badge.clock")
                    StatTile(title: "מחיר ממוצע", value: item.purchases.isEmpty ? "—" : Fmt.moneyRounded(item.averagePrice), icon: "tag")
                    StatTile(title: "בשימוש כבר", value: item.ageMonths.map { Fmt.duration(months: $0) } ?? "—", icon: "clock")
                    StatTile(title: "סה״כ הוצאת", value: Fmt.moneyRounded(item.totalSpent), icon: "sum")
                }

                Card {
                    HStack {
                        Text("היסטוריית קניות")
                            .font(.headline)
                        Spacer()
                        Text(verbatim: "\(item.purchases.count) קניות")
                            .foregroundStyle(.secondary)
                    }
                    if item.purchases.isEmpty {
                        Text("עוד לא נרשמו קניות. לחץ ״קניתי חדש״ כדי להתחיל.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(item.sortedPurchases.reversed())) { purchase in
                        Button {
                            editingPurchase = purchase
                        } label: {
                            PurchaseRow(purchase: purchase, lasted: item.lasted(purchase))
                        }
                        .buttonStyle(.plain)
                        .rowMenu(onEdit: { editingPurchase = purchase }) {
                            store.deletePurchase(purchase.id, from: item.id)
                        }
                        Divider()
                    }
                    Text("משך השימוש של כל קנייה נמדד עד הקנייה הבאה. מ-2 קניות ומעלה האפליקציה משתמשת בממוצע האמיתי במקום בהערכה. קליק ימני על קנייה למחיקה.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .sheet(item: $editingPurchase) { purchase in
            PurchaseEditor(
                purchase: purchase,
                isNew: !item.purchases.contains { $0.id == purchase.id }
            ) { saved in
                store.addPurchase(saved, to: item.id)
            }
        }
        .sheet(isPresented: $editingItem) {
            TrackedItemEditor(item: item, isNew: false) { saved, _ in
                store.upsertTracked(saved)
            }
        }
    }
}

struct PurchaseRow: View {
    let purchase: Purchase
    let lasted: Double?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Fmt.date(purchase.date))
                    .font(.body.weight(.medium))
                Text(verbatim: lasted.map { "החזיק " + Fmt.duration(months: $0) }
                     ?? "בשימוש כרגע · " + Fmt.duration(months: max(0, monthsBetween(purchase.date, Date()))))
                    .font(.caption)
                    .foregroundStyle(lasted == nil ? Color.accentColor : Color.secondary)
                if !purchase.note.isEmpty {
                    Text(purchase.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(verbatim: Fmt.money(purchase.price))
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Editors

struct TrackedItemEditor: View {
    @State private var item: TrackedItem
    @State private var addFirstPurchase: Bool
    @State private var firstPurchase = Purchase()
    let isNew: Bool
    let onSave: (TrackedItem, Purchase?) -> Void

    private let emojis = ["👟", "👕", "👖", "🧥", "📱", "💻", "👓", "💈", "🔧", "🛞", "🦷", "🛏️", "🎧", "⌚️", "🎒", "🧴", "📄", "📦"]

    init(item: TrackedItem, isNew: Bool, onSave: @escaping (TrackedItem, Purchase?) -> Void) {
        _item = State(initialValue: item)
        _addFirstPurchase = State(initialValue: isNew)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        SheetContainer(
            title: isNew ? "פריט חדש למעקב" : "עריכת פריט",
            width: 520,
            onSave: { onSave(item, isNew && addFirstPurchase ? firstPurchase : nil) }
        ) {
            Section {
                FormTextField("שם", text: $item.name, prompt: Text("למשל: נעלי ריצה"))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 6), count: 9), spacing: 6) {
                    ForEach(emojis, id: \.self) { emoji in
                        Button {
                            item.emoji = emoji
                        } label: {
                            Text(emoji)
                                .font(.title2)
                                .frame(width: 38, height: 38)
                                .background(
                                    item.emoji == emoji ? Color.accentColor.opacity(0.3) : Palette.fill,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section {
                AmountField(title: "כמה זמן זה מחזיק בערך", value: $item.expectedMonths, suffix: "חודשים")
                Toggle("כלול ביתרה החודשית", isOn: $item.includeInBudget)
            } footer: {
                Text("ההערכה משמשת רק עד שיש 2 קניות — אחר כך האפליקציה מחשבת לבד לפי מה שבאמת קרה. העלות החודשית (מחיר ÷ משך שימוש) יורדת מהיתרה בסיכום.")
            }

            if isNew {
                Section {
                    Toggle("רשום את הקנייה האחרונה", isOn: $addFirstPurchase)
                    if addFirstPurchase {
                        DatePicker("מתי קנית", selection: $firstPurchase.date, in: ...Date(), displayedComponents: .date)
                        AmountField(title: "מחיר", value: $firstPurchase.price)
                    }
                } footer: {
                    Text("למשל: מתי קנית את זוג הנעליים שאתה נועל עכשיו וכמה הוא עלה.")
                }
            }
        }
    }
}

struct PurchaseEditor: View {
    @State private var purchase: Purchase
    let isNew: Bool
    let onSave: (Purchase) -> Void

    init(purchase: Purchase, isNew: Bool, onSave: @escaping (Purchase) -> Void) {
        _purchase = State(initialValue: purchase)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        SheetContainer(title: isNew ? "קנייה חדשה" : "עריכת קנייה", width: 420, onSave: { onSave(purchase) }) {
            Section {
                DatePicker("תאריך", selection: $purchase.date, in: ...Date(), displayedComponents: .date)
                AmountField(title: "מחיר", value: $purchase.price)
                FormTextField("הערה", text: $purchase.note, prompt: Text("למשל: דגם, חנות"))
            }
        }
    }
}
