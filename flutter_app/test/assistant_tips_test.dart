@Tags(['swift'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:maskoret/data/assistant_tips.dart';
import 'package:maskoret/data/fmt.dart';
import 'package:maskoret/data/json.dart';
import 'package:maskoret/data/models.dart';
import 'package:maskoret/data/money_calc.dart';
import 'package:maskoret/data/month_picture.dart';
import 'package:maskoret/data/trends.dart';

import 'compat_test.dart' show loadFixture;

/// The local rules behind the tips at the top of the screens — and the same ids and texts as AssistantTips.swift.
void main() {
  final canRun = Platform.isMacOS && Process.runSync('which', ['swiftc']).exitCode == 0;
  final now = DateTime(2026, 11, 16, 10);

  setUpAll(() => initializeDateFormatting('he'));

  /// A member with a salary of `net`, and whatever `build` adds.
  SaveFile member(void Function(Json money) build, {double net = 10000}) {
    final doc = Starter.family();
    final family = FamilyBackup(doc);
    final file = family.fileForEditing(family.state.primaryID);
    file.budget.incomes.first
      ..amount = net
      ..json['isNet'] = true;
    build(file.json['money'] as Json);
    return file;
  }

  MonthPicture picture(SaveFile f) {
    final (y, m) = f.money.period(now);
    return MonthPicture.of(f, y, m, now: now);
  }

  List<AssistantTip> tips(SaveFile f) => AssistantTips.all(f.money, picture(f), now: now);

  Json trend(String name, double limit, List<(DateTime, double)> spent) => Trend.create(name: name, monthlyLimit: limit)
    ..['entries'] = [
      for (final (date, amount) in spent)
        {'id': newId(), 'date': dateTimeToSwift(date), 'amount': amount, 'note': ''},
    ];

  Json account(String name, String kind, {DateTime? balanceAt, DateTime? maturity}) => {
        ...Account.create(name: name, kind: AccountKind.values.firstWhere((k) => k.name == kind)),
        'balances': [
          if (balanceAt != null) {'id': newId(), 'date': dateTimeToSwift(balanceAt), 'amount': 5000, 'note': ''},
        ],
        if (maturity != null) 'maturityDate': dateTimeToSwift(maturity),
      };

  test('a quiet month has no tips', () {
    expect(tips(member((_) {})).where((t) => t.id != 'no-actual-net:202611'), isEmpty);
  });

  test('trends: over the limit, close to it, and none with a limit', () {
    final f = member((money) {
      money['trends'] = [
        trend('אוכל בחוץ', 500, [(DateTime(2026, 11, 3), 400), (DateTime(2026, 11, 10), 250), (DateTime(2026, 10, 20), 900)]),
        trend('קפה', 200, [(DateTime(2026, 11, 5), 170)]),
        trend('מתנות', 300, [(DateTime(2026, 11, 5), 100)]),
        trend('חופשות', 0, [(DateTime(2026, 11, 5), 5000)]),
      ];
    });
    final list = tips(f);
    final ids = (f.json['money']['trends'] as List).map((t) => t['id']).toList();
    final over = list.firstWhere((t) => t.id == 'trend-over:${ids[0]}:202611');
    expect(over.severity, 3);
    expect(over.screen, 'trends');
    expect(over.text, contains(Fmt.money(150)));
    expect(over.question, contains('איך אני חוזר לתקציב'));
    expect(over.question + over.text + over.title, isNot(contains('להעלות')), reason: 'never suggests raising the limit');
    final near = list.firstWhere((t) => t.id == 'trend-near:${ids[1]}:202611');
    expect(near.severity, 2);
    expect(near.text, 'נשארו ${Fmt.money(30)} עד התקרה, ועוד 14 ימים עד סוף החודש.');
    expect(list.where((t) => t.id.contains(ids[2] as String) || t.id.contains(ids[3] as String)), isEmpty);
    expect(list.where((t) => t.id == 'trends-no-limits'), isEmpty);
    expect(list.first.id, over.id, reason: 'the most important first');
    expect(AssistantTips.top(f.money, picture(f), [over.id], now: now)!.severity, lessThanOrEqualTo(3));
    expect(AssistantTips.tipFor('trends', f.money, picture(f), [over.id], now: now)!.id, near.id);

    final none = member((money) => money['trends'] = [trend('קפה', 0, [])]);
    expect(tips(none).map((t) => t.id), contains('trends-no-limits'));
  });

  test('the month: already negative, or expected to be', () {
    final negative = member((money) {
      money['transactions'] = [
        {
          ...MoneyTransaction.create(kind: TransactionKind.expense, accountID: (money['accounts'] as List).first['id'] as String),
          'title': 'תיקון רכב', 'amount': 4000, 'date': dateTimeToSwift(DateTime(2026, 11, 5)),
        },
      ];
    }, net: 3000);
    final p = picture(negative);
    expect(p.remainingActual, lessThan(0));
    final tip = tips(negative).firstWhere((t) => t.id == 'left-negative:202611');
    expect(tip.severity, 3);
    expect(tip.screen, 'summary');
    expect(tip.text, contains(Fmt.money(-p.remainingActual)));
    expect(tips(negative).where((t) => t.id.startsWith('left-expected')), isEmpty, reason: 'one of the two');
  });

  test('accounts: a balance not updated for more than 60 days, a deposit that ends within 30', () {
    final f = member((money) {
      (money['accounts'] as List).addAll(<Json>[
        account('חיסכון', 'savings', balanceAt: DateTime(2026, 8, 1)),
        account('טרי', 'savings', balanceAt: DateTime(2026, 10, 1)),
        account('פיקדון', 'deposit', balanceAt: DateTime(2026, 11, 1), maturity: DateTime(2026, 12, 10)),
        account('רחוק', 'deposit', balanceAt: DateTime(2026, 11, 1), maturity: DateTime(2027, 6, 1)),
        account('פנסיה', 'pension', balanceAt: DateTime(2025, 1, 1)),
      ]);
    });
    final list = tips(f).where((t) => t.screen == 'accounts').toList();
    final acc = (f.json['money']['accounts'] as List);
    expect(list.map((t) => t.id), ['deposit-ends:${acc[3]['id']}:20261210', 'balance-stale:${acc[1]['id']}:20260801']);
    expect(list[0].title, '״פיקדון״ מסתיים בעוד 24 ימים');
    expect(list[1].title, 'היתרה של ״חיסכון״ לא עודכנה 107 ימים');
  });

  test('"לא עכשיו" hides exactly that tip, and is kept as a list of unique strings', () {
    final f = member((money) => money['trends'] = [trend('קפה', 0, [])]);
    final a = f.money.assistant;
    a.dismissTip('trends-no-limits');
    a.dismissTip('trends-no-limits');
    expect(a.dismissedTips, ['trends-no-limits']);
    expect(AssistantTips.tipFor('trends', f.money, picture(f), a.dismissedTips, now: now), isNull);
    for (var i = 0; i < 300; i++) {
      a.dismissTip('x:$i');
    }
    expect(a.dismissedTips.length, 200);
    expect(a.dismissedTips.last, 'x:299');
  });

  test('Swift gives the same tips, word for word (the demo household with limits, old balances and a deposit)', () {
    final doc = loadFixture();
    final family = FamilyBackup(doc);
    final at = DateTime.now();
    for (final m in family.state.members) {
      final f = family.fileForEditing(m.id);
      final money = f.json['money'] as Json;
      final trends = (money['trends'] as List?) ?? (money['trends'] = <dynamic>[]);
      for (var i = 0; i < trends.length; i++) {
        (trends[i] as Map)['monthlyLimit'] = i.isEven ? 50 : 100000;
      }
      trends.add(trend('קפה', 200, [(at, 170)]));
      trends.add(trend('מתנות', 100, [(at, 400)]));
      (money['accounts'] as List).addAll([
        account('חיסכון ישן', 'savings', balanceAt: at.subtract(const Duration(days: 100))),
        account('פיקדון', 'deposit', balanceAt: at, maturity: at.add(const Duration(days: 12))),
      ]);
      f.money.assistant.dismissTip('trends-no-limits');
    }
    final file = File('${Directory.systemTemp.createTempSync('tips').path}/doc.json')..writeAsStringSync(jsonEncode(doc));
    final r = Process.runSync('tool/swift_check.sh', [file.path, '${dateTimeToSwift(at)}']);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    final out = (jsonDecode((r.stdout as String).trim().split('\n').last) as Map)['files'] as Map;
    for (final m in family.state.members) {
      final f = family.file(m.id)!;
      final (y, mo) = f.money.period(at);
      final mine = AssistantTips.all(f.money, MonthPicture.of(f, y, mo, now: at), now: at);
      expect(mine.length, greaterThanOrEqualTo(4), reason: 'the fixture triggers several rules');
      expect(out[m.id]['tips'], [for (final t in mine) [t.id, t.screen, t.title, t.text, '${t.severity}', t.question]]);
      expect(out[m.id]['dismissedTips'], ['trends-no-limits']);
    }
  }, skip: canRun ? false : 'needs swiftc (macOS)');
}
