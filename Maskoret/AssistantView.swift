import SwiftUI

// MARK: - The question at the top of a screen

/// One getting-to-know-you question, at the top of the screens it belongs to (inside PageBar). At most one a day;
/// the answer becomes something the assistant knows about the member being edited.
struct AssistantQuestionCard: View {
    let screen: SidebarItem
    @EnvironmentObject private var store: Store
    @State private var showFacts = false

    var body: some View {
        if let question = store.money.assistant.question(for: screen.rawValue) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(question.text)
                            .font(.callout.weight(.semibold))
                        Text("כדי שההמלצות יתאימו לך")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(question.answers, id: \.self) { answer in
                            Button(answer) {
                                withAnimation { store.money.assistant.answer(question, with: answer) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                HStack(spacing: 14) {
                    Button("לא עכשיו") {
                        withAnimation { store.money.assistant.postpone() }
                    }
                    Button("אל תשאל שוב") {
                        withAnimation { store.money.assistant.skip(question) }
                    }
                    Spacer(minLength: 0)
                    Button("מה העוזר יודע עליי") { showFacts = true }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .padding(10)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .sheet(isPresented: $showFacts) {
                AssistantFactsView()
                    .environmentObject(store)
            }
        }
    }
}

// MARK: - The tip at the top of a screen

/// One tip from the local rules (AssistantTips), under the question card. "למה?" asks the AI chat about it;
/// "לא עכשיו" hides this tip for good (synced with the member's data).
struct AssistantTipRow: View {
    let screen: SidebarItem
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ai: InsightsEngine

    private var color: Color { tip?.severity == 3 ? .red : (tip?.severity == 2 ? .orange : .accentColor) }
    private var tip: AssistantTip? { store.assistantTips.first { $0.screen == screen.rawValue } }

    var body: some View {
        if let tip {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: tip.severity >= 2 ? "exclamationmark.circle.fill" : "lightbulb.fill")
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tip.title)
                        .font(.callout.weight(.semibold))
                    Text(tip.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 14) {
                        Button("למה?") {
                            ai.pendingQuestion = tip.question
                            store.openScreen = .insights
                        }
                        .foregroundStyle(.tint)
                        Button("לא עכשיו") {
                            withAnimation { store.money.assistant.dismissTip(tip.id) }
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - "מה העוזר יודע עליי"

/// Everything the assistant knows about the member being edited: delete what's wrong, add in your own words.
struct AssistantFactsView: View {
    @EnvironmentObject private var store: Store
    @State private var newFact = ""

    private var facts: [AssistantFact] { store.money.assistant.facts }

    private func add() {
        if store.money.assistant.remember(newFact) { newFact = "" }
    }

    var body: some View {
        SheetContainer(title: "מה העוזר יודע עליי", minHeight: 420, onSave: nil) {
            Section {
                if facts.isEmpty {
                    Text("עדיין כלום. אפשר לענות על השאלות שבראש המסכים, או לכתוב כאן.")
                        .foregroundStyle(.secondary)
                }
                ForEach(facts) { fact in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(fact.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(role: .destructive) {
                            withAnimation { store.money.assistant.forget(id: fact.id) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("מחיקה")
                        .accessibilityLabel("מחיקה")
                    }
                }
            } header: {
                if store.hasFamily, let me = store.activeMember { Text(me.title) }
            } footer: {
                Text("העוזר משתמש בזה כדי להתאים את התשובות וההמלצות. זה נשמר עם הנתונים שלך ומסתנכרן בין המכשירים.")
            }
            Section("להוסיף משהו") {
                HStack(spacing: 8) {
                    TextField("למשל: חוסכים לחתונה בקיץ", text: $newFact)
                        .onSubmit(add)
                    Button("הוספה", action: add)
                        .disabled(newFact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
