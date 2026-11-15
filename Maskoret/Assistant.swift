import Foundation

// MARK: - What the assistant knows about the user

/// One short thing the assistant knows ("מצב משפחתי: זוג עם ילדים"): an answer to one of its questions, something
/// the user wrote, or something the model asked to remember and the user approved.
struct AssistantFact: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var date = Date()
    /// The question this answers (AssistantQuestion.id), when it came from one.
    var questionID: String? = nil
}

/// The assistant's profile of one family member; part of their money data, so it syncs with it.
struct AssistantProfile: Codable, Equatable {
    var facts: [AssistantFact] = []
    /// Questions the user asked not to be asked (AssistantQuestion.id).
    var skipped: [String] = []
    /// When a question was last answered or put off: at most one a day.
    var lastAskedAt: Date? = nil

    init() {}

    private enum CodingKeys: String, CodingKey { case facts, skipped, lastAskedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        facts = (try? c.decodeIfPresent([AssistantFact].self, forKey: .facts)) ?? []
        skipped = (try? c.decodeIfPresent([String].self, forKey: .skipped)) ?? []
        lastAskedAt = try? c.decodeIfPresent(Date.self, forKey: .lastAskedAt)
    }
}

/// A getting-to-know-you question shown at the top of the screens it belongs to.
struct AssistantQuestion: Identifiable, Equatable {
    let id: String
    /// What the fact is called ("מצב משפחתי"); the fact is "label: answer".
    let label: String
    let text: String
    let answers: [String]
    /// The screens it shows on (SidebarItem raw values).
    let screens: [String]

    /// The same list, in the same order, as `AssistantQuestion.all` in flutter_app/lib/data/assistant.dart.
    static let all: [AssistantQuestion] = [
        AssistantQuestion(id: "family", label: "מצב משפחתי", text: "מי בבית?",
                          answers: ["רווק/ה", "זוג בלי ילדים", "זוג עם ילדים", "הורה יחיד"],
                          screens: ["summary", "incomes"]),
        AssistantQuestion(id: "goal", label: "יעד כספי עיקרי", text: "מה היעד הכספי הכי חשוב לך עכשיו?",
                          answers: ["לסגור את החודש בלי מינוס", "לבנות כרית ביטחון", "לחסוך לדירה", "לחסוך למטרה גדולה אחרת", "להשקיע לטווח ארוך"],
                          screens: ["summary", "accounts", "forecast"]),
        AssistantQuestion(id: "housing", label: "מגורים", text: "מה מצב המגורים שלך?",
                          answers: ["שכירות", "דירה בבעלות עם משכנתא", "דירה בבעלות בלי משכנתא", "אצל ההורים"],
                          screens: ["expenses", "summary"]),
        AssistantQuestion(id: "car", label: "רכב", text: "יש רכב בבית?",
                          answers: ["אין רכב", "רכב אחד", "שני רכבים או יותר", "רכב מהעבודה / ליסינג"],
                          screens: ["expenses", "card"]),
        AssistantQuestion(id: "income_stability", label: "יציבות ההכנסה", text: "כמה ההכנסה שלך קבועה מחודש לחודש?",
                          answers: ["קבועה", "משתנה קצת", "משתנה מאוד"],
                          screens: ["incomes", "forecast"]),
        AssistantQuestion(id: "big_change", label: "שינוי גדול צפוי בשנה הקרובה", text: "צפוי שינוי גדול בשנה הקרובה?",
                          answers: ["לא צפוי שינוי", "ילד/ה בדרך", "מעבר דירה", "חתונה או אירוע גדול", "החלפת עבודה", "קניית רכב"],
                          screens: ["forecast", "summary"]),
        AssistantQuestion(id: "hard_spot", label: "המקום שהכי קשה לעמוד בו בתקציב", text: "איפה הכי קשה לך לעמוד בתקציב?",
                          answers: ["אוכל בחוץ ומשלוחים", "סופר", "קניות ובגדים", "בילויים ויציאות", "ילדים", "לא קשה לי במיוחד"],
                          screens: ["trends", "card"]),
        AssistantQuestion(id: "runway", label: "לכמה זמן החיסכון מספיק בלי הכנסה", text: "אם ההכנסה נעצרת מחר — לכמה זמן החיסכון מספיק?",
                          answers: ["פחות מחודש", "1–3 חודשים", "3–6 חודשים", "יותר מחצי שנה"],
                          screens: ["accounts", "forecast"]),
        AssistantQuestion(id: "tone", label: "איך לדבר איתי על חריגות", text: "כשיש חריגה מהתקציב — איך להגיד לך?",
                          answers: ["ישר ולעניין", "בעדינות, עם עידוד", "רק מספרים, בלי הערות"],
                          screens: ["trends", "card", "summary"])
    ]
}

extension AssistantProfile {
    /// The longest a fact can be (what the user writes and what the model asks to remember).
    static let maxFactLength = 200

    private static func normalized(_ s: String) -> String {
        s.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
            .map(String.init).joined().lowercased()
    }

    /// The question to show at the top of a screen now: none when one was already asked today, otherwise the first
    /// one of this screen that wasn't answered or turned off.
    func question(for screen: String, now: Date = Date()) -> AssistantQuestion? {
        if let last = lastAskedAt, Calendar.current.isDate(last, inSameDayAs: now) { return nil }
        let answered = Set(facts.compactMap(\.questionID))
        return AssistantQuestion.all.first {
            $0.screens.contains(screen) && !answered.contains($0.id) && !skipped.contains($0.id)
        }
    }

    /// An answer becomes a fact (replacing an earlier answer to the same question).
    mutating func answer(_ question: AssistantQuestion, with answer: String, now: Date = Date()) {
        facts.removeAll { $0.questionID == question.id }
        facts.append(AssistantFact(text: question.label + ": " + answer, date: now, questionID: question.id))
        lastAskedAt = now
    }

    /// "לא עכשיו": the question comes back another day.
    mutating func postpone(now: Date = Date()) {
        lastAskedAt = now
    }

    /// "אל תשאל שוב".
    mutating func skip(_ question: AssistantQuestion, now: Date = Date()) {
        if !skipped.contains(question.id) { skipped.append(question.id) }
        lastAskedAt = now
    }

    /// Adds a fact in the user's (or the model's) words. False when it's empty or already there.
    @discardableResult
    mutating func remember(_ text: String, now: Date = Date()) -> Bool {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(AssistantProfile.maxFactLength))
        let key = AssistantProfile.normalized(t)
        guard !key.isEmpty, !facts.contains(where: { AssistantProfile.normalized($0.text) == key }) else { return false }
        facts.append(AssistantFact(text: t, date: now))
        return true
    }

    /// Removes a fact. An answer that was deleted isn't asked about again.
    mutating func forget(id: UUID) {
        guard let i = facts.firstIndex(where: { $0.id == id }) else { return }
        if let q = facts[i].questionID, !skipped.contains(q) { skipped.append(q) }
        facts.remove(at: i)
    }

    /// Removes the fact the model named: the same text, or one that contains it / is contained in it. False when none.
    @discardableResult
    mutating func forget(matching text: String) -> Bool {
        let wanted = AssistantProfile.normalized(text)
        guard !wanted.isEmpty else { return false }
        let found = facts.first { AssistantProfile.normalized($0.text) == wanted }
            ?? facts.first { let n = AssistantProfile.normalized($0.text); return n.contains(wanted) || wanted.contains(n) }
        guard let found else { return false }
        forget(id: found.id)
        return true
    }
}

extension Store {
    /// What the assistant knows about each member in view, for the model ("## מה ידוע על המשתמש").
    func assistantContextLines() -> [String] {
        var parts: [(title: String?, facts: [AssistantFact])] = []
        if isCombined {
            for member in viewedMembers {
                let m = member.id == activeMemberID ? money : memberFiles[member.id]?.money
                parts.append((member.title, m?.assistant.facts ?? []))
            }
        } else {
            parts.append((nil, money.assistant.facts))
        }
        var lines: [String] = []
        for part in parts {
            for fact in part.facts {
                lines.append("- " + (part.title.map { $0 + " — " } ?? "") + fact.text)
            }
        }
        return lines
    }
}
