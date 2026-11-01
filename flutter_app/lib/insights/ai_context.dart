import '../data/card.dart';
import '../data/fmt.dart';
import '../data/forecast.dart';
import '../data/json.dart';
import '../data/maaser.dart';
import '../data/models.dart';
import '../data/money_calc.dart';
import '../data/month_picture.dart';
import '../data/receivables.dart';
import '../data/trends.dart';
import '../state/store.dart';

String _rate(Account a, double prime, DateTime now) {
  String describe(double minus) => 'P−${Fmt.percent(minus)} = ${Fmt.percent(((prime - minus) * 100).round() / 100)}';
  if (!a.isPrimeLinked) return Fmt.percent(a.annualRate);
  if (a.rateTiers.isEmpty) return '${describe(a.primeMinus)} (פריים ${Fmt.percent(prime)})';
  return '${describe(MoneyCalc.primeMinusFor(a, MoneyCalc.exitMonthsCovering(a, now)))} עכשיו';
}

/// A compact text summary of the whole app, for the model — port of `Store.aiContext` (Insights.swift).
String aiContext(AppStore store, {DateTime? at}) {
  final now = at ?? DateTime.now();
  String m(double v) => Fmt.money(v);
  // One member, or the family members in view merged together.
  final d = store.dashboard;
  final budget = d.budget, money = d.money, history = d.history;
  final cards = CardData(money);
  final transactions = money.transactions;
  final lines = <String>['תאריך היום: ${Fmt.date(now)}'];
  if (store.isCombined) {
    lines.add('תצוגה משפחתית משותפת של: ${store.viewedMembers.map((x) => x.title).join(', ')}. כל אחד מחושב בנפרד (מס לפי התלוש שלו) '
        'ואז הכל מצורף יחד. שם של פריט מתחיל באימוג׳י של בן המשפחה שלו.');
  } else if (store.members.length > 1 && store.activeMember != null) {
    lines.add('הנתונים של: ${store.activeMember!.title} (בן משפחה אחד מתוך ${store.members.length})');
  }

  // This month
  final p = MonthPicture.current(d);
  final monthStart = p.periodStart!, monthEnd = p.periodEnd!;
  lines.add('\n## החודש (${p.title})');
  lines.add('נטו: ${m(p.net)}${p.isActual ? ' (בפועל)' : ' (הערכה)'}');
  lines.add('נשאר מההכנסה האחרונה (לפי האפליקציה): ${m(p.remaining)} · ימים עד המשכורת הבאה: ${p.daysLeft}');
  for (final l in p.spending) {
    lines.add('- הוצאה קבועה: ${l.title} ${m(l.amount)}');
  }
  if (p.periodic > 0) lines.add('- רכישות תקופתיות (ממוצע): ${m(p.periodic)}');
  for (final l in p.toSavings) {
    lines.add('- לחיסכון: ${l.title} ${m(l.amount)}');
  }
  for (final l in p.card) {
    lines.add('- אשראי משתנות: ${l.title} ${m(l.amount)}${p.cardEstimated ? ' (הערכה)' : ''}');
  }
  for (final l in p.installments) {
    lines.add('- תשלום שיורד החודש: ${l.title} ${m(l.amount)} · ${l.detail}');
  }
  // Bought this month in installments, first charge next month or later.
  final key = p.year * 100 + p.month;
  final later = cards.cardTransactions.where((t) {
    final inst = t.installment;
    return t.isVariable && inst != null && inst.number == 1 && !t.date.isBefore(monthStart) && t.date.isBefore(monthEnd) && (t.billingKey ?? 0) > key;
  }).toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  for (final t in later) {
    final of = t.installment!.of;
    lines.add('- נקנה החודש בתשלומים (לא יורד החודש): ${t.merchant} ${m(t.originalAmount != 0 ? t.originalAmount : t.amount * of)} ב-$of תשלומים');
  }
  for (final x in cards.manualCardPayments) {
    final bought = x.transaction.date;
    if (x.number == 1 && x.billingKey > key && !bought.isBefore(monthStart) && bought.isBefore(monthEnd)) {
      lines.add('- נקנה החודש בתשלומים (לא יורד החודש): ${x.transaction.title} ${m(x.transaction.amount)} ב-${x.of} תשלומים');
    }
  }
  if (p.installmentsAfterThisMonth > 0) lines.add('סה״כ תשלומים שעוד ירדו בחודשים הבאים: ${m(p.installmentsAfterThisMonth)}');
  for (final l in p.oneOffs) {
    lines.add('- תנועה חריגה: ${l.title} ${m(l.amount)}');
  }

  // Payslip
  lines.add('\n## תלוש');
  for (final i in budget.incomes.where((i) => i.isActive)) {
    lines.add('- הכנסה: ${i.name} ${m(i.monthlyTotal)}${i.isNet ? ' (נטו)' : ' (ברוטו)'}');
  }
  lines.add('ברוטו: ${m(budget.gross)} · ניכויים: ${m(budget.totalDeductions)} · נטו משוער: ${m(budget.net)}');
  final actuals = history.where((r) => r.actualNet != null).toList()..sort((a, b) => b.sortKey.compareTo(a.sortKey));
  if (actuals.isNotEmpty) {
    lines.add('נטו בפועל בחודשים קודמים: ${actuals.take(6).map((r) => '${r.month}/${r.year % 100}: ${m(r.actualNet!)}').join(', ')}');
  }

  // Accounts
  lines.add('\n## חשבונות');
  for (final a in money.accounts) {
    var s = '- ${a.name} (${a.kind.title}): ${m(money.balance(a, now))}';
    if (a.kind.hasInterest) s += ' · ריבית: ${_rate(a, money.primeRate, now)}';
    if (a.monthlyContribution > 0) s += ' · הפקדה חודשית ${m(a.monthlyContribution)}';
    if (a.maturityDate != null) s += ' · סיום ${Fmt.date(a.maturityDate!)}';
    lines.add(s);
  }

  // Card by billing month
  final keys = cards.cardBillingKeys.take(6).toList();
  if (keys.isNotEmpty) {
    lines.add('\n## כרטיס אשראי (לפי חודש חיוב)');
    for (final k in keys) {
      final txs = cards.chargedIn(k);
      final s = CardMonthSummary.of(txs);
      lines.add('### ${Fmt.monthTitle(k ~/ 100, k % 100)}: סה״כ ${m(s.total)} · מצומד להוצאות קבועות ${m(s.fixedLinked)} · משתנות ${m(s.variable)}'
          '${s.pending != 0 ? ' · מתוכן ממתין ${m(s.pending)}' : ''}');
      if (s.byCategory.isNotEmpty) {
        lines.add('קטגוריות: ${s.byCategory.take(8).map((c) => '${c.name} ${m(c.amount)}').join(', ')}');
      }
      final merchants = <String, (double, int)>{};
      for (final t in txs.where((t) => t.isVariable)) {
        final x = merchants[t.merchant] ?? (0.0, 0);
        merchants[t.merchant] = (x.$1 + t.amount, x.$2 + 1);
      }
      final top = merchants.entries.toList()..sort((a, b) => b.value.$1.compareTo(a.value.$1));
      if (top.isNotEmpty) {
        lines.add('בתי עסק מובילים: ${top.take(6).map((e) => '${e.key} ${m(e.value.$1)} (${e.value.$2} עסקאות)').join(', ')}');
      }
    }
    final avg = cards.averageCardVariable();
    if (avg > 0) lines.add('ממוצע משתנות לחודש (בלי תשלומים): ${m(avg)}');
  }

  // Installments
  final plans = cards.installmentPlans.where((x) => x.isActive).toList();
  if (plans.isNotEmpty) {
    lines.add('\n## תשלומים פעילים');
    for (final plan in plans) {
      lines.add('- ${plan.merchant}: ${m(plan.total)} ב-${plan.count} תשלומים · '
          '${plan.payments.map((x) => '${x.number}/${plan.count} ${Fmt.date(x.chargeDate)} ${m(x.amount)}').join(', ')}');
    }
  }

  // Trends
  final trends = JObj(money.raw).objects('trends').map(Trend.new).toList();
  if (trends.isNotEmpty) {
    lines.add('\n## מגמות (קבוצות הוצאה שהמשתמש הגדיר)');
    for (final t in trends) {
      final s = TrendCalc.stats(money, t, now: now);
      lines.add('- ${t.emoji} ${t.name}: החודש ${m(s.thisMonth)} · חודש שעבר ${m(s.lastMonth)} · ממוצע ${m(s.monthlyAverage)} · סה״כ ${m(s.total)}'
          '${t.monthlyLimit > 0 ? ' · תקרה ${m(t.monthlyLimit)}' : ''}');
    }
  }

  // Owed to me
  final debtors = cards.debtors(transactions).where((x) => x.amount > 0.005).toList();
  if (debtors.isNotEmpty) {
    lines.add('\n## חייבים לי (שילמתי בשביל אחרים — לא הוצאה שלי)');
    for (final x in debtors) {
      lines.add('- ${x.person}: ${m(x.amount)}');
    }
  }

  // Maaser
  final funds = [
    for (final member in store.viewedMembers)
      if (store.family.file(member.id) case final f? when MaaserSettings(JObj((f.money.raw['maaser'] as Json?) ?? {})).enabled)
        (member, MaaserCalc.status(f, now: now))
  ];
  if (funds.isNotEmpty) {
    lines.add('\n## מעשרות');
    for (final (member, s) in funds) {
      lines.add('- ${member.title}: ${s.balance >= 0 ? 'חוב ' : 'זכות '}${m(s.balance.abs())} · ניתן החודש ${m(s.thisMonthPaid)} · ניתן השנה ${m(s.paidThisYear)}');
    }
  }

  // Tracked purchases
  if (budget.trackedItems.isNotEmpty) {
    lines.add('\n## מעקב רכישות');
    for (final t in budget.trackedItems) {
      var s = '- ${t.name}: ${t.purchases.length} רכישות';
      final last = t.lastPurchase;
      if (last != null) s += ' · אחרונה ${Fmt.date(last.date)} ב-${m(last.price)}';
      if (t.monthlyCost > 0) s += ' · עלות חודשית ממוצעת ${m(t.monthlyCost)}';
      lines.add(s);
    }
  }

  // Forecast
  final f = Forecaster.run(d, months: ForecastSettings.of(store.file).months, now: now);
  if (f.length > 1) {
    lines.add('\n## תחזית');
    for (final month in f.skip(1)) {
      lines.add('- ${month.label}: עו״ש ${m(month.checking)} · חיסכון ${m(month.savings)}${month.events.isEmpty ? '' : ' · ${month.events.join('; ')}'}');
    }
  }
  return lines.join('\n');
}

/// New data since the last automatic insight (or a week passed).
bool insightsDue(MoneyData money, DateTime? lastAuto) {
  if (lastAuto == null) return true;
  if (DateTime.now().difference(lastAuto) > const Duration(days: 7)) return true;
  final imported = JObj(money.raw).objects('cardImports').firstOrNull;
  final at = imported == null ? null : JObj(imported).date('importedAt');
  return at != null && at.isAfter(lastAuto);
}
