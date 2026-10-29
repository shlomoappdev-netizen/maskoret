import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/data/json.dart';
import 'package:maskoret/data/models.dart';
import 'package:maskoret/data/money_calc.dart';

/// A real household document written by the Swift app (anonymized by tool/make_fixture.py).
Json loadFixture() =>
    (jsonDecode(File('test/fixtures/swift_household.json').readAsStringSync()) as Map).cast<String, dynamic>();

/// Paths where two JSON values differ (numbers compare by value: 5000 == 5000.0).
List<String> diff(dynamic a, dynamic b, [String path = '']) {
  if (a is Map && b is Map) {
    final out = <String>[];
    for (final k in {...a.keys, ...b.keys}) {
      if (!a.containsKey(k) || !b.containsKey(k)) {
        out.add('$path/$k');
      } else {
        out.addAll(diff(a[k], b[k], '$path/$k'));
      }
    }
    return out;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return ['$path[len ${a.length}≠${b.length}]'];
    return [for (var i = 0; i < a.length; i++) ...diff(a[i], b[i], '$path[$i]')];
  }
  if (a is num && b is num) return a == b ? [] : [path];
  return a == b ? [] : [path];
}

void main() {
  late Json original;
  late Json doc;
  late FamilyBackup family;
  late SaveFile file;

  setUp(() {
    original = loadFixture();
    doc = deepCopy(original) as Json;
    family = FamilyBackup(doc);
    file = family.fileForEditing(family.state.activeID);
  });

  /// What would be sent to the server: encoded and decoded again (as Postgres jsonb would keep it).
  Json sent() => (jsonDecode(jsonEncode(doc)) as Map).cast<String, dynamic>();

  test('the fixture really has data from screens this app does not have yet', () {
    final money = file.json['money'] as Map;
    for (final k in ['cardTransactions', 'merchantRules', 'cardImports', 'trends', 'maaser', 'receivables']) {
      expect(money.containsKey(k), isTrue, reason: k);
    }
    expect((money['cardTransactions'] as List), isNotEmpty);
    expect(file.history, isNotEmpty);
  });

  test('reading everything and writing back gives exactly the same JSON', () {
    // Touch every getter and calculation the app uses.
    final b = file.budget;
    b.gross;
    b.net;
    b.remaining;
    b.totalDeductions;
    for (final d in b.deductions) {
      b.deductionAmount(d);
    }
    b.taxSettings.creditPoints;
    final m = file.money;
    final calc = MoneyCalc(m.primeRate);
    for (final a in m.accounts) {
      calc.value(a, DateTime.now(), m.transactions);
      a.latestBalance;
    }
    for (final t in m.transactions) {
      t.effectOn(m.accounts.first.id);
      t.isPlanned;
    }
    file.history.map((r) => r.actualNet).toList();
    expect(diff(original, sent()), isEmpty);
  });

  test('editing an income changes only that field', () {
    final income = file.budget.incomes.first;
    income.amount = income.amount + 123.45;
    final changed = diff(original, sent());
    final index = (file.json['budget']['incomes'] as List).indexOf(income.json);
    expect(changed, ['/files/${family.state.activeID}/budget/incomes[$index]/amount']);
  });

  test('many edits on every screen keep all the other data', () {
    final b = file.budget;
    final m = file.money;
    // Incomes
    b.upsertIncome(IncomeItem.create(name: 'בונוס')..['amount'] = 1500);
    // Deductions & tax settings
    b.taxSettings.creditPoints = 2.75;
    final ded = CostItem.create(name: 'ועד עובדים', value: 50);
    b.upsertDeduction(ded);
    b.removeDeduction(ded['id'] as String);
    // Fixed expenses
    final exp = b.expenses.first;
    exp.value = exp.value + 10;
    // Accounts
    final acc = m.accounts.first;
    acc.upsertBalance(BalanceEntry.create(date: DateTime(2026, 10, 1), amount: 4321.5));
    final newAcc = Account.create(name: 'חיסכון לרכב', kind: AccountKind.savings)..['annualRate'] = 3.5;
    m.upsertAccount(newAcc);
    // Transactions
    final t = MoneyTransaction.create(accountID: acc.id)
      ..['title'] = 'מקרר'
      ..['amount'] = 3200;
    m.upsertTransaction(t);
    // Monthly record (summary → "save the month")
    file.upsertRecord({
      'id': newId(),
      'year': 2026,
      'month': 10,
      'note': '',
      'budget': deepCopy(file.json['budget']),
      'savedAt': dateTimeToSwift(DateTime.now()),
    });

    final now = sent();
    final before = original['files'][family.state.activeID] as Map;
    final after = now['files'][family.state.activeID] as Map;
    // Everything that belongs to screens not built yet is identical.
    for (final k in ['cardTransactions', 'merchantRules', 'cardImports', 'trends', 'maaser', 'receivables',
        'forecast', 'primeRate', 'primeAuto', 'boiRate', 'primeCheckedAt', 'nextRateDecision']) {
      expect(diff(before['money'][k], after['money'][k]), isEmpty, reason: k);
    }
    expect(diff(before['budget']['trackedItems'], after['budget']['trackedItems']), isEmpty);
    expect(diff(before['budget']['rates'], after['budget']['rates']), isEmpty);
    expect(diff(original['state'], now['state']), isEmpty);
    // The old history records are all there, unchanged.
    final oldHistory = before['history'] as List;
    for (var i = 0; i < oldHistory.length; i++) {
      final match = (after['history'] as List).firstWhere((r) => r['id'] == oldHistory[i]['id']);
      expect(diff(oldHistory[i], match), isEmpty);
    }
    // Existing accounts keep their unknown/unedited fields; old transactions are untouched.
    final oldTx = before['money']['transactions'] as List;
    for (final o in oldTx) {
      final match = (after['money']['transactions'] as List).firstWhere((r) => r['id'] == o['id']);
      expect(diff(o, match), isEmpty);
    }
    // Only these paths changed in the edited expense.
    final ei = (before['budget']['expenses'] as List).indexWhere((e) => e['id'] == exp.id);
    expect(diff(before['budget']['expenses'][ei], after['budget']['expenses'][ei]), ['/value']);
  });

  test('new objects are written like Swift writes them', () {
    final t = MoneyTransaction.create(accountID: 'A');
    expect(t.keys.toSet(), {'id', 'date', 'title', 'amount', 'kind', 'accountID', 'note', 'paidByCard', 'cardInstallments'});
    expect(t['id'], matches(RegExp(r'^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$')));
    expect(t['date'], isA<num>());
    // Clearing an optional removes the key (Swift leaves nil out).
    final tx = MoneyTransaction(t)..accountID = null;
    expect(t.containsKey('accountID'), isFalse);
    expect(tx.accountID, isNull);
    // Whole doubles are written as integers, like Swift.
    final i = IncomeItem(IncomeItem.create())..amount = 5000.0;
    expect(jsonEncode(i.json['amount']), '5000');
  });

  test('dates are seconds since 2001-01-01', () {
    expect(dateTimeToSwift(DateTime.utc(2001, 1, 1)), 0);
    expect(swiftDateToDateTime(0).toUtc(), DateTime.utc(2001, 1, 1));
    final d = DateTime.utc(2026, 10, 28, 12, 30, 15, 250);
    expect(swiftDateToDateTime(dateTimeToSwift(d)).toUtc(), d);
    expect(dateTimeToSwift(DateTime.utc(2026, 10, 28)), 814838400);
  });

  test('a new household is a valid FamilyBackup', () {
    final f = FamilyBackup(Starter.family());
    final id = f.state.primaryID;
    expect(f.state.members.single.name, 'אני');
    expect(f.file(id), isNotNull);
    expect(f.file(id)!.budget.deductions.length, 4);
    expect(f.file(id)!.money.checking, isNotNull);
  });
}
