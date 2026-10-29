@Tags(['swift'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/data/json.dart';
import 'package:maskoret/data/models.dart';
import 'package:maskoret/data/money_calc.dart';

import 'compat_test.dart' show loadFixture;

/// Runs the Swift app's own decoders and calculations (tool/swift_check.sh) on JSON written by this app.
/// Only on a Mac with Xcode; skipped elsewhere (e.g. on the Windows build machine).
void main() {
  final canRun = Platform.isMacOS && Process.runSync('which', ['swiftc']).exitCode == 0;

  Map<String, dynamic> swift(Json doc, DateTime now) {
    final f = File('${Directory.systemTemp.createTempSync('swift_check').path}/doc.json')
      ..writeAsStringSync(jsonEncode(doc));
    final r = Process.runSync('tool/swift_check.sh', [f.path, '${dateTimeToSwift(now)}']);
    if (r.exitCode != 0) fail('Swift could not read the JSON:\n${r.stdout}\n${r.stderr}');
    return jsonDecode((r.stdout as String).trim().split('\n').last) as Map<String, dynamic>;
  }

  Map<String, dynamic> dart(Json doc, DateTime now) {
    final family = FamilyBackup(doc);
    final files = <String, dynamic>{};
    for (final m in family.state.members) {
      final f = family.file(m.id)!;
      final b = f.budget;
      final money = f.money;
      final calc = MoneyCalc(money.primeRate);
      files[m.id] = {
        'gross': b.gross,
        'net': b.net,
        'totalDeductions': b.totalDeductions,
        'totalExpenses': b.totalExpenses,
        'periodicTotal': b.periodicTotal,
        'remaining': b.remaining,
        'deductions': b.deductions.map(b.deductionAmount).toList(),
        'accounts': money.accounts.map((a) => calc.value(a, now, money.transactions)).toList(),
      };
    }
    return files;
  }

  void compare(Json doc) {
    final now = DateTime.now();
    final s = swift(doc, now)['files'] as Map<String, dynamic>;
    final d = dart(doc, now);
    for (final id in d.keys) {
      for (final k in (d[id] as Map).keys) {
        final dv = d[id][k];
        final sv = s[id][k];
        if (dv is List) {
          expect((sv as List).length, dv.length, reason: k);
          for (var i = 0; i < dv.length; i++) {
            expect((sv[i] as num).toDouble(), closeTo((dv[i] as num).toDouble(), 0.01), reason: '$k[$i]');
          }
        } else {
          expect((sv as num).toDouble(), closeTo((dv as num).toDouble(), 0.01), reason: k);
        }
      }
    }
  }

  test('the Swift app reads the real data, and calculates the same as this app', () {
    compare(loadFixture());
  }, skip: canRun ? false : 'needs swiftc (macOS)');

  test('after edits on every screen, Swift still reads everything (money is not dropped) and agrees', () {
    final doc = loadFixture();
    final family = FamilyBackup(doc);
    final file = family.fileForEditing(family.state.activeID);
    final b = file.budget;
    final m = file.money;
    b.upsertIncome(IncomeItem.create(name: 'משכורת')..['amount'] = 15300.5);
    b.upsertIncome(IncomeItem.create(name: 'שעות נוספות')
      ..['kind'] = 'hourly'
      ..['hours'] = 12.5
      ..['hourlyRate'] = 80);
    for (final t in AutoDeduction.values) {
      if (!b.hasAuto(t)) b.upsertDeduction(CostItem.automatic(t));
    }
    b.upsertDeduction(CostItem.create(name: 'ועד', kind: CostKind.percent, value: 0.5));
    b.taxSettings.creditPoints = 2.75;
    b.taxSettings.pensionMode = PensionMode.startsLater;
    b.taxSettings.pensionStart = DateTime(2026, 1, 1);
    b.upsertExpense(CostItem.create(name: 'חיסכון', kind: CostKind.percent, value: 7.5)
      ..['targetAccountID'] = m.accounts.last.id);
    final checking = m.ensureChecking();
    checking.upsertBalance(BalanceEntry.create(date: DateTime(2026, 9, 1), amount: 10000));
    final dep = Account.create(name: 'פיקדון', kind: AccountKind.deposit)
      ..['annualRate'] = 4.2
      ..['compounding'] = 'monthly'
      ..['monthlyContribution'] = 500
      ..['contributionDay'] = 10
      ..['startDate'] = dateTimeToSwift(DateTime(2026, 3, 10))
      ..['maturityDate'] = dateTimeToSwift(DateTime(2028, 3, 10));
    (dep['balances'] as List).add(BalanceEntry.create(date: DateTime(2026, 4, 1), amount: 20000));
    m.upsertAccount(dep);
    final prime = Account.create(name: 'פריים', kind: AccountKind.savings)
      ..['rateType'] = 'prime'
      ..['primeMinus'] = 1.25;
    (prime['balances'] as List).add(BalanceEntry.create(date: DateTime(2026, 6, 15), amount: 3000));
    m.upsertAccount(prime);
    m.upsertTransaction(MoneyTransaction.create(accountID: checking.id)
      ..['amount'] = 1200.75
      ..['date'] = dateTimeToSwift(DateTime(2026, 10, 2)));
    m.upsertTransaction(MoneyTransaction.create(kind: TransactionKind.transfer, accountID: checking.id)
      ..['toAccountID'] = prime['id']
      ..['amount'] = 2000
      ..['date'] = dateTimeToSwift(DateTime(2026, 10, 5)));
    m.upsertTransaction(MoneyTransaction.create(accountID: checking.id)
      ..['amount'] = 900
      ..['paidByCard'] = true
      ..['cardInstallments'] = 3);
    file.upsertRecord({
      'id': newId(),
      'year': 2026,
      'month': 10,
      'note': 'בדיקה',
      'budget': deepCopy(file.json['budget']),
      'savedAt': dateTimeToSwift(DateTime.now()),
      'actualNet': 11000.4,
    });

    final now = DateTime.now();
    final s = swift(doc, now)['files'][family.state.activeID] as Map;
    expect(s['transactions'], m.transactions.length);
    expect(s['cardTransactions'], 38, reason: 'card data must survive');
    expect(s['trends'], 3);
    expect(s['receivables'], 1);
    expect(s['history'], 2);
    compare(doc);
    expect(b.totalDeductions, greaterThan(1000));
  }, skip: canRun ? false : 'needs swiftc (macOS)');

  test('a new household made by this app is read by Swift', () {
    final doc = Starter.family();
    final f = FamilyBackup(doc).file(FamilyBackup(doc).state.primaryID)!;
    f.budget.incomes.first.amount = 9000;
    compare(doc);
  }, skip: canRun ? false : 'needs swiftc (macOS)');
}
