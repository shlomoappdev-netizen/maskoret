import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/data/json.dart';
import 'package:maskoret/data/models.dart';
import 'package:maskoret/data/trends.dart';

SaveFile _file() {
  final doc = (jsonDecode(File('test/fixtures/swift_household.json').readAsStringSync()) as Map).cast<String, dynamic>();
  final family = FamilyBackup(doc);
  return family.fileForEditing(family.state.activeID);
}

void main() {
  test('the limits together, against the latest saved month', () {
    final f = _file();
    final l = TrendLimits.of(f)!;
    expect(l.count, 3);
    expect(l.total, 365);
    expect(l.lastIncome, 1092);
    expect(l.lastLabel, 'ההכנסה האחרונה (אוקטובר 2026)');
    expect(l.averageIncome, isNull, reason: 'one saved month: no average');
    expect(l.warning, isNull);
  });

  test('the average of the last 3 saved months, and the warnings', () {
    final f = _file();
    final budget = f.history.first.json['budget'];
    for (final (y, m, net) in [(2026, 7, 9999.0), (2026, 8, 200.0), (2026, 9, 400.0)]) {
      f.upsertRecord({'id': newId(), 'year': y, 'month': m, 'note': '', 'budget': deepCopy(budget), 'savedAt': 0, 'actualNet': net});
    }
    var l = TrendLimits.of(f)!;
    expect(l.months, 3, reason: 'only the last three (Oct, Sep, Aug); July is left out');
    expect(l.averageIncome, closeTo((1092 + 400 + 200) / 3, 1e-9));
    expect(l.overLast, isFalse);
    expect(l.overAverage, isFalse);

    // Limits above the latest income.
    for (final t in JObj.lazy(f.json, 'money').objects('trends')) {
      t['monthlyLimit'] = 500;
    }
    l = TrendLimits.of(f)!;
    expect(l.total, 1500);
    expect(l.overLast, isTrue);
    expect(l.warning, startsWith('סך התקרות גבוה מההכנסה האחרונה ב-'));
  });

  test('no history: the current estimate; no limits: no card', () {
    final f = _file();
    JObj.lazy(f.json, 'history');
    f.json['history'] = <dynamic>[];
    final l = TrendLimits.of(f)!;
    expect(l.lastLabel, 'ההכנסה החודשית המשוערת');
    expect(l.lastIncome, f.budget.net);
    for (final t in JObj.lazy(f.json, 'money').objects('trends')) {
      t['monthlyLimit'] = 0;
    }
    expect(TrendLimits.of(f), isNull);
  });
}
