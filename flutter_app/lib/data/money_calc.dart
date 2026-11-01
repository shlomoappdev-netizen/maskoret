import 'dart:math' as math;

import 'card.dart';
import 'forecast.dart';
import 'models.dart';

/// Calendar month arithmetic like Foundation's `Calendar.date(byAdding: .month…)`:
/// the day is clamped to the end of the target month (Jan 31 + 1 month = Feb 28/29).
DateTime addMonths(DateTime d, int months) {
  final total = d.year * 12 + (d.month - 1) + months;
  final y = total ~/ 12;
  final m = total % 12 + 1;
  final lastDay = DateTime(y, m + 1, 0).day;
  return DateTime(y, m, math.min(d.day, lastDay), d.hour, d.minute, d.second, d.millisecond, d.microsecond);
}

/// Whole months from `a` to `b` (`Calendar.dateComponents([.month], from:to:)`).
int wholeMonths(DateTime a, DateTime b) {
  var months = (b.year - a.year) * 12 + (b.month - a.month);
  if (months > 0 && addMonths(a, months).isAfter(b)) months--;
  if (months < 0 && addMonths(a, months).isBefore(b)) months++;
  return months;
}

/// Port of `MoneyCalc` and the date helpers of `Account` (Money.swift).
class MoneyCalc {
  MoneyCalc(this.prime);

  /// The prime rate of the member being viewed.
  final double prime;

  static const day = 86400.0;

  static double years(DateTime from, DateTime to) {
    final s = to.difference(from).inMicroseconds / 1e6;
    return math.max(0, s) / day / 365;
  }

  static List<RateTier> _sortedTiers(Account a) => a.rateTiers..sort((x, y) => x.fromMonth.compareTo(y.fromMonth));

  static double primeMinusFor(Account a, int? m) {
    final tiers = _sortedTiers(a);
    if (tiers.isEmpty) return a.primeMinus;
    if (m == null) return tiers.last.primeMinus;
    RateTier? match;
    for (final t in tiers) {
      if (t.fromMonth <= m) match = t;
    }
    return (match ?? tiers.first).primeMinus;
  }

  static int? monthsFromStart(Account a, DateTime date) {
    final start = a.startDate;
    return start == null ? null : wholeMonths(start, date);
  }

  static DateTime? nextExitPoint(Account a, DateTime after) {
    final start = a.startDate;
    if (start == null || a.exitFirstMonths <= 0) return null;
    var point = addMonths(start, a.exitFirstMonths);
    var guard = 0;
    while (point.isBefore(after) && guard < 400) {
      if (a.exitEveryMonths <= 0) return null;
      point = addMonths(point, a.exitEveryMonths);
      guard++;
    }
    final maturity = a.maturityDate;
    if (maturity != null && point.isAfter(maturity)) return null;
    return point;
  }

  static int? exitMonthsCovering(Account a, DateTime date) {
    final exit = nextExitPoint(a, date);
    if (exit != null) return monthsFromStart(a, exit);
    final maturity = a.maturityDate;
    if (maturity != null) return monthsFromStart(a, maturity);
    return monthsFromStart(a, date);
  }

  double effectiveRate(Account a, DateTime at) {
    if (!a.isPrimeLinked) return a.annualRate;
    return prime - primeMinusFor(a, a.rateTiers.isEmpty ? null : exitMonthsCovering(a, at));
  }

  /// Dates of the fixed monthly deposit in (from, to].
  static List<DateTime> contributionDates(Account a, DateTime from, DateTime to) {
    if (a.monthlyContribution <= 0 || a.kind == AccountKind.pension || a.kind == AccountKind.checking) return [];
    var end = to;
    final maturity = a.maturityDate;
    if (maturity != null && maturity.isBefore(end)) end = maturity;
    var d = DateTime(from.year, from.month, a.contributionDay.clamp(1, 28));
    final result = <DateTime>[];
    var count = 0;
    final start = a.startDate;
    while (!d.isAfter(end) && count < 600) {
      if (d.isAfter(from) && (start == null || !d.isBefore(start))) result.add(d);
      d = addMonths(d, 1);
      count++;
    }
    return result;
  }

  /// How much 1 ₪ in `account` grows between two dates (deposits stop at maturity).
  double growth(Account a, DateTime from, DateTime to) {
    final rate = effectiveRate(a, to);
    if (a.kind == AccountKind.checking || rate == 0) return 1;
    var end = to;
    final maturity = a.maturityDate;
    if (a.kind == AccountKind.deposit && maturity != null && maturity.isBefore(end)) end = maturity;
    final y = years(from, end);
    if (y <= 0) return 1;
    final r = rate / 100;
    if (a.kind == AccountKind.pension) return math.pow(1 + r, y).toDouble();
    return switch (a.compounding) {
      Compounding.simple => 1 + r * y,
      Compounding.monthly => math.pow(1 + r / 12, y * 12).toDouble(),
      Compounding.yearly => math.pow(1 + r, y).toDouble(),
    };
  }

  static BalanceEntry? baseEntry(Account a, DateTime date) {
    BalanceEntry? best;
    for (final b in a.balances) {
      if (!b.date.isAfter(date) && (best == null || b.date.isAfter(best.date))) best = b;
    }
    return best;
  }

  /// Estimated balance on `date`: last balance update, plus interest, plus recorded transactions since.
  double value(Account a, DateTime date, List<MoneyTransaction> transactions) {
    final base = baseEntry(a, date);
    final baseDate = base?.date;
    var value = (base?.amount ?? 0) * growth(a, base?.date ?? date, date);
    for (final t in transactions) {
      final td = t.date;
      if ((baseDate == null || td.isAfter(baseDate)) && !td.isAfter(date)) {
        final change = t.effectOn(a.id);
        if (change != 0) value += change * growth(a, td, date);
      }
    }
    for (final d in contributionDates(a, baseDate ?? date, date)) {
      value += a.monthlyContribution * growth(a, d, date);
    }
    if (a.kind == AccountKind.pension && a.monthlyContribution > 0 && base != null) {
      value += a.monthlyContribution * (years(base.date, date) * 12).floorToDouble();
    }
    return value;
  }

  double total(MoneyData money, Set<AccountKind> kinds, {DateTime? on, Budget? budget, List<MonthRecord> history = const []}) {
    final date = on ?? DateTime.now();
    return money.accounts
        .where((a) => kinds.contains(a.kind))
        .fold(0.0, (s, a) => s + money.balance(a, date, budget, history));
  }
}

/// Pay periods and balances — port of the MoneyData extensions in Money.swift.
extension MoneyPeriods on MoneyData {
  /// Where the money period of (year, month) begins: that month's pay day. The period runs until the next month's
  /// pay day and is named after the month the salary came in. A pay day of 1 makes it the calendar month.
  DateTime periodStart(int year, int month) {
    final days = DateTime(year, month + 1, 0).day;
    return DateTime(year, month, math.min(math.max(payDay, 1), days));
  }

  DateTime periodEnd(int year, int month) => month == 12 ? periodStart(year + 1, 1) : periodStart(year, month + 1);

  /// The money period a date falls in.
  (int, int) period(DateTime date) {
    if (!date.isBefore(periodStart(date.year, date.month))) return (date.year, date.month);
    return date.month == 1 ? (date.year - 1, 12) : (date.year, date.month - 1);
  }

  /// Estimated balance of an account: `MoneyCalc.value`, and the main checking account also pays for the fixed
  /// deposits into savings plans (they raise the plan on their day, so the money has to leave here on that day).
  /// With a budget, it also follows the salary, fixed expenses and card charges (`expectedChecking`).
  double balance(Account account, [DateTime? on, Budget? budget, List<MonthRecord> history = const []]) {
    final date = on ?? DateTime.now();
    var value = MoneyCalc(primeRate).value(account, date, transactions);
    final base = MoneyCalc.baseEntry(account, date);
    if (account.id != checking?.id || base == null) return value;
    for (final plan in accounts.where((a) => a.kind == AccountKind.savings || a.kind == AccountKind.deposit)) {
      value -= MoneyCalc.contributionDates(plan, base.date, date).length * plan.monthlyContribution;
    }
    final since = autoBalanceSince;
    if (budget != null && since != null) {
      value += expectedChecking(base.date.isAfter(since) ? base.date : since, date, budget, history);
    }
    return value;
  }

  /// What should have moved in the checking account in (from, to] without being recorded: the salary on the pay day,
  /// fixed expenses on their day, and the card on its charge day. Typing in a balance starts this count over.
  double expectedChecking(DateTime from, DateTime to, Budget budget, List<MonthRecord> history) {
    if (!from.isBefore(to)) return 0;
    DateTime day(int wanted, int year, int month) {
      final days = DateTime(year, month + 1, 0).day;
      return DateTime(year, month, math.min(math.max(wanted, 1), days));
    }

    bool inRange(DateTime d) => d.isAfter(from) && !d.isAfter(to);
    final cards = CardData(this);
    var total = 0.0;

    // Card: every imported charge once its day came — fixed expenses and tracked purchases on the card included.
    for (final t in cards.cardTransactions.where((t) => !t.ignored)) {
      final d = t.chargeDate;
      if (d != null && inRange(d)) total -= t.amount;
    }
    for (final p in cards.manualCardPayments.where((p) => inRange(p.chargeDate))) {
      total -= p.amount;
    }

    var y = from.year, m = from.month;
    final endKey = to.year * 100 + to.month;
    final cardDay = cards.usualChargeDay;
    final average = cards.averageCardVariable();
    final tx = transactions;
    while (y * 100 + m <= endKey) {
      final key = y * 100 + m;
      // Salary, unless it was recorded as a transaction.
      if (inRange(periodStart(y, m)) && !tx.any((t) => t.salaryKey == key)) {
        total += history.where((r) => r.year == y && r.month == m).firstOrNull?.actualNet ?? budget.net;
      }
      final statement = cards.chargedIn(key);
      // A statement that wasn't imported: the usual spending and the planned installments.
      if (cardDay != null && statement.isEmpty) {
        final d = day(cardDay, y, m);
        if (inRange(d)) total -= average + Forecaster.projectedInstallments(cards, DateTime(d.year, d.month, d.day - 1), d);
      }
      // Fixed expenses. One paid by card leaves with the statement, so it never counts by itself as well.
      for (final item in budget.expenses.where((e) => e.isActive)) {
        final amount = item.amount(budget.expenseBase);
        if (amount == 0) continue;
        final onCard = cards.cardTransactions.any((t) => t.linkedExpenseID == item.id && !t.ignored);
        if (onCard && statement.any((t) => t.linkedExpenseID == item.id && !t.ignored)) continue;
        final d = day(onCard ? (cardDay ?? payDay) : (item.chargeDay ?? payDay), y, m);
        if (inRange(d)) total -= amount;
      }
      if (m == 12) {
        y += 1;
        m = 1;
      } else {
        m += 1;
      }
    }
    return total;
  }

  /// Savings deposits live in one place, the savings account. A fixed expense marked "transfer to savings" becomes a
  /// monthly deposit of that account, from now on. Returns whether anything moved. Transfers to a pension stay.
  bool adoptSavingsTransfers(Budget budget) {
    var changed = false;
    if (autoBalanceSince == null) {
      autoBalanceSince = DateTime.now();
      changed = true;
    }
    for (final item in budget.expenses) {
      final target = account(item.targetAccountID);
      if (target == null || (target.kind != AccountKind.savings && target.kind != AccountKind.deposit)) continue;
      if (item.isActive) {
        final amount = (item.amount(budget.expenseBase) * 100).round() / 100;
        if (target.monthlyContribution <= 0) {
          target.contributionDay = math.min(math.max(payDay, 1), 28);
          target.startDate ??= DateTime.now();
        }
        target.monthlyContribution += amount;
      }
      budget.removeExpense(item.id);
      changed = true;
    }
    return changed;
  }
}
