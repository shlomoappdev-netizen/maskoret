import SwiftUI

/// The new charges of an import that aren't in a trend yet (MoneyData.trendSuggestions).
struct TrendSortSession: Identifiable {
    let id = UUID()
    var items: [TrendSuggestionItem]
}

/// After a card statement was imported: the new charges that aren't in a trend, merchant by merchant, each with the
/// trend the app suggests. "אישור" assigns, the picker chooses another trend, "דילוג" leaves the merchant as it is,
/// and "תמיד לבית העסק הזה" does the same by itself on the next statements.
struct TrendSortSheet: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ai: InsightsEngine
    @Environment(\.dismiss) private var dismiss
    @State var items: [TrendSuggestionItem]
    @State private var index = 0
    @State private var trendID: UUID?
    @State private var always = false
    @State private var asking = false

    private var item: TrendSuggestionItem { items[min(index, items.count - 1)] }
    private var selected: UUID? { store.money.trends.contains { $0.id == trendID } ? trendID : nil }

    private func next() {
        guard index + 1 < items.count else { dismiss(); return }
        index += 1
        trendID = item.trendID
        always = false
    }

    private func confirm() {
        guard let selected else { return }
        store.money.assign(item, to: selected, always: always)
        next()
    }

    /// One request to the cloud model (when it's set up) for the merchants the app couldn't place by itself.
    private func askModel() async {
        guard ai.canAskCloud, items.contains(where: { $0.trendID == nil }) else { return }
        asking = true
        let answer = await ai.complete(system: TrendSuggestions.aiSystem, prompt: store.money.trendAIPrompt(items))
        asking = false
        guard let answer else { return }
        store.money.applyTrendAIAnswer(answer, to: &items)
        if trendID == nil { trendID = item.trendID }
    }

    var body: some View {
        SheetContainer(title: "לשייך למגמה? (\(index + 1) מתוך \(items.count))", minHeight: 360, onSave: nil) {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.merchant)
                        .font(.headline)
                    Text((item.cardIDs.count == 1 ? "עסקה אחת" : "\(item.cardIDs.count) עסקאות") + " · " + Fmt.money(item.total)
                         + (item.category.isEmpty ? "" : " · " + item.category))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("מגמה", selection: $trendID) {
                    Text("בחר מגמה").tag(UUID?.none)
                    ForEach(store.money.trends) { trend in
                        Text(verbatim: trend.emoji + " " + trend.name).tag(UUID?.some(trend.id))
                    }
                }
                Toggle("תמיד לבית העסק הזה", isOn: $always)
            } footer: {
                if let suggested = item.trendID, suggested == selected, !item.reasonText.isEmpty {
                    Text(item.reasonText)
                } else if asking, item.trendID == nil {
                    Text("מבקש הצעה מה-AI…")
                }
            }
            Section {
                HStack {
                    Button("דילוג", action: next)
                    Spacer()
                    Button("אישור", action: confirm)
                        .buttonStyle(.borderedProminent)
                        .disabled(selected == nil)
                }
            }
        }
        .onAppear { trendID = item.trendID }
        .task { await askModel() }
    }
}
