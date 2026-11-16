import 'card.dart';
import 'fmt.dart';
import 'json.dart';
import 'models.dart';
import 'month_picture.dart';
import 'trends.dart';

/// One short tip from the local rules (AssistantTip in AssistantTips.swift). The id is stable
/// ("trend-over:<trend id>:<month>"), so "לא עכשיו" hides exactly this one, and a notification can point at it.
class AssistantTip {
  const AssistantTip(this.id, this.screen, this.title, this.text, this.severity, this.question);
  final String id;

  /// The screen it shows on (Dest name).
  final String screen;
  final String title;
  final String text;

  /// 3 = over the budget now, 2 = about to be, 1 = housekeeping.
  final int severity;

  /// What "למה?" asks the AI chat.
  final String question;
}

/// The rules — no AI, no network. A pure function of the data and the month's picture; the same rules, ids and
/// texts as `AssistantTips` in AssistantTips.swift.
class AssistantTips {
  static const staleBalanceDays = 60;
  static const maturitySoonDays = 30;
  static const nearLimit = 0.8;
  static const minUnsorted = 3;

  static int _days(DateTime a, DateTime b) =>
      DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

  static String _dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  /// Every tip that applies now, the most important first.
  static List<AssistantTip> all(MoneyData money, MonthPicture p, {DateTime? now}) {
    final at = now ?? DateTime.now();
    String m(double v) => Fmt.money(v);
    final tips = <AssistantTip>[];
    final monthKey = at.year * 100 + at.month;
    final periodKey = p.year * 100 + p.month;
    final daysLeftInMonth = DateTime(at.year, at.month + 1, 0).day - at.day;
    final trends = JObj(money.raw).objects('trends').map(Trend.new).toList();

    // Trends against their monthly limit.
    for (final t in trends.where((t) => t.monthlyLimit > 0)) {
      final spent = TrendCalc.stats(money, t, now: at).thisMonth;
      if (spent > t.monthlyLimit + 0.005) {
        tips.add(AssistantTip(
            'trend-over:${t.id}:$monthKey',
            'trends',
            'חריגה במגמה ״${t.name}״',
            'יצאו ${m(spent)} מתוך תקרה של ${m(t.monthlyLimit)} — ${m(spent - t.monthlyLimit)} מעל התקרה החודש.',
            3,
            'חרגתי החודש מהתקרה במגמה ״${t.name}״: ${m(spent)} מתוך ${m(t.monthlyLimit)}. מה גרם לחריגה, ואיך אני חוזר לתקציב?'));
      } else if (spent >= t.monthlyLimit * nearLimit && daysLeftInMonth >= 1) {
        final left = t.monthlyLimit - spent < 0 ? 0.0 : t.monthlyLimit - spent;
        tips.add(AssistantTip(
            'trend-near:${t.id}:$monthKey',
            'trends',
            '״${t.name}״ קרובה לתקרה',
            'נשארו ${m(left)} עד התקרה, ועוד $daysLeftInMonth ימים עד סוף החודש.',
            2,
            'במגמה ״${t.name}״ נשארו לי ${m(left)} עד התקרה ועוד $daysLeftInMonth ימים עד סוף החודש. איך אני נשאר בתקציב?'));
      }
    }

    // What's left of the month.
    if (p.net > 0) {
      if (p.remainingActual < -0.005) {
        tips.add(AssistantTip(
            'left-negative:$periodKey',
            'summary',
            'החודש כבר במינוס',
            'מאז ההכנסה האחרונה יצאו ${m(-p.remainingActual)} יותר ממה שנכנס.',
            3,
            'מאז ההכנסה האחרונה יצאו ${m(-p.remainingActual)} יותר ממה שנכנס. מה גרם לזה, ואיך אני מצמצם עד המשכורת הבאה?'));
      } else if (p.remaining < -0.005) {
        tips.add(AssistantTip(
            'left-expected-negative:$periodKey',
            'summary',
            'צפוי מינוס בסוף החודש',
            'בקצב הנוכחי יחסרו ${m(-p.remaining)} אחרי חיוב האשראי.',
            2,
            'לפי הצפי יחסרו לי ${m(-p.remaining)} בסוף החודש אחרי חיוב האשראי. על מה אפשר לוותר או מה לדחות כדי לסגור את החודש בלי מינוס?'));
      }
    }

    // A card purchase priced like a fixed expense, not linked to it: it may be counted twice.
    if (p.fixedInCardSuspects.isNotEmpty) {
      final names = p.fixedInCardSuspects.take(3).join(', ');
      tips.add(AssistantTip(
          'card-duplicate:$periodKey',
          'card',
          'ייתכן שהוצאה נספרת פעמיים',
          '$names — הסכום זהה להוצאה קבועה. אם זו אותה הוצאה, צמד את החיוב אליה.',
          2,
          'יש חיובי אשראי שנראים כמו הוצאות קבועות שלי ($names). אילו מהם נספרים פעמיים, ומה כדאי לצמד?'));
    }

    // A deposit that ends soon.
    for (final a in money.accounts.where((a) => a.kind == AccountKind.deposit)) {
      final end = a.maturityDate;
      if (end == null) continue;
      final left = _days(at, end);
      if (left < 0 || left > maturitySoonDays) continue;
      tips.add(AssistantTip(
          'deposit-ends:${a.id}:${_dayKey(end)}',
          'accounts',
          left == 0 ? '״${a.name}״ מסתיים היום' : '״${a.name}״ מסתיים בעוד $left ימים',
          'כדאי להחליט מראש לאן הכסף ממשיך — חידוש, חיסכון אחר או העו״ש.',
          2,
          'הפיקדון ״${a.name}״ מסתיים בקרוב. מה כדאי לעשות עם הכסף לפי המצב שלי והיעדים שלי?'));
    }

    // The actual net wasn't recorded for a period whose salary already came in.
    if (!p.isActual && p.estimatedNet > 0 && p.periodStart != null && _days(p.periodStart!, at) >= 3) {
      tips.add(AssistantTip(
          'no-actual-net:$periodKey',
          'summary',
          'עוד לא נרשם הנטו בפועל',
          'החישוב של החודש נשען על הערכה. רישום הנטו מהתלוש ידייק את מה שנשאר.',
          1,
          'עוד לא רשמתי את הנטו בפועל של החודש. כמה ההערכה יכולה להיות רחוקה מהמציאות, ועל מה זה משפיע?'));
    }

    // Savings whose balance wasn't updated for a long time.
    for (final a in money.accounts.where((a) => a.kind == AccountKind.savings || a.kind == AccountKind.deposit)) {
      final dates = a.balances.map((b) => b.date).toList();
      if (dates.isEmpty) continue;
      final last = dates.reduce((x, y) => x.isAfter(y) ? x : y);
      final age = _days(last, at);
      if (age <= staleBalanceDays) continue;
      tips.add(AssistantTip(
          'balance-stale:${a.id}:${_dayKey(last)}',
          'accounts',
          'היתרה של ״${a.name}״ לא עודכנה $age ימים',
          'עדכון היתרה מהבנק ידייק את החיסכון ואת התחזית.',
          1,
          'היתרה של ״${a.name}״ לא עודכנה $age ימים. כמה זה משפיע על התחזית שלי?'));
    }

    // Card charges of this period with no category and in no trend.
    final start = p.periodStart, end = p.periodEnd;
    if (start != null && end != null) {
      final inTrends = {for (final t in trends) ...t.cardIDs};
      final unsorted = CardData(money).cardTransactions.where((t) =>
          t.isVariable && t.myAmount != 0 && t.category.trim().isEmpty && !inTrends.contains(t.id) &&
          !t.date.isBefore(start) && t.date.isBefore(end)).toList();
      if (unsorted.length >= minUnsorted) {
        final total = unsorted.fold(0.0, (s, t) => s + t.myAmount);
        tips.add(AssistantTip(
            'card-unsorted:$periodKey',
            'card',
            '${unsorted.length} עסקאות בלי קטגוריה ובלי מגמה',
            '${m(total)} החודש שלא ברור לאן הלכו. שיוך למגמה מראה איפה הכסף יוצא.',
            1,
            'יש לי ${unsorted.length} עסקאות אשראי החודש (${m(total)}) בלי קטגוריה ובלי מגמה. לאילו מגמות כדאי לשייך אותן?'));
      }
    }

    // Trends, but none of them has a limit.
    if (trends.isNotEmpty && trends.every((t) => t.monthlyLimit <= 0)) {
      tips.add(const AssistantTip(
          'trends-no-limits',
          'trends',
          'לאף מגמה אין תקרה',
          'תקרה חודשית מראה מתי מתקרבים לגבול. אפשר להתחיל ממגמה אחת.',
          1,
          'לאף אחת מהמגמות שלי אין תקרה חודשית. לפי ההוצאות שלי בחודשים האחרונים, אילו תקרות כדאי לקבוע?'));
    }

    // The most important first; rules of the same severity keep their order.
    final indexed = [for (var i = 0; i < tips.length; i++) (i, tips[i])];
    indexed.sort((a, b) => a.$2.severity != b.$2.severity ? b.$2.severity - a.$2.severity : a.$1 - b.$1);
    return [for (final e in indexed) e.$2];
  }

  /// The tips the user didn't put off.
  static List<AssistantTip> visible(MoneyData money, MonthPicture picture, List<String> dismissed, {DateTime? now}) =>
      all(money, picture, now: now).where((t) => !dismissed.contains(t.id)).toList();

  /// The one tip a screen shows.
  static AssistantTip? tipFor(String screen, MoneyData money, MonthPicture picture, List<String> dismissed, {DateTime? now}) =>
      visible(money, picture, dismissed, now: now).where((t) => t.screen == screen).firstOrNull;

  /// The most important tip right now (for a notification).
  static AssistantTip? top(MoneyData money, MonthPicture picture, List<String> dismissed, {DateTime? now}) =>
      visible(money, picture, dismissed, now: now).firstOrNull;
}
