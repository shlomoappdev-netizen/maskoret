import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/data/models.dart';
import 'package:maskoret/data/json.dart';
import 'package:maskoret/data/month_picture.dart';
import 'package:maskoret/data/trends.dart';
import 'package:maskoret/ui/summary_screen.dart';

void main() {
  test('"לאן הולך הנטו" by the user’s trends: their share of the card, and the rest of the card apart', () {
    final doc = (jsonDecode(File('test/fixtures/swift_household.json').readAsStringSync()) as Map).cast<String, dynamic>();
    final family = FamilyBackup(doc);
    final file = family.file(family.state.activeID)!;
    final money = file.money;
    final pic = MonthPicture.of(file, 2026, 10);
    final slices = netSlices(pic, money);
    final names = slices.map((s) => s.$1).toList();

    // What each trend got in the period, from the card.
    var fromCard = 0.0;
    final expected = <String, double>{};
    for (final t in JObj(money.raw).objects('trends').map(Trend.new)) {
      var total = 0.0;
      for (final i in TrendCalc.items(money, t)) {
        if (i.source == TrendSource.card && !i.date.isBefore(pic.periodStart!) && i.date.isBefore(pic.periodEnd!)) {
          total += i.amount;
        }
      }
      fromCard += total;
      if (total > 0.005) expected['${t.emoji} ${t.name}'] = total;
    }
    expect(expected, isNotEmpty, reason: 'the fixture month has charges in trends');
    for (final e in expected.entries) {
      expect(slices.firstWhere((s) => s.$1 == e.key).$2, closeTo(e.value, 0.001));
    }
    expect(names, isNot(contains('כרטיס אשראי (משתנות)')));
    final rest = slices.where((s) => s.$1 == '💳 אשראי — בלי מגמה').fold(0.0, (a, s) => a + s.$2);
    final known = pic.cardTotal - pic.cardEstimate;
    expect(rest, closeTo(known - fromCard > 0 ? known - fromCard : 0, 0.001));
    // The trends come biggest first, right after the fixed spending.
    final trendValues = [for (final s in slices) if (expected.containsKey(s.$1)) s.$2];
    expect(trendValues, [...trendValues]..sort((a, b) => b.compareTo(a)));
  });
}
