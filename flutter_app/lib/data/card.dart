import 'json.dart';
import 'models.dart';
import 'money_calc.dart';

/// Read-only views of the credit-card and "owed to me" data (edited only in the iPhone/Mac app),
/// with the calculations the month picture needs. Ports of Card.swift and Receivables.swift.

int _billingKey(DateTime d) => d.year * 100 + d.month;

/// One line from a credit-card statement (Max export).
class CardTransaction {
  CardTransaction(this.json);
  final Json json;
  JObj get _o => JObj(json);

  String get id => _o.s('id');
  DateTime get date => _o.date('date') ?? DateTime.now();
  String get merchant => _o.s('merchant');
  String get category => _o.s('category');
  String get cardLast4 => _o.s('cardLast4');
  double get amount => _o.d('amount');
  double get originalAmount => _o.d('originalAmount');
  DateTime? get chargeDate => _o.date('chargeDate');
  bool get chargeEstimated => _o.b('chargeEstimated');
  String get note => _o.s('note');
  String get status => _o.s('status', 'charged');
  String? get linkedExpenseID => _o.sOpt('linkedExpenseID');
  String? get linkedTrackedID => _o.sOpt('linkedTrackedID');
  bool get ignored => _o.b('ignored');
  double get owedPortion => _o.d('owedPortion');

  /// What is really your own spending in this charge.
  double get myAmount => amount > 0 ? (amount - owedPortion > 0 ? amount - owedPortion : 0) : amount;

  /// Spending that is not covered by a fixed expense or a tracked purchase.
  bool get isVariable => !ignored && linkedExpenseID == null && linkedTrackedID == null;

  int? get billingKey => chargeDate == null ? null : _billingKey(chargeDate!);

  String get merchantKey => merchant.toLowerCase().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).join(' ');

  static final _installmentPattern = RegExp(r'תשלום\s*(\d+)\s*מתוך\s*(\d+)');

  /// "תשלום 1 מתוך 2" → (1, 2).
  ({int number, int of})? get installment {
    final m = _installmentPattern.firstMatch(note);
    if (m == null) return null;
    final n = int.tryParse(m.group(1)!), total = int.tryParse(m.group(2)!);
    if (n == null || total == null || total <= 1) return null;
    return (number: n, of: total);
  }

  /// Same purchase, every payment: merchant | purchase day | card | original amount.
  String get installmentPlanKey {
    final day = date.millisecondsSinceEpoch ~/ 86400000;
    return [merchantKey, '$day', cardLast4, originalAmount.toStringAsFixed(2)].join('|');
  }
}

class InstallmentPayment {
  InstallmentPayment(this.number, this.chargeDate, this.amount, this.imported);
  final int number;
  final DateTime chargeDate;
  final double amount;

  /// From an imported statement (false = expected).
  final bool imported;
  int get billingKey => _billingKey(chargeDate);
}

/// A purchase split into monthly payments, with the payments still to come.
class InstallmentPlan {
  InstallmentPlan(this.id, this.merchant, this.purchaseDate, this.total, this.count, this.payments, this.countsAsVariable);
  final String id;
  final String merchant;
  final DateTime purchaseDate;
  final double total;
  final int count;
  final List<InstallmentPayment> payments;
  final bool countsAsVariable;
}

/// One expected card charge of a purchase recorded by hand as "paid by card".
class ManualCardPayment {
  ManualCardPayment(this.transaction, this.number, this.of, this.amount, this.chargeDate);
  final MoneyTransaction transaction;
  final int number;
  final int of;
  final double amount;
  final DateTime chargeDate;
  String get title => transaction.title + (of > 1 ? ' (תשלום $number/$of)' : '');
  int get billingKey => _billingKey(chargeDate);
}

class Receivable {
  Receivable(this.json);
  final Json json;
  JObj get _o => JObj(json);
  bool get forgiven => _o.b('forgiven');
  List<String> get incomeIDs => ((_o.raw('incomeIDs') as List?) ?? const []).whereType<String>().toList();
  Map<String, dynamic> get transactionShares =>
      (_o.raw('transactionShares') as Map?)?.cast<String, dynamic>() ?? const {};
}

class CategoryAmount {
  CategoryAmount(this.name, this.amount);
  final String name;
  final double amount;
}

/// Port of `CardMonthSummary` (only what the month picture uses).
class CardMonthSummary {
  double variable = 0;
  double installments = 0;
  List<CategoryAmount> byCategory = [];

  static CardMonthSummary of(List<CardTransaction> txs) {
    final s = CardMonthSummary();
    final categories = <String, double>{};
    for (final t in txs) {
      if (t.ignored || t.linkedExpenseID != null || t.linkedTrackedID != null) continue;
      s.variable += t.myAmount;
      if (t.installment != null) {
        s.installments += t.myAmount;
      } else if (t.myAmount != 0) {
        final name = t.category.isEmpty ? 'שונות' : t.category;
        categories[name] = (categories[name] ?? 0) + t.myAmount;
      }
    }
    s.byCategory = categories.entries.map((e) => CategoryAmount(e.key, e.value)).toList()
      ..sort((a, b) => b.amount.compareTo(a.amount));
    return s;
  }
}

/// The card and "owed to me" calculations on one member's money data.
class CardData {
  CardData(this.money) {
    final raw = money.raw;
    cardTransactions = JObj(raw).objects('cardTransactions').map(CardTransaction.new).where((t) => t.id.isNotEmpty).toList();
    receivables = JObj(raw).objects('receivables').map(Receivable.new).toList();
  }

  final MoneyData money;
  late final List<CardTransaction> cardTransactions;
  late final List<Receivable> receivables;

  List<CardTransaction> chargedIn(int key) =>
      cardTransactions.where((t) => t.billingKey == key).toList()..sort((a, b) => b.date.compareTo(a.date));

  List<int> get cardBillingKeys =>
      (cardTransactions.map((t) => t.billingKey).whereType<int>().toSet().toList()..sort((a, b) => b.compareTo(a)));

  /// The usual day of the month the card is charged (e.g. 2).
  late final int? usualChargeDay = () {
    final counts = <int, int>{};
    for (final t in cardTransactions) {
      if (t.status == 'pending' || t.chargeEstimated || t.chargeDate == null) continue;
      counts[t.chargeDate!.day] = (counts[t.chargeDate!.day] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    final best = counts.values.reduce((a, b) => a > b ? a : b);
    return (counts.keys.where((d) => counts[d] == best).toList()..sort()).first;
  }();

  /// Billing months that contain the main statement (a charge on the usual charge day).
  late final List<int> cardStatementKeys = () {
    final day = usualChargeDay;
    if (day == null) return cardBillingKeys;
    final keys = <int>{};
    for (final t in cardTransactions) {
      final d = t.chargeDate;
      if (!t.chargeEstimated && d != null && d.day == day) keys.add(t.billingKey!);
    }
    return keys.toList()..sort((a, b) => b.compareTo(a));
  }();

  /// Average variable card spending per month, from the last (up to) 3 full statements.
  double averageCardVariable() {
    final keys = cardStatementKeys.take(3).toList();
    if (keys.isEmpty) return 0;
    var total = 0.0;
    for (final k in keys) {
      for (final t in chargedIn(k)) {
        if (t.isVariable && t.installment == null) total += t.myAmount;
      }
    }
    return total / keys.length;
  }

  late final List<InstallmentPlan> installmentPlans = () {
    final groups = <String, List<CardTransaction>>{};
    for (final t in cardTransactions.where((t) => t.installment != null)) {
      groups.putIfAbsent(t.installmentPlanKey, () => []).add(t);
    }
    final plans = <InstallmentPlan>[];
    groups.forEach((key, txs) {
      final known = [...txs]..sort((a, b) => a.installment!.number.compareTo(b.installment!.number));
      final first = known.first;
      final info = first.installment!;
      final payments = <InstallmentPayment>[
        for (final t in known)
          if (t.chargeDate != null) InstallmentPayment(t.installment!.number, t.chargeDate!, t.amount, true),
      ];
      // Payments not in any imported statement yet: one a month after the last known one.
      if (payments.isNotEmpty && payments.last.number < info.of) {
        final last = payments.last;
        final paid = payments.fold(0.0, (s, p) => s + p.amount);
        final left = info.of - last.number;
        for (var k = 1; k <= left; k++) {
          final isLast = k == left;
          var amount = isLast ? first.originalAmount - paid - last.amount * (left - 1) : last.amount;
          if (amount < 0) amount = 0;
          payments.add(InstallmentPayment(last.number + k, addMonths(last.chargeDate, k), amount > 0 ? amount : last.amount, false));
        }
      }
      final reference = known.last;
      plans.add(InstallmentPlan(
        key,
        first.merchant,
        first.date,
        first.originalAmount != 0 ? first.originalAmount : payments.fold(0.0, (s, p) => s + p.amount),
        info.of,
        payments,
        reference.isVariable,
      ));
    });
    plans.sort((a, b) => b.purchaseDate.compareTo(a.purchaseDate));
    return plans;
  }();

  /// The card charge that is this hand-recorded purchase (same price, a few days apart), if it was imported.
  CardTransaction? cardMatch(MoneyTransaction t) {
    if (t.kind != TransactionKind.expense || t.amount <= 0) return null;
    final candidates = cardTransactions.where((c) {
      if (c.ignored || c.amount <= 0) return false;
      final price = c.originalAmount != 0 ? c.originalAmount.abs() : c.amount;
      return (price - t.amount).abs() < 1 && c.date.difference(t.date).inSeconds.abs() <= 4 * 86400;
    }).toList();
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final da = a.date.difference(t.date).inMicroseconds.abs(), db = b.date.difference(t.date).inMicroseconds.abs();
      if (da != db) return da.compareTo(db);
      return (a.installment?.number ?? 1).compareTo(b.installment?.number ?? 1);
    });
    return candidates.first;
  }

  /// Hand-recorded card purchases' expected charges: the first on the next charge day after the purchase month.
  late final List<ManualCardPayment> manualCardPayments = () {
    final day = usualChargeDay ?? 2;
    final result = <ManualCardPayment>[];
    for (final t in money.transactions) {
      final isCardPurchase = t.kind == TransactionKind.expense && t.paidByCard;
      if (!isCardPurchase || t.amount <= 0 || cardMatch(t) != null) continue;
      final n = t.cardInstallments < 1 ? 1 : t.cardInstallments;
      final each = (t.amount / n * 100).round() / 100;
      final monthStart = DateTime(t.date.year, t.date.month);
      for (var i = 0; i < n; i++) {
        final month = addMonths(monthStart, i + 1);
        final charge = DateTime(month.year, month.month, day < 28 ? day : 28);
        final amount = i == n - 1 ? t.amount - each * (n - 1) : each;
        result.add(ManualCardPayment(t, i + 1, n, amount, charge));
      }
    }
    return result;
  }();

  /// An expense recorded from the bank account that looks like a card purchase already in the statements.
  bool looksLikeCardPurchase(MoneyTransaction t) =>
      t.kind == TransactionKind.expense && !t.paidByCard && t.salaryKey == null && cardMatch(t) != null;

  /// Income transactions that are someone paying you back — not real income.
  late final Set<String> reimbursementIncomeIDs = {for (final r in receivables) ...r.incomeIDs};

  /// The part of an expense transaction someone else owes you.
  double owedPortion(String transactionId) => receivables
      .where((r) => !r.forgiven)
      .fold(0.0, (s, r) => s + ((r.transactionShares[transactionId] as num?)?.toDouble() ?? 0));
}
