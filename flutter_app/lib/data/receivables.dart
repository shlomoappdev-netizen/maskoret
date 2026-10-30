import 'dart:math' as math;

import 'card.dart';
import 'json.dart';
import 'max_import.dart';
import 'models.dart';

/// Someone and what they still owe (Debtor in Receivables.swift).
class Debtor {
  Debtor(this.person, this.amount);
  final String person;
  final double amount;
}

/// The calculations of the MoneyData extension in Receivables.swift.
extension ReceivableCalc on CardData {
  double returned(Receivable r, List<MoneyTransaction> transactions) {
    final incomes = transactions.where((t) => r.incomeIDs.contains(t.id)).fold(0.0, (s, t) => s + t.amount);
    final credits = cardTransactions.where((t) => r.cardCreditIDs.contains(t.id)).fold(0.0, (s, t) => s + t.amount.abs());
    return incomes + credits + r.returns.fold(0.0, (s, e) => s + ((e['amount'] as num?)?.toDouble() ?? 0));
  }

  double outstanding(Receivable r, List<MoneyTransaction> transactions) =>
      r.forgiven ? 0 : math.max(0, r.expected - returned(r, transactions));

  double totalOwedToMe(List<MoneyTransaction> transactions) =>
      receivables.fold(0.0, (s, r) => s + outstanding(r, transactions));

  /// Everyone you lent to, with what they still owe, the most first.
  List<Debtor> debtors(List<MoneyTransaction> transactions) {
    final grouped = <String, double>{};
    for (final r in receivables) {
      final name = r.person.trim();
      grouped[name] = (grouped[name] ?? 0) + outstanding(r, transactions);
    }
    return [for (final e in grouped.entries) Debtor(e.key, e.value)]..sort((a, b) => b.amount.compareTo(a.amount));
  }

  List<String> get people => ({for (final r in receivables) if (r.person.isNotEmpty) r.person}.toList()..sort());
}

/// The Store actions of Receivables.swift, on one member's data.
class ReceivableActions {
  ReceivableActions(this.file);
  final SaveFile file;

  JObj get _money => JObj.lazy(file.json, 'money');

  static Json create({String person = '', String note = ''}) => {
        'id': newId(),
        'person': person,
        'note': note,
        'createdAt': dateTimeToSwift(DateTime.now()),
        'cardShares': <String, dynamic>{},
        'transactionShares': <String, dynamic>{},
        'manualAmount': 0,
        'incomeIDs': <dynamic>[],
        'cardCreditIDs': <dynamic>[],
        'returns': <dynamic>[],
        'forgiven': false,
      };

  static Json returnEntry({required DateTime date, required double amount, String note = ''}) =>
      {'id': newId(), 'date': dateTimeToSwift(date), 'amount': jsonNumber(amount), 'note': note};

  void upsert(Json r) {
    _money.upsertById('receivables', r);
    CardActions(file).syncOwedPortions();
  }

  void delete(String id) {
    _money.removeWhere('receivables', (r) => r['id'] == id);
    CardActions(file).syncOwedPortions();
  }

  /// Adds a card charge to the open debt of `person` (or a new one).
  void addCardToReceivable(CardTransaction tx, {required String person, required double amount, required String note}) {
    final name = person.trim();
    final cards = CardData(file.money);
    final transactions = file.money.transactions;
    final open = cards.receivables
        .where((r) => r.person == name && !r.forgiven && cards.outstanding(r, transactions) > 0)
        .firstOrNull;
    final r = open == null ? create(person: name, note: note) : deepCopy(open.json) as Json;
    ((r['cardShares'] ??= <String, dynamic>{}) as Map)[tx.id] = jsonNumber(amount);
    if ((r['note'] as String? ?? '').isEmpty) r['note'] = note;
    upsert(r);
  }

  void removeCardFromReceivables(String txID) {
    for (final r in _money.objects('receivables')) {
      (r['cardShares'] as Map?)?.remove(txID);
      (r['cardCreditIDs'] as List?)?.remove(txID);
    }
    _money.removeWhere('receivables', (j) {
      final r = Receivable(j);
      return r.expected == 0 && r.returns.isEmpty && r.incomeIDs.isEmpty;
    });
    CardActions(file).syncOwedPortions();
  }

  /// An income of `amount` into the checking account, "החזר מ…" — its id.
  String addReturnIncome(String person, Json entry) {
    final checking = file.money.ensureChecking();
    final note = entry['note'] as String? ?? '';
    final t = MoneyTransaction.create(kind: TransactionKind.income, accountID: checking.id)
      ..['date'] = entry['date']
      ..['title'] = 'החזר מ$person${note.isEmpty ? '' : ' — $note'}'
      ..['amount'] = entry['amount'];
    file.money.upsertTransaction(t);
    return t['id'] as String;
  }

  /// Links an income transaction as a payment on a debt (null = a regular income again).
  void linkIncome(String txID, String? receivableID) {
    for (final r in _money.objects('receivables')) {
      (r['incomeIDs'] as List?)?.remove(txID);
    }
    if (receivableID == null) return;
    final r = _money.objects('receivables').where((r) => r['id'] == receivableID).firstOrNull;
    if (r != null) ((r['incomeIDs'] ??= <dynamic>[]) as List).add(txID);
  }
}
