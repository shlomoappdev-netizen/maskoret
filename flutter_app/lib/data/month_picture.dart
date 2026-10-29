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

/// One consistent picture of a month: actual net (if recorded) or the estimate, fixed expenses, periodic
/// purchases, money moved into savings, credit-card charges and one-off transactions. "נשאר בסוף החודש" is
/// `remaining` — the same number as in the iPhone/Mac app. Port of `MonthPicture` / `Store.monthPicture` (Sync.swift).
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

  /// Variable credit-card spending charged this month (not linked to a fixed expense), by category.
  final List<MonthLine> card;

  /// True when `card` is an average because this month's statement wasn't imported yet.
  final bool cardEstimated;
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
  double get remaining => net - spendingTotal - periodic - toSavingsTotal - cardWithInstallments + oneOffTotal;
  String get title => Fmt.monthTitle(year, month);

  /// The month of one member's data (the member being viewed on this device).
  static MonthPicture of(SaveFile file, int year, int month, {Budget? budgetOverride, DateTime? now}) {
    final monthStart = DateTime(year, month);
    final monthEnd = addMonths(monthStart, 1);
    final budget = budgetOverride ?? file.budget;
    final money = file.money;
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

    // Credit card: what is charged this month and isn't already a fixed expense / tracked purchase.
    final key = year * 100 + month;
    var card = <MonthLine>[];
    var cardEstimated = false;
    final charged = cards.chargedIn(key);
    final summary = CardMonthSummary.of(charged);
    final hasStatement = cards.cardStatementKeys.contains(key) || (cards.cardStatementKeys.isEmpty && charged.isNotEmpty);
    // Purchases recorded as "paid by card" that the statements don't show yet.
    final manualCard = cards.manualCardPayments;
    final manualRegular = manualCard.where((p) => p.of == 1 && p.billingKey == key).toList();
    final manualRegularTotal = manualRegular.fold(0.0, (s, p) => s + p.amount);
    List<MonthLine> byCategory() => [
          for (final c in summary.byCategory) MonthLine(c.name, c.amount),
          for (final p in manualRegular) MonthLine('💳 ${p.transaction.title} (צפוי בכרטיס)', p.amount),
        ];
    if (hasStatement) {
      card = byCategory();
    } else {
      final average = cards.averageCardVariable();
      final soFar = summary.variable - summary.installments + manualRegularTotal;
      if (average > 0) {
        card = [MonthLine('הערכה לפי ממוצע (בלי תשלומים)', average > soFar ? average : soFar)];
        if (manualRegularTotal > average) card[0] = MonthLine('הערכה — כולל קניות שרשמת באשראי', soFar);
        cardEstimated = true;
      } else {
        card = byCategory();
      }
    }

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
      installments: installments,
      installmentsAfterThisMonth: installmentsAfter,
    );
  }
}
