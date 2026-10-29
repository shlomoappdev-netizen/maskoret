@Tags(['swift'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/data/card.dart';
import 'package:maskoret/data/forecast.dart';
import 'package:maskoret/data/json.dart';
import 'package:maskoret/data/max_import.dart';
import 'package:maskoret/data/models.dart';
import 'package:maskoret/data/money_calc.dart';
import 'package:maskoret/data/month_picture.dart';

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
      Map<String, dynamic> pic(MonthPicture p, {bool record = false}) => {
            'key': p.year * 100 + p.month,
            if (record) 'record': true,
            'remaining': p.remaining,
            'net': p.net,
            'spending': p.spendingTotal,
            'periodic': p.periodic,
            'toSavings': p.toSavingsTotal,
            'card': p.cardTotal,
            'installments': p.installmentsTotal,
            'oneOffs': p.oneOffTotal,
            'installmentsAfter': p.installmentsAfterThisMonth,
            'cardEstimated': p.cardEstimated,
          };
      final months = <Map<String, dynamic>>[
        for (var o = -3; o <= 2; o++)
          pic(MonthPicture.of(f, addMonths(now, o).year, addMonths(now, o).month)),
        for (final r in f.history)
          pic(MonthPicture.of(f, r.year, r.month, budgetOverride: Budget(JObj(r.json['budget'] as Json))), record: true),
      ];
      final cards = CardData(money);
      final cardInfo = {
        'months': [
          for (final key in cards.cardBillingKeys)
            () {
              final c = CardMonthSummary.of(cards.chargedIn(key));
              return {
                'key': key, 'total': c.total, 'fixedLinked': c.fixedLinked, 'trackedLinked': c.trackedLinked,
                'variable': c.variable, 'pending': c.pending, 'owed': c.owed, 'installments': c.installments,
                'ignored': c.ignored, 'count': c.count,
              };
            }(),
        ],
        'average': cards.averageCardVariable(),
        'usualDay': cards.usualChargeDay ?? 0,
        'statementKeys': cards.cardStatementKeys,
        'plans': [
          for (final p in cards.installmentPlans)
            {
              'id': p.id, 'total': p.total, 'count': p.count, 'payments': p.payments.map((x) => x.amount).toList(),
              'keys': p.payments.map((x) => x.billingKey).toList(), 'variable': p.countsAsVariable,
            },
        ],
        'manual': [for (final p in cards.manualCardPayments) {'amount': p.amount, 'key': p.billingKey}],
      };
      files[m.id] = {
        'forecast': [
          for (final x in Forecaster.run(f, months: 24, now: now))
            {
              'index': x.index, 'checking': x.checking, 'savings': x.savings, 'pension': x.pension, 'card': x.card,
              'spending': x.spending, 'toSavings': x.toSavings, 'income': x.income, 'events': x.events.length,
            },
        ],
        'expectedNet': Forecaster.expectedNet(b, f.history, ForecastSettings(JObj.lazy(JObj.lazy(f.json, 'money').readMap ?? {}, 'forecast'))).amount,
        'card': cardInfo,
        'months': months,
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

  /// Numbers within a cent, lists in the same order (plans are compared by id).
  void deepClose(dynamic d, dynamic s, String path) {
    if (d is Map) {
      for (final k in d.keys) {
        deepClose(d[k], (s as Map)[k], '$path.$k');
      }
    } else if (d is List) {
      var sl = s as List;
      if (path.endsWith('plans')) {
        sl = [for (final p in d) sl.firstWhere((x) => x['id'] == p['id'], orElse: () => fail('$path: plan ${p['id']} missing'))];
      }
      expect(sl.length, d.length, reason: '$path length');
      for (var i = 0; i < d.length; i++) {
        deepClose(d[i], sl[i], '$path[$i]');
      }
    } else if (d is num) {
      expect((s as num).toDouble(), closeTo(d.toDouble(), 0.01), reason: path);
    } else {
      expect(s, d, reason: path);
    }
  }

  void compare(Json doc) {
    final now = DateTime.now();
    final s = swift(doc, now)['files'] as Map<String, dynamic>;
    final d = dart(doc, now);
    for (final id in d.keys) {
      for (final k in (d[id] as Map).keys) {
        final dv = d[id][k];
        final sv = s[id][k];
        if (k == 'card' || k == 'forecast') {
          deepClose(dv, sv, 'card');
        } else if (k == 'months') {
          final sm = sv as List;
          expect(sm.length, (dv as List).length, reason: 'months');
          for (var i = 0; i < dv.length; i++) {
            for (final mk in (dv[i] as Map).keys) {
              final a = dv[i][mk], b = sm[i][mk];
              final reason = 'month ${dv[i]['key']}${dv[i]['record'] == true ? ' (saved)' : ''} $mk';
              if (a is bool) {
                expect(b, a, reason: reason);
              } else {
                expect((b as num).toDouble(), closeTo((a as num).toDouble(), 0.01), reason: reason);
              }
            }
          }
        } else if (dv is List) {
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

  test('after importing a Max statement, Swift reads it and calculates the same (card, installments, month)', () {
    final doc = loadFixture();
    final family = FamilyBackup(doc);
    final file = family.fileForEditing(family.state.activeID);
    CardActions(file).importFile(File('test/fixtures/max_sample.xlsx').readAsBytesSync(), 'max_sample.xlsx');
    CardActions(file).linkToExpense(CardData(file.money).cardTransactions.firstWhere((t) => t.merchant == 'חברת החשמל').id,
        file.budget.expenses.first.id);
    compare(doc);
  }, skip: canRun ? false : 'needs swiftc (macOS)');
}
