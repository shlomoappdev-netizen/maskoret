import 'dart:math' as math;

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

  double total(MoneyData money, Set<AccountKind> kinds, [DateTime? on]) {
    final date = on ?? DateTime.now();
    final tx = money.transactions;
    return money.accounts.where((a) => kinds.contains(a.kind)).fold(0.0, (s, a) => s + value(a, date, tx));
  }
}
