import SwiftUI

struct IncomesView: View {
    @EnvironmentObject private var store: Store
    @State private var editing: IncomeItem?

    private var incomes: [IncomeItem] { store.budget.incomes }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            PageBar(title: "הכנסות", subtitle: subtitle) {
                Menu {
                    Button("הכנסה רגילה (ברוטו)…") { editing = IncomeItem() }
                    Button("משכורת צה״לית / הכנסה נטו…") {
                        editing = IncomeItem(name: "משכורת צה״לית", isNet: true)
                    }
                } label: {
                    Label("הכנסה חדשה", systemImage: "plus")
                }
                .fixedSize()
            }
            Divider()
            List {
                if !incomes.isEmpty {
                    Section {
                        ForEach(incomes) { item in
                            Button {
                                editing = item
                            } label: {
                                IncomeRow(item: item)
                            }
                            .buttonStyle(.plain)
                            .rowMenu(onEdit: { editing = item }) {
                                store.budget.incomes.removeAll { $0.id == item.id }
                            }
                        }
                        .onMove { store.budget.incomes.move(fromOffsets: $0, toOffset: $1) }
                    } footer: {
                        Text("לחיצה על שורה פותחת עריכה · קליק ימני למחיקה · גרירה לשינוי סדר. משכורת רגילה מזינים ברוטו — הניכויים מחושבים לבד. משכורת צה״לית (או כל הכנסה שכבר נטו) מסמנים ״נטו״ ולא יורדים ממנה ניכויים.")
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        BreakdownLine(title: "סה״כ ברוטו", value: store.budget.gross, emphasized: store.budget.netIncomes == 0)
                        if store.budget.netIncomes > 0 {
                            BreakdownLine(title: "סה״כ נטו (ללא ניכויים)", value: store.budget.netIncomes)
                            BreakdownLine(title: "סה״כ הכנסות", value: store.budget.totalIncome, emphasized: true)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if incomes.isEmpty {
                    ContentUnavailableView {
                        Label("אין הכנסות", systemImage: "banknote")
                    } description: {
                        Text("הוסף משכורת או הכנסה נוספת")
                    } actions: {
                        Button("הוסף הכנסה") { editing = IncomeItem() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            }
            .navigationTitle("הכנסות")
            .sheet(item: $editing) { item in
                IncomeEditor(
                    item: item,
                    isNew: !incomes.contains { $0.id == item.id }
                ) { saved in
                    store.upsertIncome(saved)
                }
            }
        }
    }
}

extension IncomesView {
    fileprivate var subtitle: String {
        let b = store.budget
        if b.netIncomes > 0 && b.gross > 0 {
            return "ברוטו " + Fmt.money(b.gross) + " · נטו " + Fmt.money(b.netIncomes)
        }
        if b.netIncomes > 0 { return "סה״כ נטו: " + Fmt.money(b.netIncomes) }
        return "סה״כ ברוטו: " + Fmt.money(b.gross)
    }
}

struct IncomeRow: View {
    let item: IncomeItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.body.weight(.medium))
                    if item.isNet {
                        Text(verbatim: "נטו")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.2), in: Capsule())
                    }
                }
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(verbatim: Fmt.money(item.rawTotal))
                .monospacedDigit()
                .strikethrough(!item.isActive)
        }
        .padding(.vertical, 4)
        .opacity(item.isActive ? 1 : 0.45)
        .contentShape(Rectangle())
    }
}

struct IncomeEditor: View {
    @State private var item: IncomeItem
    let isNew: Bool
    let onSave: (IncomeItem) -> Void

    init(item: IncomeItem, isNew: Bool, onSave: @escaping (IncomeItem) -> Void) {
        _item = State(initialValue: item)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        SheetContainer(title: isNew ? "הכנסה חדשה" : "עריכת הכנסה", onSave: { onSave(item) }) {
            Section {
                FormTextField("שם", text: $item.name, prompt: Text("למשל: משכורת"))
                Picker("סוג", selection: $item.kind) {
                    ForEach(IncomeKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("הסכום הוא נטו — בלי מס וניכויים", isOn: $item.isNet)
            } footer: {
                Text("לסמן למשכורת צה״לית (דמי קיום בשירות סדיר פטורים ממס, ביטוח לאומי ופנסיה) או לכל הכנסה שאתה כבר יודע כמה ממנה נכנס בפועל.")
            }

            Section {
                if item.kind == .fixed {
                    AmountField(title: item.isNet ? "סכום נטו" : "סכום ברוטו", value: $item.amount)
                } else {
                    AmountField(title: "שעות בחודש", value: $item.hours, suffix: "שעות")
                    AmountField(title: item.isNet ? "תעריף נטו לשעה" : "תעריף לשעה", value: $item.hourlyRate)
                }
            } footer: {
                Text(verbatim: (item.isNet ? "סה״כ נטו: " : "סה״כ ברוטו: ") + Fmt.money(item.rawTotal))
            }

            Section {
                Toggle("כלול בחישוב", isOn: $item.isActive)
            } footer: {
                Text("כבה כדי להשאיר את ההכנסה ברשימה בלי שתיכנס לחישוב (למשל עבודה עונתית).")
            }
        }
    }
}
