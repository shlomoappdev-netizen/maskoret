@Tags(['swift'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/data/json.dart';
import 'package:maskoret/data/models.dart';
import 'package:maskoret/data/trend_suggestions.dart';
import 'package:maskoret/data/trends.dart';

import 'compat_test.dart' show loadFixture;

/// Which trend the new card charges are offered after an import — the logic, and the same answers as
/// TrendSuggestions.swift.
void main() {
  final canRun = Platform.isMacOS && Process.runSync('which', ['swiftc']).exitCode == 0;

  Json charge(String id, String merchant, double amount, {String category = '', String? linkedExpenseID}) => {
        'id': id,
        'status': 'charged',
        'importedAt': dateTimeToSwift(DateTime(2026, 11, 10)),
        'originalAmount': amount,
        'originalCurrency': '₪',
        'chargeEstimated': false,
        'merchant': merchant,
        'chargeDate': dateTimeToSwift(DateTime(2026, 12, 10)),
        'date': dateTimeToSwift(DateTime(2026, 11, 5)),
        'amount': amount,
        'owedPortion': 0,
        'ignored': false,
        'type': 'רגילה',
        'method': '',
        'note': '',
        'cardLast4': '1234',
        'category': category,
        if (linkedExpenseID != null) 'linkedExpenseID': linkedExpenseID,
      };

  const newIDs = {'n1', 'n2', 'n3', 'n4', 'n5', 'n6', 'n7', 'n8'};

  /// A member with three trends, one older charge already in "דייטים", and a new statement.
  (Json, SaveFile, List<String>) household({bool trends = true}) {
    final doc = Starter.family();
    final family = FamilyBackup(doc);
    final file = family.fileForEditing(family.state.primaryID);
    final money = file.json['money'] as Json;
    final list = [
      Trend.create(name: 'דייטים', emoji: '💕')..['cardIDs'] = ['old1'],
      Trend.create(name: 'סופר', emoji: '🛒'),
      Trend.create(name: 'ביגוד', emoji: '👕'),
    ];
    if (trends) money['trends'] = list;
    money['cardTransactions'] = [
      charge('old1', 'קפה גרג', 40),
      charge('n1', 'קפה  גרג', 45),
      charge('n2', 'קפה גרג', 55),
      charge('n3', 'שופרסל דיל', 300, category: 'סופר ומזון'),
      charge('n4', 'H&M ביגוד', 200),
      charge('n5', 'פז דלק', 250, category: 'דלק'),
      charge('n6', 'זיכוי מחנות', -30),
      charge('n7', 'חברת החשמל', 400, linkedExpenseID: 'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE'),
      charge('n8', 'קולנוע לב', 80),
    ];
    return (doc, file, [for (final t in list) t['id'] as String]);
  }

  test('suggestions: by the merchant\'s history, the bank\'s category, the merchant\'s name — or none', () {
    final (_, file, ids) = household();
    final items = TrendSuggestions.items(file.money, newIDs);
    expect([for (final i in items) (i.merchant, i.trendID, i.reason, i.cardIDs.length, i.total)], [
      ('שופרסל דיל', ids[1], 'category', 1, 300.0),
      ('H&M ביגוד', ids[2], 'name', 1, 200.0),
      ('קפה  גרג', ids[0], 'history', 2, 100.0),
      ('פז דלק', null, '', 1, 250.0),
      ('קולנוע לב', null, '', 1, 80.0),
    ], reason: 'with a suggestion first, then by amount; refunds and charges linked to a fixed expense are left out');
    expect(TrendSuggestions.items(file.money, {'n5'}).single.merchant, 'פז דלק', reason: 'only the new charges');
  });

  test('without trends nothing is offered', () {
    final (_, file, _) = household(trends: false);
    expect(TrendSuggestions.items(file.money, newIDs), isEmpty);
    expect(TrendSuggestions.applyRules(file, newIDs), 0);
  });

  test('"אישור" assigns the merchant\'s charges; "תמיד" does it by itself on the next statement', () {
    final (_, file, ids) = household();
    final items = TrendSuggestions.items(file.money, newIDs);
    final cinema = items.firstWhere((i) => i.merchant == 'קולנוע לב');
    TrendSuggestions.assign(file, cinema, ids[0], always: true);
    TrendSuggestions.assign(file, cinema, ids[0], always: true);
    final coffee = items.firstWhere((i) => i.reason == 'history');
    TrendSuggestions.assign(file, coffee, ids[2]);
    List<String> cards(int i) => Trend((file.json['money']['trends'] as List)[i] as Json).cardIDs;
    expect(cards(0), ['old1', 'n8'], reason: 'once');
    expect(cards(2), ['n1', 'n2'], reason: 'another trend than the suggested one');
    expect(file.money.merchantTrends, {'קולנוע לב': ids[0]});
    expect(TrendSuggestions.items(file.money, newIDs).map((i) => i.merchant), ['שופרסל דיל', 'H&M ביגוד', 'פז דלק']);

    // The next statement: the cinema goes to its trend without asking.
    (file.json['money']['cardTransactions'] as List).addAll(<Json>[charge('m1', 'קולנוע  לב', 90), charge('m2', 'פז דלק', 100)]);
    expect(TrendSuggestions.applyRules(file, {'m1', 'm2'}), 1);
    expect(cards(0), ['old1', 'n8', 'm1']);
    expect(TrendSuggestions.items(file.money, {'m1', 'm2'}).single.merchant, 'פז דלק');
    // A rule whose trend was deleted does nothing.
    file.money.merchantTrends = {'פז דלק': 'GONE'};
    expect(TrendSuggestions.applyRules(file, {'m2'}), 0);
  });

  const aiAnswer = 'הנה:\n```json\n{"1": "דייטים", "2": "מגמה שלא קיימת", "7": "סופר", "x": 3}\n```';

  test('the model is asked once about what is left, and only trends that exist are taken', () {
    final (_, file, ids) = household();
    final items = TrendSuggestions.items(file.money, newIDs);
    final prompt = TrendSuggestions.aiPrompt(file.money, items);
    expect(prompt, 'המגמות:\n- דייטים\n- סופר\n- ביגוד\n\nבתי העסק:\n1. פז דלק (קטגוריה: דלק)\n2. קולנוע לב');
    expect(TrendSuggestions.applyAIAnswer(file.money, items, aiAnswer), 1);
    expect(items.firstWhere((i) => i.merchant == 'פז דלק').trendID, ids[0]);
    expect(items.firstWhere((i) => i.merchant == 'פז דלק').reason, 'ai');
    expect(items.last.trendID, isNull);
    expect(TrendSuggestions.applyAIAnswer(file.money, items, 'לא יודע'), 0);
    expect(items.first.reason, 'category', reason: 'the app\'s own suggestions stay');
  });

  test('Swift offers the same trends, writes the same request and reads the same answer', () {
    Map<String, dynamic> swift(Json doc) {
      final f = File('${Directory.systemTemp.createTempSync('trends').path}/doc.json')..writeAsStringSync(jsonEncode(doc));
      final r = Process.runSync('tool/swift_check.sh', [f.path, '${dateTimeToSwift(DateTime.now())}', aiAnswer]);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      return (jsonDecode((r.stdout as String).trim().split('\n').last) as Map)['files'] as Map<String, dynamic>;
    }

    void check(Json doc) {
      final out = swift(doc);
      final family = FamilyBackup(doc);
      for (final m in family.state.members) {
        final f = family.file(m.id)!;
        final all = {for (final t in JObj(f.money.raw).objects('cardTransactions')) t['id'] as String};
        final items = TrendSuggestions.items(f.money, all);
        final s = out[m.id]['trendSuggestions'] as Map<String, dynamic>;
        expect(s['items'], [
          for (final i in items) [i.merchantKey, i.trendID ?? '', i.reason, '${i.cardIDs.length}', i.total.toStringAsFixed(2)],
        ]);
        expect(s['prompt'], TrendSuggestions.aiPrompt(f.money, items));
        expect(s['placed'], TrendSuggestions.applyAIAnswer(f.money, items, aiAnswer));
        expect(s['afterAI'], [for (final i in items) [i.merchantKey, i.trendID ?? '', i.reason]]);
        expect(s['rules'], f.money.merchantTrends);
      }
    }

    final (doc, file, ids) = household();
    file.money.merchantTrends = {'קולנוע לב': ids[0]};
    check(doc);
    check(loadFixture());
  }, skip: canRun ? false : 'needs swiftc (macOS)');
}
