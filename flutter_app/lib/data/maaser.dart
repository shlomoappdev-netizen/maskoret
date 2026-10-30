import 'dart:math' as math;

import 'card.dart';
import 'json.dart';
import 'models.dart';
import 'money_calc.dart';

/// What the maaser percentage is taken from (MaaserBase in Maaser.swift).
enum MaaserBase {
  gross('ברוטו מלא'),
  afterIncomeTax('ברוטו פחות מס הכנסה'),
  afterTaxAndNI('ברוטו פחות מס, ביטוח לאומי ובריאות'),
  actualNet('נטו שנכנס בפועל');

  const MaaserBase(this.title);
  final String title;
}

class MaaserDonation {
  MaaserDonation(this.json);
  final Json json;
  JObj get _o => JObj(json);
  String get id => _o.s('id');
  DateTime get date => _o.date('date') ?? DateTime.now();
  double get amount => _o.d('amount');
  String get note => _o.s('note');

  static Json create({required DateTime date, required double amount, String note = ''}) =>
      {'id': newId(), 'date': dateTimeToSwift(date), 'amount': jsonNumber(amount), 'note': note};
}

/// money.maaser — per family member, every member has their own maaser fund.
class MaaserSettings {
  MaaserSettings(this._o);
  final JObj _o;

  static MaaserSettings of(SaveFile file) => MaaserSettings(JObj.lazy(JObj.lazy(file.json, 'money').writeMap, 'maaser'));

  bool get enabled => _o.b('enabled');
  set enabled(bool v) => _o.set('enabled', v);
  double get percent => _o.d('percent', 10);
  set percent(double v) => _o.set('percent', v);
  MaaserBase get base =>
      MaaserBase.values.firstWhere((b) => b.name == _o.sOpt('base'), orElse: () => MaaserBase.afterIncomeTax);
  set base(MaaserBase v) => _o.set('base', v.name);
  bool get includeInterest => _o.b('includeInterest', true);
  set includeInterest(bool v) => _o.set('includeInterest', v);
  bool get includeOneOffs => _o.b('includeOneOffs', true);
  set includeOneOffs(bool v) => _o.set('includeOneOffs', v);
  int get startKey => _o.i('startKey');
  set startKey(int v) => _o.set('startKey', v);
  double get openingBalance => _o.d('openingBalance');
  set openingBalance(double v) => _o.set('openingBalance', v);

  List<String> _strings(String k) => [for (final v in (_o.raw(k) as List?) ?? const []) if (v is String) v];
  List<String> get excludedIncomeIDs => _strings('excludedIncomeIDs');
  List<String> get deductedExpenseIDs => _strings('deductedExpenseIDs');
  List<String> get maaserExpenseIDs => _strings('maaserExpenseIDs');
  List<String> get maaserCardIDs => _strings('maaserCardIDs');
  List<String> get maaserMerchants => _strings('maaserMerchants');
  List<MaaserDonation> get donations => _o.objects('donations').map(MaaserDonation.new).toList();

  /// Adds or removes `value` in one of the id lists (writes the full list, like Swift encodes it).
  void toggle(String key, String value, bool on) {
    final list = _strings(key)..remove(value);
    if (on) list.add(value);
    _o.set(key, list);
  }

  void addDonation(Json d) => _o.addObject('donations', d);
  void deleteDonation(String id) => _o.removeWhere('donations', (d) => d['id'] == id);

  bool isMaaser(CardTransaction tx) =>
      !tx.ignored && (maaserCardIDs.contains(tx.id) || maaserMerchants.contains(tx.merchantKey));
}

class MaaserMonth {
  MaaserMonth({
    required this.key,
    required this.base,
    required this.salaryBase,
    required this.interest,
    required this.oneOffs,
    required this.deducted,
    required this.owed,
    required this.paid,
    required this.balance,
  });

  final int key;

  /// null = the actual net for this month wasn't recorded yet, so nothing is owed for it yet.
  final double? base;
  final double salaryBase;
  final double interest;
  final double oneOffs;
  final double deducted;
  final double owed;
  final double paid;

  /// Running balance after this month: + owed, − credit.
  final double balance;
}

class MaaserStatus {
  final months = <MaaserMonth>[];
  double balance = 0;
  double thisMonthOwed = 0;
  double thisMonthPaid = 0;
  double paidThisYear = 0;
  final missingMonths = <int>[];
}

/// Port of MaaserCalc (Maaser.swift).
class MaaserCalc {
  static int key(DateTime d) => d.year * 100 + d.month;

  static int nextKey(int key) => key % 100 == 12 ? (key ~/ 100 + 1) * 100 + 1 : key + 1;

  /// Salary part of the base, from the actual net and that month's payslip.
  static double salaryBase(double actualNet, Budget budget, MaaserBase base) {
    double sum(Set<AutoDeduction> types) => budget.deductions
        .where((d) => d.isActive && d.auto != null && types.contains(d.auto))
        .fold(0.0, (s, d) => s + budget.deductionAmount(d));
    final all = budget.totalDeductions;
    return switch (base) {
      MaaserBase.gross => actualNet + all,
      MaaserBase.afterIncomeTax => actualNet + all - sum({AutoDeduction.incomeTax}),
      MaaserBase.afterTaxAndNI =>
        actualNet + all - sum({AutoDeduction.incomeTax, AutoDeduction.nationalInsurance, AutoDeduction.healthInsurance}),
      MaaserBase.actualNet => actualNet,
    };
  }

  /// Interest earned during the month in savings and deposits (after tax unless the base is gross).
  static double interest(MoneyData money, DateTime from, DateTime to, bool gross, DateTime now) {
    final end = to.isBefore(now) ? to : now;
    if (!end.isAfter(from)) return 0;
    final calc = MoneyCalc(money.primeRate);
    final transactions = money.transactions;
    var total = 0.0;
    for (final a in money.accounts.where((a) => a.kind.hasInterest)) {
      // Measure only from the latest balance entered — before it the balance is unknown and must never count as profit.
      DateTime? lastEntry;
      for (final b in a.balances) {
        if (!b.date.isAfter(end) && (lastEntry == null || b.date.isAfter(lastEntry))) lastEntry = b.date;
      }
      if (lastEntry == null) continue;
      final start = from.isAfter(lastEntry) ? from : lastEntry;
      if (!end.isAfter(start)) continue;
      final before = calc.value(a, start, transactions);
      final after = calc.value(a, end, transactions);
      final deposits = MoneyCalc.contributionDates(a, start, end).length * a.monthlyContribution;
      final flows = transactions
          .where((t) => t.date.isAfter(start) && !t.date.isAfter(end))
          .fold(0.0, (s, t) => s + t.effectOn(a.id));
      final earned = after - before - deposits - flows;
      if (earned <= 0) continue;
      total += gross ? earned : earned * (1 - a.interestTax / 100);
    }
    return total;
  }

  static Budget recordBudget(MonthRecord r) => Budget(JObj(r.json['budget'] as Json? ?? <String, dynamic>{}));

  static MaaserStatus status(SaveFile file, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final s = MaaserSettings(JObj((file.money.raw['maaser'] as Json?) ?? <String, dynamic>{}));
    final result = MaaserStatus();
    if (!s.enabled) return result;
    final budget = file.budget;
    final money = file.money;
    final history = file.history;
    final cards = CardData(money);
    final current = key(at);
    final start = s.startKey > 0 ? s.startKey : current;
    var balance = s.openingBalance;
    var k = start;
    var guard = 0;
    final excluded = s.excludedIncomeIDs.toSet();
    final reimbursements = cards.reimbursementIncomeIDs;
    while (k <= current && guard < 600) {
      guard++;
      final from = DateTime(k ~/ 100, k % 100);
      final to = addMonths(from, 1);
      final record = history.where((r) => r.year * 100 + r.month == k).firstOrNull;
      final recordBudget = record == null ? null : MaaserCalc.recordBudget(record);

      // What's owed — only once the actual net was recorded.
      double? base;
      var salary = 0.0, interest = 0.0, oneOffs = 0.0, deducted = 0.0;
      final net = record?.actualNet;
      if (recordBudget != null && net != null) {
        salary = salaryBase(net, recordBudget, s.base);
        // Like Swift: interest is measured up to the real "now", not the status date.
        if (s.includeInterest) interest = MaaserCalc.interest(money, from, to, s.base == MaaserBase.gross, DateTime.now());
        if (s.includeOneOffs) {
          oneOffs = money.transactions
              .where((t) =>
                  t.kind == TransactionKind.income &&
                  t.salaryKey == null &&
                  !t.date.isBefore(from) &&
                  t.date.isBefore(to) &&
                  !t.date.isAfter(at) &&
                  !excluded.contains(t.id) &&
                  !reimbursements.contains(t.id))
              .fold(0.0, (sum, t) => sum + t.amount);
        }
        deducted = recordBudget.expenses
            .where((e) => e.isActive && s.deductedExpenseIDs.contains(e.id))
            .fold(0.0, (sum, e) => sum + e.amount(recordBudget.expenseBase));
        base = math.max(0, salary + interest + oneOffs - deducted);
      } else {
        result.missingMonths.add(k);
      }
      final owed = (base ?? 0) * s.percent / 100;

      // What was given.
      var paid = 0.0;
      final monthBudget = recordBudget ?? budget;
      for (final id in s.maaserExpenseIDs) {
        final e = monthBudget.expenses.where((e) => e.id == id).firstOrNull ??
            budget.expenses.where((e) => e.id == id).firstOrNull;
        if (e != null && e.isActive) paid += e.amount(monthBudget.expenseBase);
      }
      paid += cards.cardTransactions
          .where((t) => t.billingKey == k && s.isMaaser(t) && !(t.chargeDate ?? t.date).isAfter(at))
          .fold(0.0, (sum, t) => sum + t.amount);
      paid += s.donations
          .where((d) => !d.date.isBefore(from) && d.date.isBefore(to))
          .fold(0.0, (sum, d) => sum + d.amount);

      balance += owed - paid;
      result.months.add(MaaserMonth(
          key: k,
          base: base,
          salaryBase: salary,
          interest: interest,
          oneOffs: oneOffs,
          deducted: deducted,
          owed: owed,
          paid: paid,
          balance: balance));
      if (k == current) {
        result.thisMonthOwed = owed;
        result.thisMonthPaid = paid;
      }
      if (k ~/ 100 == current ~/ 100) result.paidThisYear += paid;
      k = nextKey(k);
    }
    result.balance = balance;
    return result;
  }

  /// Store.addDonation: the donation, and optionally the same amount out of the checking account.
  static void addDonation(SaveFile f, {required DateTime date, required double amount, String note = '', required bool fromChecking}) {
    MaaserSettings.of(f).addDonation(MaaserDonation.create(date: date, amount: amount, note: note));
    if (fromChecking) {
      final checking = f.money.ensureChecking();
      f.money.upsertTransaction(MoneyTransaction.create(kind: TransactionKind.expense, accountID: checking.id)
        ..['date'] = dateTimeToSwift(date)
        ..['title'] = 'מעשרות${note.isEmpty ? '' : ' — $note'}'
        ..['amount'] = jsonNumber(amount));
    }
  }

  /// Store.setCardMaaser: marks / unmarks a card charge; with `merchant`, every charge from that business counts.
  static void setCardMaaser(SaveFile f, CardTransaction tx, {required bool on, required bool merchant}) {
    final m = MaaserSettings.of(f);
    if (on) {
      if (merchant) {
        if (!m.maaserMerchants.contains(tx.merchantKey)) m.toggle('maaserMerchants', tx.merchantKey, true);
      } else if (!m.maaserCardIDs.contains(tx.id)) {
        m.toggle('maaserCardIDs', tx.id, true);
      }
    } else {
      m.toggle('maaserCardIDs', tx.id, false);
      m.toggle('maaserMerchants', tx.merchantKey, false);
    }
  }
}
