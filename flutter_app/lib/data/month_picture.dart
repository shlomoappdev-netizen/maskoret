import 'package:intl/intl.dart';

import 'card.dart';
import 'fmt.dart';
import 'models.dart';
import 'money_calc.dart';

class MonthLine {
  MonthLine(this.title, this.amount);
  final String title;
  final double amount;
}

/// One payment of a purchase split into installments — only this payment comes off this month.
class InstallmentLine {
  InstallmentLine({
    required this.merchant,
    required this.number,
    required this.of,
    required this.amount,
    required this.total,
    required this.leftAfter,
    required this.expected,
  });
  final String merchant;
  final int number;
  final int of;
  final double amount;
  final double total;
  final double leftAfter;
  final bool expected;

  int get paymentsLeft => of - number > 0 ? of - number : 0;
  String get title => '$merchant — תשלום $number/$of מתוך ${Fmt.money(total)}${expected ? ' (צפוי)' : ''}';
  String get detail => paymentsLeft == 0 ? 'תשלום אחרון' : 'נשארו עוד $paymentsLeft תשלומים · ${Fmt.money(leftAfter)}';
}

/// One consistent picture of a money period (pay day to pay day): actual net (if recorded) or the estimate, fixed
/// expenses, periodic purchases, money moved into savings, credit-card purchases and one-offs. "נשאר מההכנסה האחרונה"
/// is `remaining` — the same number as in the iPhone/Mac app. Port of `MonthPicture` / `Store.monthPicture` (Sync.swift).
class MonthPicture {
  MonthPicture({
    required this.year,
    required this.month,
    required this.estimatedNet,
    required this.actualNet,
    required this.spending,
    required this.periodic,
    required this.toSavings,
    required this.oneOffs,
    required this.card,
    required this.cardEstimated,
    this.cardEstimate = 0,
    this.fixedInCardSuspects = const [],
    this.periodStart,
    this.periodEnd,
    required this.installments,
    required this.installmentsAfterThisMonth,
  });

  final int year;
  final int month;
  final double estimatedNet;
  final double? actualNet;
  final List<MonthLine> spending;
  final double periodic;
  final List<MonthLine> toSavings;
  final List<MonthLine> oneOffs;

  /// Variable credit-card spending bought in this period (not linked to a fixed expense), by category.
  final List<MonthLine> card;

  /// True when `card` includes an estimate of what's still to come, by the average of the last statements.
  final bool cardEstimated;

  /// The "עוד צפוי לפי ממוצע החודשים הקודמים" line in `card`, or 0 when there is no estimate.
  final double cardEstimate;

  /// Card purchases priced like a fixed expense but not linked to it: they may be counted twice.
  final List<String> fixedInCardSuspects;

  /// When this money period began and ends.
  final DateTime? periodStart;
  final DateTime? periodEnd;
  final List<InstallmentLine> installments;

  /// Every installment still to be charged after this month.
  final double installmentsAfterThisMonth;

  double get net => actualNet ?? estimatedNet;
  bool get isActual => actualNet != null;
  static double _sum(Iterable<double> v) => v.fold(0.0, (a, b) => a + b);
  double get spendingTotal => _sum(spending.map((l) => l.amount));
  double get toSavingsTotal => _sum(toSavings.map((l) => l.amount));
  double get cardTotal => _sum(card.map((l) => l.amount));
  double get installmentsTotal => _sum(installments.map((l) => l.amount));
  double get cardWithInstallments => cardTotal + installmentsTotal;

  /// Positive = money came in, negative = went out.
  double get oneOffTotal => _sum(oneOffs.map((l) => l.amount));
  /// What is expected to be left after the card is charged, the estimate of the rest of the card included.
  double get remaining => net - spendingTotal - periodic - toSavingsTotal - cardWithInstallments + oneOffTotal;

  /// What is actually left so far: `remaining` without the estimate of card spending still to come.
  double get remainingActual => remaining + cardEstimate;
  String get title => Fmt.monthTitle(year, month);

  /// "10 באוק׳ – 9 בנוב׳", or the month's name when the period is a calendar month.
  String get periodTitle {
    final s = periodStart, e = periodEnd;
    if (s == null || e == null || s.day == 1) return title;
    final f = DateFormat('d בMMM', 'he');
    return '${f.format(s)} – ${f.format(DateTime(e.year, e.month, e.day - 1))}';
  }

  /// Days until the next pay day (at least 1).
  int get daysLeft {
    final e = periodEnd ?? DateTime(year, month + 1);
    final n = DateTime.now();
    final d = DateTime.utc(e.year, e.month, e.day).difference(DateTime.utc(n.year, n.month, n.day)).inDays;
    return d < 1 ? 1 : d;
  }

  /// The money period today is in (Store.monthPicture).
  static MonthPicture current(SaveFile file) {
    final (y, m) = file.money.period(DateTime.now());
    return of(file, y, m);
  }

  /// The month of one member's data (the member being viewed on this device).
  static MonthPicture of(SaveFile file, int year, int month, {Budget? budgetOverride, DateTime? now}) {
    final budget = budgetOverride ?? file.budget;
    final money = file.money;
    final monthStart = money.periodStart(year, month);
    final monthEnd = money.periodEnd(year, month);
    final cards = CardData(money);

    final spending = <MonthLine>[];
    final toSavings = <MonthLine>[];
    final base = budget.expenseBase;
    for (final item in budget.expenses.where((e) => e.isActive)) {
      final amount = item.amount(base);
      if (amount == 0) continue;
      final target = money.account(item.targetAccountID);
      if (target != null) {
        toSavings.add(MonthLine('${item.name} ← ${target.name}', amount));
      } else {
        spending.add(MonthLine(item.name, amount));
      }
    }

    // Automatic monthly deposits into savings plans.
    for (final a in money.accounts.where((a) => a.kind == AccountKind.savings || a.kind == AccountKind.deposit)) {
      if (a.monthlyContribution <= 0) continue;
      if (a.startDate != null && !a.startDate!.isBefore(monthEnd)) continue;
      if (a.maturityDate != null && a.maturityDate!.isBefore(monthStart)) continue;
      toSavings.add(MonthLine('הפקדה ל${a.name}', a.monthlyContribution));
    }

    // One-off transactions this month that touch the checking account (salary excluded).
    final oneOffs = <MonthLine>[];
    final checkingIDs = money.accounts.where((a) => a.kind == AccountKind.checking).map((a) => a.id).toList();
    final reimbursements = cards.reimbursementIncomeIDs;
    for (final t in money.transactions) {
      if (t.salaryKey != null || t.date.isBefore(monthStart) || !t.date.isBefore(monthEnd)) continue;
      // Money paid back by someone isn't income.
      if (reimbursements.contains(t.id)) continue;
      // Several checking accounts count as one (a transfer between them cancels out).
      var change = checkingIDs.fold(0.0, (s, id) => s + t.effectOn(id));
      // The part of an expense someone owes you isn't your spending.
      if (t.kind == TransactionKind.expense && change < 0) {
        final c = change + cards.owedPortion(t.id);
        change = c < 0 ? c : 0;
      }
      if (change == 0) continue;
      if (t.kind == TransactionKind.transfer) {
        final other = money.account(change < 0 ? t.toAccountID : t.accountID)?.name ?? 'חשבון';
        if (change < 0) {
          toSavings.add(MonthLine('${t.title} ← $other', -change));
        } else {
          oneOffs.add(MonthLine('${t.title} (מ$other)', change));
        }
      } else {
        final suspect = cards.looksLikeCardPurchase(t) ? ' ⚠︎ נראה שזה כבר בכרטיס' : '';
        oneOffs.add(MonthLine('${t.title}${t.isPlanned ? ' (מתוכנן)' : ''}$suspect', change));
      }
    }

    // Credit card: purchases count in the period they were bought in, whenever the card charges them. Fixed expenses
    // and tracked purchases already came off above, so a charge linked to one isn't counted again.
    final key = year * 100 + month;
    final charged = cards.chargedIn(key);
    final bought = cards.cardTransactions.where((t) => t.installment == null && !t.date.isBefore(monthStart) && t.date.isBefore(monthEnd)).toList();
    final summary = CardMonthSummary.of(bought);
    // Purchases recorded as "paid by card" that the statements don't show yet.
    final manualCard = cards.manualCardPayments;
    final card = <MonthLine>[
      for (final c in summary.byCategory) MonthLine(c.name, c.amount),
      for (final p in manualCard)
        if (p.of == 1 && !p.transaction.date.isBefore(monthStart) && p.transaction.date.isBefore(monthEnd))
          MonthLine('💳 ${p.transaction.title}', p.amount),
    ];
    // What wasn't imported yet: the rest of the usual spending, by the average of the last statements.
    var cardEstimated = false;
    var cardEstimate = 0.0;
    final known = card.fold(0.0, (s, l) => s + l.amount);
    final average = cards.averageCardVariable();
    if (average > known && (monthEnd.isAfter(DateTime.now()) || card.isEmpty)) {
      cardEstimate = average - known;
      card.add(MonthLine('עוד צפוי לפי ממוצע החודשים הקודמים', cardEstimate));
      cardEstimated = true;
    }
    // Cards whose statements aren't imported (e.g. the bank's own card): what they usually charge.
    for (final s in cards.cardSettings.where((s) => s.monthlyEstimate > 0)) {
      card.add(MonthLine('💳 ${s.displayName} (משוער)', s.monthlyEstimate));
    }
    // A fixed expense paid by card that isn't linked to its charge would count twice — point it out.
    final fixedAmounts = spending.map((l) => l.amount).where((a) => a >= 20).toList();
    final suspects = {
      for (final t in bought)
        if (t.isVariable && fixedAmounts.any((a) => (a - t.myAmount).abs() < 1)) t.merchant
    }.toList()
      ..sort();

    // Installments: only this month's payment counts, never the whole purchase.
    final allPlans = cards.installmentPlans;
    final plans = <String, InstallmentPlan>{};
    for (final p in allPlans) {
      plans.putIfAbsent(p.id, () => p);
    }
    final installments = <InstallmentLine>[];
    for (final t in charged) {
      final inst = t.installment;
      if (!t.isVariable || t.myAmount == 0 || inst == null) continue;
      final plan = plans[t.installmentPlanKey];
      final share = t.amount != 0 ? t.myAmount / t.amount : 1.0;
      final later = plan?.payments.where((p) => p.number > inst.number).fold(0.0, (s, p) => s + p.amount) ?? 0;
      final total = t.originalAmount != 0 ? t.originalAmount : (plan?.total ?? t.amount * inst.of);
      installments.add(InstallmentLine(
          merchant: t.merchant, number: inst.number, of: inst.of, amount: t.myAmount,
          total: total * share, leftAfter: later * share, expected: false));
    }
    var installmentsAfter = 0.0;
    for (final plan in allPlans.where((p) => p.countsAsVariable)) {
      for (final p in plan.payments.where((p) => !p.imported && p.billingKey == key)) {
        final later = plan.payments.where((q) => q.number > p.number).fold(0.0, (s, q) => s + q.amount);
        installments.add(InstallmentLine(
            merchant: plan.merchant, number: p.number, of: plan.count, amount: p.amount,
            total: plan.total, leftAfter: later, expected: true));
      }
      installmentsAfter += plan.payments.where((p) => p.billingKey > key).fold(0.0, (s, p) => s + p.amount);
    }
    for (final p in manualCard.where((p) => p.of > 1)) {
      if (p.billingKey == key) {
        final later = manualCard
            .where((q) => q.transaction.id == p.transaction.id && q.number > p.number)
            .fold(0.0, (s, q) => s + q.amount);
        installments.add(InstallmentLine(
            merchant: p.transaction.title, number: p.number, of: p.of, amount: p.amount,
            total: p.transaction.amount, leftAfter: later, expected: true));
      } else if (p.billingKey > key) {
        installmentsAfter += p.amount;
      }
    }
    installments.sort((a, b) => b.amount.compareTo(a.amount));

    double? actual;
    for (final r in file.history) {
      if (r.year == year && r.month == month) {
        actual = r.actualNet;
        break;
      }
    }

    return MonthPicture(
      year: year,
      month: month,
      estimatedNet: budget.net,
      actualNet: actual,
      spending: spending,
      periodic: budget.periodicTotal,
      toSavings: toSavings,
      oneOffs: oneOffs,
      card: card,
      cardEstimated: cardEstimated,
      cardEstimate: cardEstimate,
      fixedInCardSuspects: suspects,
      periodStart: monthStart,
      periodEnd: monthEnd,
      installments: installments,
      installmentsAfterThisMonth: installmentsAfter,
    );
  }
}
