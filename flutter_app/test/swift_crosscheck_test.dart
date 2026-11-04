@Tags(['swift'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/data/card.dart';
import 'package:maskoret/data/dashboard.dart';
import 'package:maskoret/data/family.dart';
import 'package:maskoret/data/forecast.dart';
import 'package:maskoret/data/maaser.dart';
import 'package:maskoret/data/receivables.dart';
import 'package:maskoret/data/trends.dart';
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
            if (!record) ...{
              'suspects': p.fixedInCardSuspects,
              'cardLines': [for (final l in p.card) l.amount],
              'startDays': dateTimeToSwift(p.periodStart!) / 86400,
              'endDays': dateTimeToSwift(p.periodEnd!) / 86400,
            },
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
      final ms = MaaserCalc.status(f, now: now);
      files[m.id] = {
        'tracked': [
          for (final t in b.trackedItems)
            {
              'monthly': t.monthlyCost, 'life': t.averageLifespan ?? -1, 'price': t.averagePrice, 'total': t.totalSpent,
              'measured': t.isLifespanMeasured, 'age': t.ageMonths() ?? -1, 'wear': t.wear() ?? -1,
              'nextDays': t.nextReplacement == null ? 0 : dateTimeToSwift(t.nextReplacement!) / 86400,
              'lasted': [for (final p in t.sortedPurchases) t.lasted(p) ?? -1],
            },
        ],
        'trends': [
          for (final t in JObj(money.raw).objects('trends').map(Trend.new))
            () {
              final st = TrendCalc.stats(money, t, now: now);
              return {
                'total': st.total, 'count': st.count, 'this': st.thisMonth, 'last': st.lastMonth, 'avg': st.monthlyAverage,
                'keys': [for (final x in st.months) x.key], 'amounts': [for (final x in st.months) x.amount],
                'items': [for (final x in TrendCalc.items(money, t)) x.amount]..sort(),
              };
            }(),
        ],
        'owed': {
          'total': cards.totalOwedToMe(money.transactions),
          'each': [for (final r in cards.receivables) cards.outstanding(r, money.transactions)],
          'returned': [for (final r in cards.receivables) cards.returned(r, money.transactions)],
          'expected': [for (final r in cards.receivables) r.expected],
          'debtors': [for (final d in cards.debtors(money.transactions)) d.amount],
          'portions': [for (final t in cards.cardTransactions) t.owedPortion],
        },
        'maaser': {
          'balance': ms.balance, 'thisMonthOwed': ms.thisMonthOwed, 'thisMonthPaid': ms.thisMonthPaid,
          'paidThisYear': ms.paidThisYear, 'missing': ms.missingMonths,
          'months': [
            for (final x in ms.months)
              {
                'key': x.key, 'base': x.base ?? -1, 'salary': x.salaryBase, 'interest': x.interest, 'oneOffs': x.oneOffs,
                'deducted': x.deducted, 'owed': x.owed, 'paid': x.paid, 'balance': x.balance,
              },
          ],
        },
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
        'balances': money.accounts.map((a) => money.balance(a, now)).toList(),
        'autoBalances': money.accounts.map((a) => money.balance(a, now, b, f.history)).toList(),
        'statement': () {
          final until = DateTime(now.year, now.month, now.day + 35, now.hour, now.minute, now.second, now.millisecond);
          final lines = money.checkingStatement(until, b, f.history, now: now);
          // Lines of the same day and amount may come in either order: the titles, notes and kinds are compared as sets.
          return {
            'amounts': [for (final l in lines) l.amount],
            'balances': [for (final l in lines) l.balance],
            'elsewhere': [for (final l in lines) l.elsewhere ?? 0],
            'days': [for (final l in lines) (dateTimeToSwift(l.date) / 86400).truncate()],
            'titles': [for (final l in lines) l.title]..sort(),
            'notes': [for (final l in lines) l.note]..sort(),
            'sources': [for (final l in lines) l.source.name]..sort(),
          };
        }(),
        'periodNow': [money.period(now).$1, money.period(now).$2],
        'payDay': money.payDay,
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
        if (const {'card', 'forecast', 'maaser', 'owed', 'tracked', 'trends', 'statement'}.contains(k)) {
          deepClose(dv, sv, 'card');
        } else if (k == 'months') {
          final sm = sv as List;
          expect(sm.length, (dv as List).length, reason: 'months');
          for (var i = 0; i < dv.length; i++) {
            for (final mk in (dv[i] as Map).keys) {
              final a = dv[i][mk], b = sm[i][mk];
              final reason = 'month ${dv[i]['key']}${dv[i]['record'] == true ? ' (saved)' : ''} $mk';
              if (a is List) {
                deepClose(a, b, reason);
              } else if (a is bool) {
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
    expect(s['trendCount'], 3);
    expect(s['receivables'], 1);
    expect(s['history'], 2);
    compare(doc);
    expect(b.totalDeductions, greaterThan(1000));
  }, skip: canRun ? false : 'needs swiftc (macOS)');

  test('maaser: Swift calculates the same fund, month by month, for every base', () {
    for (final base in MaaserBase.values) {
      final doc = loadFixture();
      final family = FamilyBackup(doc);
      final file = family.fileForEditing(family.state.activeID);
      final now = DateTime.now();
      final b = file.budget;
      final charity = CostItem.create(name: 'צדקה', value: 150);
      final travel = CostItem.create(name: 'נסיעות', value: 320.5);
      b.upsertExpense(charity);
      b.upsertExpense(travel);
      for (var o = -4; o <= -1; o++) {
        final d = addMonths(now, o);
        if (o == -2) continue; // a month without the actual net
        file.upsertRecord({
          'id': newId(),
          'year': d.year,
          'month': d.month,
          'note': '',
          'budget': deepCopy(file.json['budget']),
          'savedAt': dateTimeToSwift(d),
          'actualNet': 11000.4 + o * 37,
        });
      }
      final m = MaaserSettings.of(file)
        ..enabled = true
        ..percent = 10
        ..base = base
        ..startKey = MaaserCalc.key(addMonths(now, -5))
        ..openingBalance = 250.75;
      m.toggle('maaserExpenseIDs', charity['id'] as String, true);
      m.toggle('deductedExpenseIDs', travel['id'] as String, true);
      final cards = CardData(file.money).cardTransactions;
      m.toggle('maaserMerchants', cards.first.merchantKey, true);
      m.toggle('maaserCardIDs', cards.last.id, true);
      MaaserCalc.addDonation(file, date: addMonths(now, -3), amount: 400, note: 'קופה', fromChecking: true);
      MaaserCalc.addDonation(file, date: now, amount: 99.9, fromChecking: false);
      final gift = MoneyTransaction.create(kind: TransactionKind.income, accountID: file.money.ensureChecking().id)
        ..['amount'] = 1800
        ..['date'] = dateTimeToSwift(DateTime(addMonths(now, -1).year, addMonths(now, -1).month, 3));
      file.money.upsertTransaction(gift);
      final status = MaaserCalc.status(file);
      expect(status.months.length, 6);
      expect(status.missingMonths, isNotEmpty);
      expect(status.months.where((x) => x.base != null && x.owed > 0).length, greaterThanOrEqualTo(3));
      expect(status.months.any((x) => x.oneOffs == 1800), isTrue);
      expect(status.months.any((x) => x.deducted > 0), isTrue);
      // The donations, plus the card charges marked as maaser (a pending one already charged is dropped as a duplicate).
      expect(status.months.fold(0.0, (s, x) => s + x.paid), greaterThan(400 + 99.9 + 150 * 5 - 0.01));
      compare(doc);
    }
  }, skip: canRun ? false : 'needs swiftc (macOS)');

  test('owed to me: Swift agrees on every debt, what came back, and the card portions', () {
    final doc = loadFixture();
    final family = FamilyBackup(doc);
    final file = family.fileForEditing(family.state.activeID);
    final actions = ReceivableActions(file);
    final charges = CardData(file.money).cardTransactions.where((t) => t.amount > 0).toList();
    final credit = CardData(file.money).cardTransactions.where((t) => t.amount < 0).firstOrNull;
    actions.addCardToReceivable(charges[0], person: 'דנה', amount: charges[0].amount / 2, note: 'הופעה');
    actions.addCardToReceivable(charges[1], person: 'דנה', amount: 40.5, note: '');
    actions.addCardToReceivable(charges[2], person: 'יוסי', amount: charges[2].amount + 100, note: 'יותר מהחיוב');
    final checking = file.money.ensureChecking();
    final expense = MoneyTransaction.create(accountID: checking.id)..['amount'] = 300;
    file.money.upsertTransaction(expense);
    final dana = CardData(file.money).receivables.firstWhere((r) => r.person == 'דנה');
    final edited = deepCopy(dana.json) as Json;
    (edited['transactionShares'] as Map)[expense['id']] = 120;
    edited['manualAmount'] = 55.25;
    (edited['returns'] as List).add(ReceivableActions.returnEntry(date: DateTime.now(), amount: 70, note: 'מזומן'));
    if (credit != null) (edited['cardCreditIDs'] as List).add(credit.id);
    actions.upsert(edited);
    final bit = actions.addReturnIncome('דנה', ReceivableActions.returnEntry(date: DateTime.now(), amount: 33.3, note: 'ביט'));
    actions.linkIncome(bit, edited['id'] as String);
    final forgiven = ReceivableActions.create(person: 'אבא')..['manualAmount'] = 500..['forgiven'] = true;
    actions.upsert(forgiven);
    final cards = CardData(file.money);
    expect(cards.receivables.length, greaterThanOrEqualTo(4));
    expect(cards.totalOwedToMe(file.money.transactions), greaterThan(0));
    expect(cards.cardTransactions.any((t) => t.owedPortion > 0), isTrue);
    compare(doc);
    actions.removeCardFromReceivables(charges[2].id);
    compare(doc);
  }, skip: canRun ? false : 'needs swiftc (macOS)');

  test('family: a member added, renamed and another deleted here is read by Swift with the same numbers', () {
    final doc = loadFixture();
    final family = FamilyBackup(doc);
    final source = family.fileForEditing(family.state.activeID);
    final actions = FamilyActions(family);
    final noa = actions.add(name: 'נועה', emoji: '👩', copyFrom: source);
    final shared = actions.add(name: 'משותף', emoji: '🏠', copyFrom: source);
    actions.update(noa, name: 'נועה כהן', emoji: '👩‍💼');
    final f = family.fileForEditing(noa);
    f.budget.upsertIncome(IncomeItem.create(name: 'משכורת')..['amount'] = 9800);
    for (final t in AutoDeduction.values) {
      if (!f.budget.hasAuto(t)) f.budget.upsertDeduction(CostItem.automatic(t));
    }
    expect(actions.delete(shared, shared), family.state.primaryID);
    expect(family.state.members.map((m) => m.id), isNot(contains(shared)));
    expect((doc['files'] as Map).containsKey(shared), isFalse);
    expect(actions.delete(family.state.primaryID, noa), noa, reason: 'the first member is never deleted');
    final s = swift(doc, DateTime.now())['files'] as Map<String, dynamic>;
    expect(s.keys, containsAll([family.state.primaryID, noa]));
    expect(s[noa]['net'], closeTo(f.budget.net, 0.01));
    compare(doc);
  }, skip: canRun ? false : 'needs swiftc (macOS)');

  test('together: Swift merges the family the same way (net per member, accounts, one card, actual months)', () {
    final doc = loadFixture();
    final family = FamilyBackup(doc);
    final primary = family.fileForEditing(family.state.activeID);
    final noaId = FamilyActions(family).add(name: 'נועה', emoji: '👩', copyFrom: primary);
    final noa = family.fileForEditing(noaId);
    noa.budget.upsertIncome(IncomeItem.create(name: 'משכורת')..['amount'] = 12400);
    for (final t in AutoDeduction.values) {
      if (!noa.budget.hasAuto(t)) noa.budget.upsertDeduction(CostItem.automatic(t));
    }
    noa.budget.upsertExpense(CostItem.create(name: 'גן', value: 2100));
    noa.budget.upsertExpense(CostItem.create(name: 'חיסכון', kind: CostKind.percent, value: 5));
    final checking = noa.money.ensureChecking();
    checking.upsertBalance(BalanceEntry.create(date: DateTime(2026, 9, 1), amount: 4300));
    // The same card charge imported by both members counts once.
    final shared = deepCopy(JObj(primary.money.raw).objects('cardTransactions').first) as Json;
    JObj.lazy(noa.json, 'money').writeList('cardTransactions').add(shared);
    final now = DateTime.now();
    for (final r in primary.history) {
      noa.upsertRecord({'id': newId(), 'year': r.year, 'month': r.month, 'note': '', 'budget': deepCopy(noa.json['budget']),
          'savedAt': dateTimeToSwift(now), 'actualNet': 9100.5});
    }
    final lonely = addMonths(now, -7);
    noa.upsertRecord({'id': newId(), 'year': lonely.year, 'month': lonely.month, 'note': '', 'budget': deepCopy(noa.json['budget']),
        'savedAt': dateTimeToSwift(now), 'actualNet': 8000});

    final parts = [for (final m in family.state.members) (m, family.file(m.id)!)];
    final c = Dashboard.combine(parts, family.file(family.state.activeID)!);
    final s = swift(doc, now)['combined'] as Map<String, dynamic>;
    expect(c.budget.net, closeTo(primary.budget.net + noa.budget.net, 0.01));
    final mine = {
      'net': c.budget.net,
      'totalExpenses': c.budget.totalExpenses,
      'periodicTotal': c.budget.periodicTotal,
      'accounts': [for (final a in c.money.accounts) c.money.balance(a, now)],
      'cards': CardData(c.money).cardTransactions.length,
      'owed': CardData(c.money).totalOwedToMe(c.money.transactions),
      'history': [for (final r in c.history..sort((a, b) => a.sortKey.compareTo(b.sortKey))) r.actualNet ?? -1],
      'expectedNet': Forecaster.expectedNet(c.budget, c.history, ForecastSettings.of(c)).amount,
      'months': [
        for (var o = -3; o <= 2; o++)
          () {
            final p = MonthPicture.of(c, addMonths(now, o).year, addMonths(now, o).month);
            return {
              'key': p.year * 100 + p.month, 'remaining': p.remaining, 'net': p.net, 'spending': p.spendingTotal,
              'periodic': p.periodic, 'toSavings': p.toSavingsTotal, 'card': p.cardTotal,
              'installments': p.installmentsTotal, 'oneOffs': p.oneOffTotal,
            };
          }(),
      ],
      'forecast': [
        for (final x in Forecaster.run(c, months: 12, now: now))
          {
            'index': x.index, 'checking': x.checking, 'savings': x.savings, 'pension': x.pension, 'card': x.card,
            'spending': x.spending, 'toSavings': x.toSavings, 'income': x.income,
          },
      ],
    };
    expect(mine['cards'], CardData(primary.money).cardTransactions.length, reason: 'the shared charge counts once');
    expect((mine['history'] as List).contains(-1), isTrue, reason: 'a month only one member recorded is not actual');
    deepClose(mine, s, 'combined');
  }, skip: canRun ? false : 'needs swiftc (macOS)');

  test('tracked items and trends: Swift calculates the same (lifespan, wear, shares, months, average)', () {
    final doc = loadFixture();
    final family = FamilyBackup(doc);
    final file = family.fileForEditing(family.state.activeID);
    final now = DateTime.now();
    final b = file.budget;
    final none = TrackedItem.create(name: 'בלי קניות', emoji: '👟', expectedMonths: 12);
    final one = TrackedItem.create(name: 'קנייה אחת', expectedMonths: 6.5);
    final many = TrackedItem.create(name: '', emoji: '📱');
    final off = TrackedItem.create(name: 'מחוץ ליתרה', expectedMonths: 3)..['includeInBudget'] = false;
    for (final t in [none, one, many, off]) {
      b.upsertTracked(t);
    }
    expect(TrackedItem(many).name, 'פריט');
    b.addPurchase(one['id'] as String, Purchase.create(date: addMonths(now, -2), price: 349.9, note: 'חנות'));
    b.addPurchase(off['id'] as String, Purchase.create(date: addMonths(now, -9), price: 120));
    for (final (back, price) in [(30, 2000.0), (3, 4150.5), (17, 2600.0)]) {
      b.addPurchase(many['id'] as String, Purchase.create(date: addMonths(now, -back), price: price));
    }
    final extra = Purchase.create(date: now, price: 1);
    b.addPurchase(one['id'] as String, extra);
    b.deletePurchase(one['id'] as String, extra['id'] as String);

    final actions = TrendActions(file);
    final trend = Trend.create(name: 'דייטים', emoji: '💕', monthlyLimit: 500);
    actions.upsert(trend);
    final id = trend['id'] as String;
    final cards = CardData(file.money).cardTransactions;
    actions.toggleCard(cards[0].id, id);
    actions.toggleCard(cards[1].id, id);
    actions.toggleCard(cards[2].id, id);
    actions.toggleCard(cards[2].id, id); // on and off again
    actions.setShare(cards[1].amount / 3, cards[1].id, id);
    final checking = file.money.ensureChecking();
    final spent = MoneyTransaction.create(accountID: checking.id)..['title'] = 'מסעדה'..['amount'] = 240.5..['date'] = dateTimeToSwift(addMonths(now, -1));
    final back = MoneyTransaction.create(kind: TransactionKind.income, accountID: checking.id)..['title'] = 'החזר'..['amount'] = 40..['date'] = dateTimeToSwift(now);
    file.money.upsertTransaction(spent);
    file.money.upsertTransaction(back);
    actions.toggleTransaction(spent['id'] as String, id);
    actions.toggleTransaction(back['id'] as String, id);
    actions.addEntry(id, date: addMonths(now, -8), amount: 75, note: 'מזומן');
    actions.addEntry(id, date: now, amount: 33.3);
    final st = TrendCalc.stats(file.money, Trend(trend));
    expect(st.count, 6);
    expect(st.months.length, 6);
    expect(TrendCalc.items(file.money, Trend(trend)).where((i) => i.fullAmount != null).length, 1);
    compare(doc);
  }, skip: canRun ? false : 'needs swiftc (macOS)');

  test('pay day: periods, purchases by date, the estimate and the deposits come out the same as Swift', () {
    for (final day in [10, 15, 31]) {
      final doc = loadFixture();
      final family = FamilyBackup(doc);
      final file = family.fileForEditing(family.state.activeID);
      final now = DateTime.now();
      file.money.payDay = day;
      final saving = Account.create(name: 'תוכנית', kind: AccountKind.savings)
        ..['monthlyContribution'] = 450
        ..['contributionDay'] = 12;
      (saving['balances'] as List).add(BalanceEntry.create(date: addMonths(now, -4), amount: 1000));
      file.money.upsertAccount(saving);
      file.money.ensureChecking().upsertBalance(BalanceEntry.create(date: addMonths(now, -3), amount: 9000));
      // A charge priced like a fixed expense, not linked: it may be counted twice.
      final expense = CostItem.create(name: 'חשמל', value: 300);
      file.budget.upsertExpense(expense);
      JObj.lazy(file.json, 'money').writeList('cardTransactions').add({
        ...deepCopy(JObj(file.money.raw).objects('cardTransactions').first) as Json,
        'id': 'test-suspect',
        'merchant': 'חברת החשמל',
        'amount': 300.4,
        'originalAmount': 300.4,
        'note': '',
        'date': dateTimeToSwift(now.subtract(const Duration(days: 1))),
        'ignored': false,
      }..remove('linkedExpenseID')..remove('linkedTrackedID'));
      expect(file.money.periodStart(2026, 2).day, day > 28 ? 28 : day);
      final bought = now.subtract(const Duration(days: 1));
      final (y, m) = file.money.period(bought);
      expect(MonthPicture.of(file, y, m).fixedInCardSuspects, contains('חברת החשמל'));
      compare(doc);
    }
  }, skip: canRun ? false : 'needs swiftc (macOS)');

  test('checking balance by itself: salary, fixed expenses on their day and the card come out the same as Swift', () {
    for (final (day, sinceMonths) in [(1, -4), (10, -2), (31, -6)]) {
      final doc = loadFixture();
      final family = FamilyBackup(doc);
      final file = family.fileForEditing(family.state.activeID);
      final now = DateTime.now();
      final money = file.money;
      money.payDay = day;
      money.autoBalanceSince = addMonths(now, sinceMonths);
      money.ensureChecking().upsertBalance(BalanceEntry.create(date: addMonths(now, -3), amount: 5000));
      final b = file.budget;
      b.upsertExpense(CostItem.create(name: 'ועד בית', value: 250)..['chargeDay'] = 5);
      b.upsertExpense(CostItem.create(name: 'ביטוח', value: 180)..['chargeDay'] = 31);
      b.upsertExpense(CostItem.create(name: 'חוג', kind: CostKind.percent, value: 2));
      b.upsertExpense(CostItem.create(name: 'כבוי', value: 999)..['chargeDay'] = 3..['isActive'] = false);
      // Last month's salary was recorded as a transaction: it isn't added again.
      final last = addMonths(now, -1);
      money.upsertTransaction(MoneyTransaction.create(kind: TransactionKind.income, accountID: money.checking!.id)
        ..['title'] = 'משכורת'
        ..['amount'] = 7000
        ..['salaryKey'] = last.year * 100 + last.month
        ..['date'] = dateTimeToSwift(money.periodStart(last.year, last.month)));
      // Two months ago the actual net was saved: that's what came in.
      final older = addMonths(now, -2);
      file.upsertRecord({
        'id': newId(),
        'year': older.year,
        'month': older.month,
        'note': '',
        'budget': deepCopy(file.json['budget']),
        'savedAt': dateTimeToSwift(now),
        'actualNet': 6543.21,
      });
      // Per-card settings (CardSetting): the imported card on its own day plus a delay, an amount typed in for this
      // month, and a card without statements with its usual monthly charge. The first round keeps no settings.
      if (day != 1) {
        final primary = CardData(money).primaryCard;
        final thisMonth = '${now.year * 100 + now.month}', lastMonth = '${last.year * 100 + last.month}';
        JObj.lazy(file.json, 'money').writeList('cardSettings').addAll([
          {'id': newId(), 'last4': primary, 'name': 'ויזה', 'chargeDay': 12, 'delayDays': 1, 'monthlyEstimate': 0},
          {'id': newId(), 'last4': '', 'name': 'כרטיס בלי קובץ', 'chargeDay': 20, 'delayDays': 0, 'monthlyEstimate': 450,
            'actualCharges': {lastMonth: 400}},
        ]);
        // Typed in through the app's own action, so Swift reads what this app writes.
        money.setActualCharge(primary, int.parse(thisMonth), 333.33);
        money.setActualCharge(primary, int.parse(lastMonth), 1.0);
        money.setActualCharge(primary, int.parse(lastMonth), null);
      }
      final checking = money.checking!;
      final auto = money.balance(checking, now, b, file.history);
      expect(auto, isNot(closeTo(money.balance(checking, now), 0.01)), reason: 'payDay $day: the estimate moved');
      // The statement's line for today ends at the same balance as "עו״ש עכשיו".
      final statement = money.checkingStatement(DateTime(now.year, now.month, now.day + 35), b, file.history, now: now);
      final today = statement.firstWhere((l) => !l.date.isAfter(now));
      expect(today.balance, closeTo(auto, 0.01), reason: 'payDay $day: the statement reaches the checking balance');
      compare(doc);
    }
  }, skip: canRun ? false : 'needs swiftc (macOS)');

  test('old "transfer to savings" expenses become deposits on the account, exactly like Swift', () {
    final doc = loadFixture();
    final family = FamilyBackup(doc);
    final file = family.fileForEditing(family.state.activeID);
    file.money.payDay = 31;
    final save = Account.create(name: 'חיסכון', kind: AccountKind.savings);
    final dep = Account.create(name: 'פיקדון', kind: AccountKind.deposit)..['monthlyContribution'] = 100..['contributionDay'] = 5;
    final pension = Account.create(name: 'פנסיה', kind: AccountKind.pension);
    for (final a in [save, dep, pension]) {
      file.money.upsertAccount(a);
    }
    final b = file.budget;
    b.upsertExpense(CostItem.create(name: 'לחיסכון', value: 250.555)..['targetAccountID'] = save['id']);
    b.upsertExpense(CostItem.create(name: 'לפיקדון אחוז', kind: CostKind.percent, value: 5)..['targetAccountID'] = dep['id']);
    b.upsertExpense(CostItem.create(name: 'כבוי', value: 999)..['targetAccountID'] = save['id']..['isActive'] = false);
    final keep = CostItem.create(name: 'לפנסיה', value: 70)..['targetAccountID'] = pension['id'];
    b.upsertExpense(keep);

    final dir = Directory.systemTemp.createTempSync('adopt');
    final path = '${dir.path}/h.json';
    File(path).writeAsStringSync(jsonEncode(doc));
    final out = Process.runSync('zsh', ['tool/swift_check.sh', 'adopt', path], stdoutEncoding: utf8);
    dir.deleteSync(recursive: true);
    expect(out.exitCode, 0, reason: '${out.stderr}');
    final s = (jsonDecode(out.stdout as String) as Map)[family.state.activeID] as Map;

    expect(file.money.adoptSavingsTransfers(b), isTrue);
    expect(s['changed'], isTrue);
    expect(b.expenses.map((e) => e.id).toList(), s['expenses']);
    expect(b.expenses.any((e) => e.id == keep['id']), isTrue, reason: 'a pension transfer stays');
    expect([for (final a in file.money.accounts) a.contributionDay], s['days']);
    deepClose([for (final a in file.money.accounts) a.monthlyContribution], s['contributions'], 'contributions');
    expect(file.money.adoptSavingsTransfers(b), isFalse, reason: 'runs once');
  }, skip: canRun ? false : 'needs swiftc (macOS)');

  test('a pending purchase already charged under a slightly different name goes, its links move — like Swift', () {
    final doc = loadFixture();
    final family = FamilyBackup(doc);
    final file = family.fileForEditing(family.state.activeID);
    final cards = JObj.lazy(file.json, 'money').writeList('cardTransactions');
    final charged = [for (final c in cards) if (c is Map && c['status'] == 'charged') c.cast<String, dynamic>()];
    final expenseID = file.budget.expenses.first.id;
    Json pendingOf(Json c, String id, String merchant, {int days = 1, double? amount}) => {
          ...deepCopy(c) as Json,
          'id': id,
          'status': 'pending',
          'merchant': merchant,
          'date': (c['date'] as num) + days * 86400,
          if (amount != null) 'originalAmount': amount,
        }..remove('linkedExpenseID')..remove('linkedTrackedID');
    // Made-up names: a company suffix and punctuation on the pending one, and a shorter name that is a prefix.
    charged[0]['merchant'] = 'א.מ. סיטי קאר רכב שיתופי';
    charged[1]['merchant'] = 'PAYBOX TEL AVIV IL';
    charged[2]['merchant'] = 'ABC';
    cards.addAll([
      pendingOf(charged[0], 'p-company', 'א.מ. סיטי קאר רכב שיתופי בע"מ')
        ..['linkedExpenseID'] = expenseID
        ..['owedPortion'] = 1.5,
      pendingOf(charged[1], 'p-prefix', 'PAYBOX', days: 3),
      pendingOf(charged[2], 'p-short', 'ABCDEF'), // under 6 letters: not the same merchant
      pendingOf(charged[3], 'p-far', charged[3]['merchant'] as String, days: 4), // too many days apart
      pendingOf(charged[4], 'p-amount', charged[4]['merchant'] as String, amount: 999), // another amount
    ]);
    final money = JObj.lazy(file.json, 'money');
    (money.objects('trends').first['cardIDs'] as List).addAll(['p-company', charged[0]['id']]);
    (money.objects('receivables').first['cardShares'] as Map)['p-prefix'] = 3.0;

    final dir = Directory.systemTemp.createTempSync('drop');
    final path = '${dir.path}/h.json';
    File(path).writeAsStringSync(jsonEncode(doc));
    final out = Process.runSync('zsh', ['tool/swift_check.sh', 'drop', path], stdoutEncoding: utf8);
    dir.deleteSync(recursive: true);
    expect(out.exitCode, 0, reason: '${out.stderr}');
    final s = (jsonDecode(out.stdout as String) as Map)[family.state.activeID] as Map;

    expect(file.money.dropConfirmedPending(), 2);
    expect(s['dropped'], 2);
    final dart = CardData(file.money);
    expect([for (final c in dart.cardTransactions) c.id], [for (final c in s['cards'] as List) c['id']]);
    expect([for (final c in dart.cardTransactions) c.linkedExpenseID ?? ''], [for (final c in s['cards'] as List) c['expense']]);
    deepClose([for (final c in dart.cardTransactions) c.owedPortion], [for (final c in s['cards'] as List) c['owed']], 'owed');
    expect([for (final t in money.objects('trends')) t['cardIDs']], s['trendCards']);
    expect([for (final r in money.objects('receivables')) ((r['cardShares'] as Map).keys.toList()..sort())], s['owedShares']);
    expect(file.money.dropConfirmedPending(), 0, reason: 'runs once');
  }, skip: canRun ? false : 'needs swiftc (macOS)');

  test('foreign-currency charges with no ₪ amount go to shekels at the saved rates, exactly like Swift', () {
    final doc = loadFixture();
    final family = FamilyBackup(doc);
    final file = family.fileForEditing(family.state.activeID);
    final cards = JObj.lazy(file.json, 'money').writeList('cardTransactions');
    final template = (cards.first as Map).cast<String, dynamic>();
    Json charge(String id, double amount, double original, String currency, DateTime date, {bool estimated = false}) => {
          ...deepCopy(template) as Json,
          'id': id,
          'date': dateTimeToSwift(date),
          'amount': amount,
          'originalAmount': original,
          'originalCurrency': currency,
          if (estimated) 'amountEstimated': true,
        }..remove('linkedExpenseID')..remove('linkedTrackedID');
    final d = DateTime(2026, 11, 2, 12), oct = DateTime(2026, 10, 15, 12), aug = DateTime(2026, 8, 1, 12);
    cards.addAll([
      charge('fx-pending', 10, 10, r'$', d), // pending in dollars: the foreign number was taken as shekels
      charge('fx-stale', 50, 20, 'EUR', d, estimated: true), // estimated at an old rate
      charge('fx-real', 37.2, 10, 'USD', d), // the statement already brought the ₪ charge: untouched
      charge('fx-yen', 1500, 1500, 'JPY', d), // a currency the rates know only after a check
      charge('fx-october', 10, 10, 'USD', oct), // the rate of its own day (the last saved one before it)
      charge('fx-august', 10, 10, 'USD', aug), // older than every saved day: today's rate
      charge('ils', 99.9, 99.9, '₪', d),
    ]);
    file.money.exchangeRates = {...MoneyData.fallbackRates, 'JPY': 0.019957};
    file.money.exchangeRateHistory = {
      '2026-10-01': {'USD': 3.7},
      '2026-10-20': {'USD': 3.9},
    };

    final dir = Directory.systemTemp.createTempSync('convert');
    final path = '${dir.path}/h.json';
    File(path).writeAsStringSync(jsonEncode(doc));
    final out = Process.runSync('zsh', ['tool/swift_check.sh', 'convert', path], stdoutEncoding: utf8);
    dir.deleteSync(recursive: true);
    expect(out.exitCode, 0, reason: '${out.stderr}');
    final s = (jsonDecode(out.stdout as String) as Map)[family.state.activeID] as Map;

    final first = file.money.convertForeignCharges();
    expect(first, s['first']);
    expect(file.money.convertForeignCharges(), 0, reason: 'runs once');
    expect(s['second'], 0);
    expect(s['roundTrip'], isTrue, reason: 'Swift keeps the flag when it saves');
    final txs = CardData(file.money).cardTransactions;
    deepClose([for (final t in txs) t.amount], s['amounts'], 'amounts');
    expect([for (final t in txs) t.amountEstimated], s['estimated']);
    final byId = {for (final t in txs) t.id: t};
    expect(byId['fx-stale']!.amount, 70.61);
    expect(byId['fx-real']!.amount, 37.2);
    expect(byId['fx-real']!.amountEstimated, isFalse);
    expect(byId['fx-yen']!.amount, 29.94);
    expect(byId['fx-october']!.amount, 37.0);
    expect(byId['fx-august']!.amount, 31.57);
    expect(byId['fx-pending']!.amount, 39.0, reason: 'the last saved day before November 2 is October 20');
    expect(byId['ils']!.amount, 99.9);
  }, skip: canRun ? false : 'needs swiftc (macOS)');

  test('the rate of the transaction day: 01.11 → 3.10, 02.11 (no rate) → 01.11, 03.11 → 3.157, 20.10 → today', () {
    final family = FamilyBackup(loadFixture());
    final file = family.fileForEditing(family.state.activeID);
    final money = file.money
      ..exchangeRates = {'USD': 3.2}
      ..exchangeRateHistory = {'2026-11-01': {'USD': 3.10}, '2026-11-03': {'USD': 3.157}};
    final cards = JObj.lazy(file.json, 'money').writeList('cardTransactions');
    final template = (cards.first as Map).cast<String, dynamic>();
    for (final (id, day) in [('nov1', DateTime(2026, 11, 1, 12)), ('nov2', DateTime(2026, 11, 2, 12)),
      ('nov3', DateTime(2026, 11, 3, 12)), ('oct20', DateTime(2026, 10, 20, 12))]) {
      cards.add({...deepCopy(template) as Json, 'id': id, 'date': dateTimeToSwift(day), 'amount': 10, 'originalAmount': 10,
        'originalCurrency': 'USD'}..remove('linkedExpenseID')..remove('linkedTrackedID'));
    }
    expect(money.convertForeignCharges(), 4);
    final byId = {for (final t in CardData(file.money).cardTransactions) t.id: t.amount};
    expect([byId['nov1'], byId['nov2'], byId['nov3'], byId['oct20']], [31.0, 31.0, 31.57, 32.0]);
    expect(money.exchangeRate('USD', DateTime(2026, 11, 2, 12))?.day, '2026-11-01');
    expect(money.exchangeRate('USD', DateTime(2026, 10, 20, 12))?.day, isNull);
  });

  test('saved rates by day: the day it was published, half a year kept', () {
    final family = FamilyBackup(loadFixture());
    final money = family.fileForEditing(family.state.activeID).money..exchangeRateHistory = {'2026-01-01': {'USD': 3.5}, '2026-10-01': {'USD': 3.7}};
    money.recordExchangeRates({'USD': 3.2, 'EUR': 3.6}, DateTime(2026, 11, 3));
    expect(money.exchangeRates['USD'], 3.2);
    expect(money.exchangeRateHistory.keys.toSet(), {'2026-10-01', '2026-11-03'});
    expect(money.exchangeRate('USD', DateTime(2026, 11, 2, 12))?.day, '2026-10-01');
    expect(money.exchangeRate('EUR', DateTime(2026, 10, 2, 12))?.day, isNull, reason: 'no EUR rate that old: today\'s');
  });

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
  }, skip: !canRun ? 'needs swiftc (macOS)' : !File('test/fixtures/max_sample.xlsx').existsSync() ? 'needs test/fixtures/max_sample.xlsx (not in git)' : false);
}
