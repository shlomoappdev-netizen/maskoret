import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/data/card.dart';
import 'package:maskoret/data/json.dart';
import 'package:maskoret/data/models.dart';
import 'package:maskoret/data/money_calc.dart';
import 'package:maskoret/data/month_picture.dart';

void main() {
  test('without the card estimates: no average line, no card-without-statements estimate, nothing estimated', () {
    final doc = (jsonDecode(File('test/fixtures/swift_household.json').readAsStringSync()) as Map).cast<String, dynamic>();
    final family = FamilyBackup(doc);
    final file = family.fileForEditing(family.state.activeID);
    JObj.lazy(file.json, 'money').writeList('cardSettings').add(
        {'id': newId(), 'last4': '', 'name': 'כרטיס הבנק', 'delayDays': 0, 'monthlyEstimate': 400, 'actualCharges': {}});
    // A month that hasn't ended: the average of past statements still to come.
    final now = DateTime.now();
    final (y, m) = file.money.period(now);
    final full = MonthPicture.of(file, y, m);
    expect(full.card.any((l) => l.estimate), isTrue);
    final actual = full.actualOnly;
    expect(actual.card.any((l) => l.estimate), isFalse);
    expect(actual.card.length, full.card.where((l) => !l.estimate).length);
    expect(actual.cardEstimated, isFalse);
    expect(actual.cardEstimate, 0);
    final estimates = full.card.where((l) => l.estimate).fold(0.0, (s, l) => s + l.amount);
    expect(actual.remaining, closeTo(full.remaining + estimates, 0.001));
    expect(actual.remainingActual, closeTo(actual.remaining, 0.001), reason: 'nothing estimated left');

    // The switch: the current month leaves the estimates out, the full one keeps them.
    MonthPicture.hideCardEstimate.value = true;
    expect(MonthPicture.current(file).card.any((l) => l.estimate), isFalse);
    expect(MonthPicture.currentFull(file).card.any((l) => l.estimate), isTrue);
    MonthPicture.hideCardEstimate.value = false;
  });

  test('linking a card charge to a tracked item does not change what is actually left', () {
    final doc = (jsonDecode(File('test/fixtures/swift_household.json').readAsStringSync()) as Map).cast<String, dynamic>();
    final family = FamilyBackup(doc);
    final file = family.fileForEditing(family.state.activeID);
    final tx = CardData(file.money).cardTransactions.firstWhere((t) => t.isVariable && t.installment == null && t.myAmount > 0);
    final (y, m) = file.money.period(tx.date);
    final before = MonthPicture.of(file, y, m);
    final raw = (file.json['money']['cardTransactions'] as List).firstWhere((t) => t['id'] == tx.id) as Map;
    raw['linkedTrackedID'] = file.budget.trackedItems.first.id;
    final after = MonthPicture.of(file, y, m);
    expect(after.trackedCharged, closeTo(before.trackedCharged + tx.myAmount, 0.001));
    expect(after.remainingActual, closeTo(before.remainingActual, 0.001));
    expect(after.actualOnly.remainingActual, closeTo(before.actualOnly.remainingActual, 0.001));
    expect(after.actualOnly.remaining, closeTo(after.remainingActual, 0.001));
  });
}
