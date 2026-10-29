import 'card.dart';
import 'fmt.dart';
import 'json.dart';
import 'models.dart';
import 'money_calc.dart';

/// The forecast: month by month, where the money goes — port of `Forecaster`, `MoneyCalc.expectedNet`,
/// `MoneyCalc.interestEarned` (Money.swift) and `MoneyData.projectedInstallments` (Card.swift).

enum IncomeBasis {
  recentAverage('ממוצע הנטו בפועל'),
  budget('חישוב לפי הברוטו'),
  manual('סכום שאני קובע');

  const IncomeBasis(this.title);
  final String title;
}

/// `ForecastSettings` inside the money object.
class ForecastSettings {
  ForecastSettings(this._o);
  final JObj _o;

  int get months => _o.i('months', 6);
  set months(int v) => _o.set('months', v);
  IncomeBasis get basis =>
      IncomeBasis.values.firstWhere((b) => b.name == _o.sOpt('basis'), orElse: () => IncomeBasis.recentAverage);
  set basis(IncomeBasis v) => _o.set('basis', v.name);
  double get manualNet => _o.d('manualNet');
  set manualNet(double v) => _o.set('manualNet', v);

  static ForecastSettings of(SaveFile file) => ForecastSettings(JObj.lazy(JObj.lazy(file.json, 'money').writeMap, 'forecast'));
}

class ForecastMonth {
  ForecastMonth({
    required this.index,
    required this.date,
    required this.income,
    required this.spending,
    required this.toSavings,
    this.card = 0,
    required this.events,
    required this.checking,
    required this.savings,
    required this.pension,
  });
  final int index;
  final DateTime date;
  final double income;
  final double spending;
  final double toSavings;
  final double card;
  final List<String> events;
  final double checking;
  final double savings;
  final double pension;

  double get liquid => checking + savings;
  String get label => Fmt.monthTitle(date.year, date.month);
  String get shortLabel => '${date.month}/${date.year % 100}';
}

class Forecaster {
  /// Expected net income per month and where it came from.
  static ({double amount, String source}) expectedNet(Budget budget, List<MonthRecord> history, ForecastSettings settings) {
    switch (settings.basis) {
      case IncomeBasis.manual:
        return (amount: settings.manualNet, source: 'סכום שקבעת');
      case IncomeBasis.budget:
        return (amount: budget.net, source: 'חישוב לפי הברוטו והניכויים');
      case IncomeBasis.recentAverage:
        final actuals = (history.where((r) => r.actualNet != null).toList()..sort((a, b) => b.sortKey.compareTo(a.sortKey)))
            .take(3)
            .map((r) => r.actualNet!)
            .toList();
        if (actuals.isEmpty) return (amount: budget.net, source: 'אין עדיין נטו בפועל — לפי חישוב הברוטו');
        final avg = actuals.reduce((a, b) => a + b) / actuals.length;
        return (amount: avg, source: 'ממוצע נטו בפועל של ${actuals.length} החודשים האחרונים');
    }
  }

  /// Gross interest earned since the last balance update.
  static double interestEarned(MoneyCalc calc, Account a, DateTime date, List<MoneyTransaction> tx) {
    if (!a.kind.hasInterest) return 0;
    final base = MoneyCalc.baseEntry(a, date);
    if (base == null) return 0;
    final deposits = MoneyCalc.contributionDates(a, base.date, date).length * a.monthlyContribution;
    final flows = tx.where((t) => t.date.isAfter(base.date) && !t.date.isAfter(date)).fold(0.0, (s, t) => s + t.effectOn(a.id));
    return calc.value(a, date, tx) - (base.amount + deposits + flows);
  }

  /// Expected installment payments (not yet in an imported statement) charged between two dates.
  static double projectedInstallments(CardData cards, DateTime from, DateTime to) => cards.installmentPlans
      .where((p) => p.countsAsVariable)
      .fold(0.0, (s, p) => s + p.payments.where((x) => !x.imported && x.chargeDate.isAfter(from) && !x.chargeDate.isAfter(to)).fold(0.0, (a, x) => a + x.amount));

  /// Month-by-month projection. Index 0 is today.
  static List<ForecastMonth> run(SaveFile file, {int? months, DateTime? now}) {
    final today = now ?? DateTime.now();
    final budget = file.budget;
    final money = file.money;
    final history = file.history;
    final settings = ForecastSettings(JObj.lazy(JObj.lazy(file.json, 'money').readMap ?? {}, 'forecast'));
    final count = months ?? settings.months;
    final calc = MoneyCalc(money.primeRate);
    final cards = CardData(money);
    final net = expectedNet(budget, history, settings).amount;
    final accounts = money.accounts;
    final tx = money.transactions;

    final balances = <String, double>{for (final a in accounts) a.id: calc.value(a, today, tx)};
    final checkingID = money.checking?.id;

    (double, double, double) totals() {
      var checking = 0.0, savings = 0.0, pension = 0.0;
      for (final a in accounts) {
        final v = balances[a.id] ?? 0;
        switch (a.kind) {
          case AccountKind.checking:
            checking += v;
          case AccountKind.savings:
          case AccountKind.deposit:
            savings += v;
          case AccountKind.pension:
            pension += v;
        }
      }
      return (checking, savings, pension);
    }

    void add(String? id, double v) {
      if (id == null) return;
      balances[id] = (balances[id] ?? 0) + v;
    }

    final start = totals();
    final result = [
      ForecastMonth(index: 0, date: today, income: 0, spending: 0, toSavings: 0, events: const [], checking: start.$1, savings: start.$2, pension: start.$3),
    ];

    // Fixed expenses split: plain spending vs transfers into one of your accounts.
    final transfers = <(String, double)>[];
    var spending = budget.periodicTotal;
    for (final item in budget.expenses.where((e) => e.isActive)) {
      final amount = item.amount(budget.expenseBase);
      final target = item.targetAccountID;
      if (target != null && money.account(target) != null) {
        transfers.add((target, amount));
      } else {
        spending += amount;
      }
    }
    final monthlyToSavings = transfers.fold(0.0, (s, t) => s + t.$2);
    final cardAverage = cards.averageCardVariable();
    final manualCard = cards.manualCardPayments;

    if (count <= 0) return result;
    for (var m = 1; m <= count; m++) {
      final from = addMonths(today, m - 1), to = addMonths(today, m);
      final events = <String>[];
      bool inMonth(DateTime d) => d.isAfter(today) && d.isAfter(from) && !d.isAfter(to);

      // Interest / returns for the month.
      for (final a in accounts.where((a) => a.kind != AccountKind.checking)) {
        balances[a.id] = (balances[a.id] ?? 0) * calc.growth(a, from, to);
      }
      // Salary in, fixed spending out, transfers to savings.
      add(checkingID, net - spending - monthlyToSavings);
      for (final (target, amount) in transfers) {
        add(target, amount);
      }
      // Pension deposits (from the salary, not the checking account).
      for (final a in accounts.where((a) => a.kind == AccountKind.pension)) {
        add(a.id, a.monthlyContribution);
      }
      // Fixed monthly deposits into savings plans — taken from the checking account.
      for (final a in accounts.where((a) => a.kind == AccountKind.savings || a.kind == AccountKind.deposit)) {
        final n = MoneyCalc.contributionDates(a, from, to).length;
        if (n > 0) {
          final amount = n * a.monthlyContribution;
          add(a.id, amount);
          add(checkingID, -amount);
        }
      }

      // Credit card (spending not already covered by a fixed expense).
      var card = 0.0;
      final upcoming = cards.cardTransactions.where((t) => t.chargeDate != null && inMonth(t.chargeDate!) && !t.ignored).toList();
      final projected = projectedInstallments(cards, from, to);
      final upcomingInstallments =
          upcoming.where((t) => t.isVariable && t.installment != null).fold(0.0, (s, t) => s + t.myAmount);
      if (upcoming.isNotEmpty) {
        var regular = upcoming.where((t) => t.isVariable && t.installment == null).fold(0.0, (s, t) => s + t.myAmount);
        // A statement that is still open (only pending purchases) will grow — never below the average.
        if (upcoming.every((t) => t.chargeEstimated)) regular = regular > cardAverage ? regular : cardAverage;
        card = regular + upcomingInstallments + projected;
        if (card != 0) events.add('כרטיס אשראי −${Fmt.money(card)}');
      } else {
        card = cardAverage + projected;
      }
      if (upcomingInstallments + projected > 0) events.add('מתוכם תשלומים −${Fmt.money(upcomingInstallments + projected)}');
      // Purchases recorded as paid by card that aren't in an imported statement yet.
      for (final p in manualCard.where((p) => inMonth(p.chargeDate))) {
        card += p.amount;
        events.add('💳 ${p.transaction.title} −${Fmt.money(p.amount)}');
      }
      add(checkingID, -card);

      // Planned transactions.
      for (final t in tx.where((t) => inMonth(t.date))) {
        for (final a in accounts) {
          final change = t.effectOn(a.id);
          if (change != 0) add(a.id, change);
        }
        final sign = t.kind == TransactionKind.income ? '+' : (t.kind == TransactionKind.expense ? '−' : '↔');
        events.add('${t.title} $sign${Fmt.money(t.amount)}');
      }

      // Deposits that mature go back to the checking account.
      for (final a in accounts.where((a) => a.kind == AccountKind.deposit)) {
        final maturity = a.maturityDate;
        if (maturity != null && maturity.isAfter(from) && !maturity.isAfter(to) && checkingID != null) {
          final amount = balances[a.id] ?? 0;
          final interest = interestEarned(calc, a, maturity, tx);
          final tax = (interest > 0 ? interest : 0) * a.interestTax / 100;
          balances[a.id] = 0;
          add(checkingID, amount - tax);
          events.add('פירעון ${a.name} +${Fmt.money(amount - tax)}');
        }
      }

      final t = totals();
      result.add(ForecastMonth(
        index: m,
        date: to,
        income: net,
        spending: spending + card,
        toSavings: monthlyToSavings,
        card: card,
        events: events,
        checking: t.$1,
        savings: t.$2,
        pension: t.$3,
      ));
    }
    return result;
  }
}
