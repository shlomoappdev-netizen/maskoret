import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/data/card.dart';
import 'package:maskoret/data/json.dart';
import 'package:maskoret/data/max_import.dart';

/// An artificial statement in CAL's format (tool/make_cal_sample.py), made on the spot when it's missing.
final sample = File('test/fixtures/cal_sample.xlsx');

void main() {
  final canPython = Process.runSync('which', ['python3']).exitCode == 0;
  if (!sample.existsSync() && canPython) Process.runSync('python3', ['tool/make_cal_sample.py']);
  final hasFile = sample.existsSync();
  final canRunSwift = Platform.isMacOS && Process.runSync('which', ['swiftc']).exitCode == 0;

  test('reads a CAL statement: "x:" prefixes, line breaks in the header, installments, pending and refunds', () {
    final sheets = XlsxReader.read(sample.readAsBytesSync());
    expect(CalParser.isCal(sheets), isTrue);
    final r = CardStatementParser.parse(sheets);
    expect(r.billingLabel, '11/2026');
    final txs = r.transactions.map(CardTransaction.new).toList();
    expect(txs.length, 12, reason: 'the totals rows have no date and are skipped');
    expect(txs.every((t) => t.cardLast4 == 'CAL' && t.category.isEmpty), isTrue);

    final pending = txs.where((t) => t.status == 'pending').toList();
    expect(pending.single.merchant, 'סופר גדול');
    expect(pending.single.note, '');
    expect(pending.single.chargeDate, DateTime(2026, 11, 2, 12));

    expect(txs.firstWhere((t) => t.merchant.startsWith('חנות בגדים')).amount, -79.9);
    final parking = txs.where((t) => t.merchant == 'חניון העירייה').map((t) => t.id).toList();
    expect(parking.map((id) => id.split('#').last), ['1', '2'], reason: 'identical purchases on the same day are both kept');

    final shoes = txs.where((t) => t.merchant == 'חנות נעליים').toList();
    expect(shoes.map((t) => t.note), ['תשלום 1 מתוך 2', 'תשלום 2 מתוך 2']);
    expect(shoes.map((t) => t.chargeDate), [DateTime(2026, 10, 2, 12), DateTime(2026, 11, 2, 12)]);
    expect(shoes.first.originalAmount, 300);
    final tv = txs.where((t) => t.merchant == 'חנות חשמל').toList();
    expect(tv.map((t) => t.installment?.number), [1, 2, 3]);
    expect(tv.every((t) => t.installment?.of == 10 && t.originalAmount == 999), isTrue);
    expect(tv.map((t) => t.chargeDate!.month), [9, 10, 11]);
  }, skip: hasFile ? false : 'needs python3 to write test/fixtures/cal_sample.xlsx');

  test('the charge months add up to the file\'s "סה״כ לחיוב"', () {
    final sheets = XlsxReader.read(sample.readAsBytesSync());
    final txs = CardStatementParser.parse(sheets).transactions.map(CardTransaction.new);
    final charged = txs.where((t) => t.status != 'pending').fold(0.0, (s, t) => s + t.amount);
    final totalRow = sheets.first.rows.firstWhere((r) => r.any((c) => c.contains('סה"כ לחיוב')));
    expect(charged, closeTo(double.parse(totalRow.last), 0.005));
  }, skip: hasFile ? false : 'needs python3 to write test/fixtures/cal_sample.xlsx');

  test('the Swift app reads the CAL statement exactly the same', () {
    final out = Process.runSync('tool/swift_check.sh', ['max', sample.path]);
    expect(out.exitCode, 0, reason: '${out.stderr}');
    final swift = jsonDecode((out.stdout as String).trim().split('\n').last) as Map;
    final dart = CardStatementParser.parse(XlsxReader.read(sample.readAsBytesSync()));
    expect(dart.billingLabel, swift['label']);
    final rows = swift['rows'] as List;
    expect(dart.transactions.length, rows.length);
    for (var i = 0; i < rows.length; i++) {
      final s = rows[i] as Map, d = CardTransaction(dart.transactions[i]);
      expect(d.id, s['id'], reason: 'row $i id');
      expect(d.status, s['status'], reason: 'row $i status');
      expect(d.note, s['note'], reason: 'row $i note');
      expect(d.originalAmount, closeTo((s['originalAmount'] as num).toDouble(), 0.001), reason: 'row $i original');
      expect(d.amount, closeTo((s['amount'] as num).toDouble(), 0.001), reason: 'row $i amount');
      expect(dateTimeToSwift(d.date), closeTo((s['date'] as num).toDouble(), 1), reason: 'row $i date');
      expect(dateTimeToSwift(d.chargeDate!), closeTo((s['chargeDate'] as num).toDouble(), 1), reason: 'row $i charge');
    }
  }, skip: !hasFile ? 'needs test/fixtures/cal_sample.xlsx' : (canRunSwift ? false : 'needs swiftc (macOS)'));
}
