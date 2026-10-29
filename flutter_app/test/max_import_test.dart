@Tags(['swift'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/data/card.dart';
import 'package:maskoret/data/json.dart';
import 'package:maskoret/data/max_import.dart';
import 'package:maskoret/data/models.dart';

import 'compat_test.dart' show loadFixture;

/// An artificial statement in Max's format (tool/make_max_sample.py).
final realStatement = File('test/fixtures/max_sample.xlsx');

void main() {
  final canRunSwift = Platform.isMacOS && Process.runSync('which', ['swiftc']).exitCode == 0;
  final hasFile = realStatement.existsSync();

  test('reads a real Max statement exactly like the Swift app', () {
    final r = Process.runSync('tool/swift_check.sh', ['max', realStatement.path]);
    if (r.exitCode != 0) fail('Swift: ${r.stdout}\n${r.stderr}');
    final swift = jsonDecode((r.stdout as String).trim().split('\n').last) as Map<String, dynamic>;
    final dart = MaxParser.parse(XlsxReader.read(realStatement.readAsBytesSync()));
    expect(dart.billingLabel, swift['label']);
    final rows = swift['rows'] as List;
    expect(dart.transactions.length, rows.length);
    for (var i = 0; i < rows.length; i++) {
      final s = rows[i] as Map, d = CardTransaction(dart.transactions[i]);
      expect(d.id, s['id'], reason: 'row $i id');
      expect(d.amount, closeTo((s['amount'] as num).toDouble(), 1e-9), reason: 'row $i amount');
      expect(d.originalAmount, closeTo((s['originalAmount'] as num).toDouble(), 1e-9));
      // A two-digit year is read literally by both apps (year 26); Foundation counts such years in the Julian
      // calendar, so only real dates are compared to the second.
      if (d.date.year > 1900) {
        expect(dateTimeToSwift(d.date), closeTo((s['date'] as num).toDouble(), 1), reason: 'row $i date');
        expect(d.chargeDate == null ? 0 : dateTimeToSwift(d.chargeDate!), closeTo((s['chargeDate'] as num).toDouble(), 1),
            reason: 'row $i chargeDate');
      }
      expect(d.status, s['status']);
      expect(d.category, s['category']);
      final inst = d.installment;
      expect(inst == null ? '' : '${inst.number}/${inst.of}', s['installment']);
    }
  }, skip: !hasFile ? 'no Max statement on this machine' : (canRunSwift ? false : 'needs swiftc (macOS)'));

  group('import into the household', () {
    late Json doc;
    late SaveFile file;
    setUp(() {
      doc = loadFixture();
      final f = FamilyBackup(doc);
      file = f.fileForEditing(f.state.activeID);
    });

    test('importing the same file twice adds nothing, and keeps links and unknown fields', () {
      final bytes = realStatement.readAsBytesSync();
      final first = CardActions(file).importFile(bytes, 'a.xlsx');
      final count = CardData(file.money).cardTransactions.length;
      expect(JObj(first.json).i('count'), greaterThan(0));
      // Link one charge to an expense and add a field this app doesn't know.
      final expense = file.budget.expenses.first.id;
      final some = CardData(file.money).cardTransactions.firstWhere((t) => t.amount > 0 && t.linkedExpenseID == null);
      CardActions(file).linkToExpense(some.id, expense);
      some.json['futureField'] = 'keep me';
      final second = CardActions(file).importFile(bytes, 'a.xlsx');
      expect(JObj(second.json).i('added'), 0);
      expect(CardData(file.money).cardTransactions.length, count);
      final again = CardData(file.money).cardTransactions.firstWhere((t) => t.id == some.id);
      expect(again.linkedExpenseID, expense);
      expect(again.json['futureField'], 'keep me');
      // The rule links every charge from the same merchant.
      for (final t in CardData(file.money).cardTransactions.where((t) => t.merchantKey == some.merchantKey)) {
        if (t.linkedTrackedID == null) expect(t.linkedExpenseID, expense);
      }
      expect((file.json['money']['cardImports'] as List).first['fileName'], 'a.xlsx');
    }, skip: hasFile ? false : 'no Max statement on this machine');
  });
}
