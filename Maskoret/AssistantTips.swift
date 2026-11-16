import Foundation

// MARK: - Tips at the top of the screens (local rules, no AI, no network)

/// One short tip from the local rules. The id is stable ("trend-over:<trend id>:<month>"), so "לא עכשיו" hides
/// exactly this one, and a notification can point at it.
struct AssistantTip: Identifiable, Equatable {
    let id: String
    /// The screen it shows on (SidebarItem raw value).
    let screen: String
    let title: String
    let text: String
    /// 3 = over the budget now, 2 = about to be, 1 = housekeeping.
    let severity: Int
    /// What "למה?" asks the AI chat.
    let question: String
}

/// The rules. A pure function of the data and the month's picture — the same rules, ids and texts as
/// `AssistantTips` in flutter_app/lib/data/assistant_tips.dart.
enum AssistantTips {
    static let staleBalanceDays = 60
    static let maturitySoonDays = 30
    static let nearLimit = 0.8
    static let minUnsorted = 3

    private static func days(from a: Date, to b: Date) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: a), to: cal.startOfDay(for: b)).day ?? 0
    }

    private static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Every tip that applies now, the most important first.
    static func all(money: MoneyData, picture p: MonthPicture, now: Date = Date()) -> [AssistantTip] {
        func m(_ v: Double) -> String { Fmt.money(v) }
        let cal = Calendar.current
        var tips: [AssistantTip] = []
        let monthKey = cal.component(.year, from: now) * 100 + cal.component(.month, from: now)
        let periodKey = p.year * 100 + p.month
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let daysLeftInMonth = daysInMonth - cal.component(.day, from: now)

        // Trends against their monthly limit.
        for t in money.trends where t.monthlyLimit > 0 {
            let spent = money.stats(of: t, now: now).thisMonth
            if spent > t.monthlyLimit + 0.005 {
                tips.append(AssistantTip(
                    id: "trend-over:\(t.id.uuidString):\(monthKey)", screen: "trends",
                    title: "חריגה במגמה ״\(t.name)״",
                    text: "יצאו \(m(spent)) מתוך תקרה של \(m(t.monthlyLimit)) — \(m(spent - t.monthlyLimit)) מעל התקרה החודש.",
                    severity: 3,
                    question: "חרגתי החודש מהתקרה במגמה ״\(t.name)״: \(m(spent)) מתוך \(m(t.monthlyLimit)). מה גרם לחריגה, ואיך אני חוזר לתקציב?"))
            } else if spent >= t.monthlyLimit * nearLimit, daysLeftInMonth >= 1 {
                let left = max(0, t.monthlyLimit - spent)
                tips.append(AssistantTip(
                    id: "trend-near:\(t.id.uuidString):\(monthKey)", screen: "trends",
                    title: "״\(t.name)״ קרובה לתקרה",
                    text: "נשארו \(m(left)) עד התקרה, ועוד \(daysLeftInMonth) ימים עד סוף החודש.",
                    severity: 2,
                    question: "במגמה ״\(t.name)״ נשארו לי \(m(left)) עד התקרה ועוד \(daysLeftInMonth) ימים עד סוף החודש. איך אני נשאר בתקציב?"))
            }
        }

        // What's left of the month.
        if p.net > 0 {
            if p.remainingActual < -0.005 {
                tips.append(AssistantTip(
                    id: "left-negative:\(periodKey)", screen: "summary",
                    title: "החודש כבר במינוס",
                    text: "מאז ההכנסה האחרונה יצאו \(m(-p.remainingActual)) יותר ממה שנכנס.",
                    severity: 3,
                    question: "מאז ההכנסה האחרונה יצאו \(m(-p.remainingActual)) יותר ממה שנכנס. מה גרם לזה, ואיך אני מצמצם עד המשכורת הבאה?"))
            } else if p.remaining < -0.005 {
                tips.append(AssistantTip(
                    id: "left-expected-negative:\(periodKey)", screen: "summary",
                    title: "צפוי מינוס בסוף החודש",
                    text: "בקצב הנוכחי יחסרו \(m(-p.remaining)) אחרי חיוב האשראי.",
                    severity: 2,
                    question: "לפי הצפי יחסרו לי \(m(-p.remaining)) בסוף החודש אחרי חיוב האשראי. על מה אפשר לוותר או מה לדחות כדי לסגור את החודש בלי מינוס?"))
            }
        }

        // A card purchase priced like a fixed expense, not linked to it: it may be counted twice.
        if !p.fixedInCardSuspects.isEmpty {
            let names = p.fixedInCardSuspects.prefix(3).joined(separator: ", ")
            tips.append(AssistantTip(
                id: "card-duplicate:\(periodKey)", screen: "card",
                title: "ייתכן שהוצאה נספרת פעמיים",
                text: "\(names) — הסכום זהה להוצאה קבועה. אם זו אותה הוצאה, צמד את החיוב אליה.",
                severity: 2,
                question: "יש חיובי אשראי שנראים כמו הוצאות קבועות שלי (\(names)). אילו מהם נספרים פעמיים, ומה כדאי לצמד?"))
        }

        // A deposit that ends soon.
        for a in money.accounts where a.kind == .deposit {
            guard let end = a.maturityDate else { continue }
            let left = days(from: now, to: end)
            guard left >= 0, left <= maturitySoonDays else { continue }
            tips.append(AssistantTip(
                id: "deposit-ends:\(a.id.uuidString):\(dayKey(end))", screen: "accounts",
                title: left == 0 ? "״\(a.name)״ מסתיים היום" : "״\(a.name)״ מסתיים בעוד \(left) ימים",
                text: "כדאי להחליט מראש לאן הכסף ממשיך — חידוש, חיסכון אחר או העו״ש.",
                severity: 2,
                question: "הפיקדון ״\(a.name)״ מסתיים בקרוב. מה כדאי לעשות עם הכסף לפי המצב שלי והיעדים שלי?"))
        }

        // The actual net wasn't recorded for a period whose salary already came in.
        if !p.isActual, p.estimatedNet > 0, let start = p.periodStart, days(from: start, to: now) >= 3 {
            tips.append(AssistantTip(
                id: "no-actual-net:\(periodKey)", screen: "summary",
                title: "עוד לא נרשם הנטו בפועל",
                text: "החישוב של החודש נשען על הערכה. רישום הנטו מהתלוש ידייק את מה שנשאר.",
                severity: 1,
                question: "עוד לא רשמתי את הנטו בפועל של החודש. כמה ההערכה יכולה להיות רחוקה מהמציאות, ועל מה זה משפיע?"))
        }

        // Savings whose balance wasn't updated for a long time.
        for a in money.accounts where a.kind == .savings || a.kind == .deposit {
            guard let last = a.balances.map(\.date).max() else { continue }
            let age = days(from: last, to: now)
            guard age > staleBalanceDays else { continue }
            tips.append(AssistantTip(
                id: "balance-stale:\(a.id.uuidString):\(dayKey(last))", screen: "accounts",
                title: "היתרה של ״\(a.name)״ לא עודכנה \(age) ימים",
                text: "עדכון היתרה מהבנק ידייק את החיסכון ואת התחזית.",
                severity: 1,
                question: "היתרה של ״\(a.name)״ לא עודכנה \(age) ימים. כמה זה משפיע על התחזית שלי?"))
        }

        // Card charges of this period with no category and in no trend.
        if let start = p.periodStart, let end = p.periodEnd {
            let inTrends = Set(money.trends.flatMap(\.cardIDs))
            let unsorted = money.cardTransactions.filter {
                $0.isVariable && $0.myAmount != 0 && $0.category.trimmingCharacters(in: .whitespaces).isEmpty
                    && !inTrends.contains($0.id) && $0.date >= start && $0.date < end
            }
            if unsorted.count >= minUnsorted {
                let total = unsorted.reduce(0) { $0 + $1.myAmount }
                tips.append(AssistantTip(
                    id: "card-unsorted:\(periodKey)", screen: "card",
                    title: "\(unsorted.count) עסקאות בלי קטגוריה ובלי מגמה",
                    text: "\(m(total)) החודש שלא ברור לאן הלכו. שיוך למגמה מראה איפה הכסף יוצא.",
                    severity: 1,
                    question: "יש לי \(unsorted.count) עסקאות אשראי החודש (\(m(total))) בלי קטגוריה ובלי מגמה. לאילו מגמות כדאי לשייך אותן?"))
            }
        }

        // Trends, but none of them has a limit.
        if !money.trends.isEmpty, money.trends.allSatisfy({ $0.monthlyLimit <= 0 }) {
            tips.append(AssistantTip(
                id: "trends-no-limits", screen: "trends",
                title: "לאף מגמה אין תקרה",
                text: "תקרה חודשית מראה מתי מתקרבים לגבול. אפשר להתחיל ממגמה אחת.",
                severity: 1,
                question: "לאף אחת מהמגמות שלי אין תקרה חודשית. לפי ההוצאות שלי בחודשים האחרונים, אילו תקרות כדאי לקבוע?"))
        }

        return tips.enumerated().sorted { a, b in
            a.element.severity != b.element.severity ? a.element.severity > b.element.severity : a.offset < b.offset
        }.map(\.element)
    }

    /// The tips the user didn't put off.
    static func visible(money: MoneyData, picture: MonthPicture, dismissed: [String], now: Date = Date()) -> [AssistantTip] {
        all(money: money, picture: picture, now: now).filter { !dismissed.contains($0.id) }
    }

    /// The one tip a screen shows.
    static func tip(for screen: String, money: MoneyData, picture: MonthPicture, dismissed: [String], now: Date = Date()) -> AssistantTip? {
        visible(money: money, picture: picture, dismissed: dismissed, now: now).first { $0.screen == screen }
    }

    /// The most important tip right now (for a notification).
    static func top(money: MoneyData, picture: MonthPicture, dismissed: [String], now: Date = Date()) -> AssistantTip? {
        visible(money: money, picture: picture, dismissed: dismissed, now: now).first
    }
}
