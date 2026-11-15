import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/data/card.dart';
import 'package:maskoret/data/json.dart';
import 'package:maskoret/data/max_import.dart';

/// An artificial statement in Isracard's format (tool/make_isracard_sample.py), made on the spot when it's missing.
final sample = File('test/fixtures/isracard_sample.xlsx');

void main() {
  final canPython = Process.runSync('which', ['python3']).exitCode == 0;
  if (!sample.existsSync() && canPython) Process.runSync('python3', ['tool/make_isracard_sample.py']);
  final hasFile = sample.existsSync();
  final canRunSwift = Platform.isMacOS && Process.runSync('which', ['swiftc']).exitCode == 0;

  test('reads an Isracard statement: cards, charge days, sections, installments, foreign and pending', () {
    final sheets = XlsxReader.read(sample.readAsBytesSync());
    expect(IsracardParser.isIsracard(sheets), isTrue);
    expect(CalParser.isCal(sheets), isFalse);
    final r = CardStatementParser.parse(sheets);
    expect(r.billingLabel, '11/2026');
    final txs = r.transactions.map(CardTransaction.new).toList();
    expect(txs.length, 10, reason: 'the totals rows have no date and are skipped');

    final first = txs.where((t) => t.cardLast4 == '1111').toList();
    expect(first.length, 9);
    expect(txs.where((t) => t.cardLast4 == '2222').single.merchant, 'בית קפה');
    expect(txs.firstWhere((t) => t.cardLast4 == '2222').chargeDate, DateTime(2026, 12, 10, 12));

    final grocery = txs.firstWhere((t) => t.merchant == 'סופר השכונה');
    expect(grocery.date, DateTime(2026, 10, 28, 12), reason: '"28.10.26" is 2026, not the year 26');
    expect(grocery.chargeDate, DateTime(2026, 12, 2, 12));
    expect(grocery.status, 'charged');

    final parking = txs.where((t) => t.merchant == 'חניון העירייה').map((t) => t.id.split('#').last).toList();
    expect(parking, ['1', '2'], reason: 'identical purchases on the same day are both kept');
    expect(txs.firstWhere((t) => t.merchant == 'חנות בגדים').amount, -80);
    final fee = txs.firstWhere((t) => t.merchant == 'דמי כרטיס');
    expect(fee.amount, 0, reason: 'a discount leaves nothing to charge');
    expect(fee.originalAmount, 24.31);

    final tv = txs.firstWhere((t) => t.merchant == 'חנות חשמל');
    expect(tv.amount, 100);
    expect(tv.originalAmount, 600);
    expect(tv.installment?.number, 2);
    expect(tv.installment?.of, 6);

    final amazon = txs.firstWhere((t) => t.merchant == 'AMAZON MKTPLACE');
    expect(amazon.status, 'foreign');
    expect(amazon.amount, 74.6);
    expect(amazon.amountEstimated, isFalse, reason: 'already charged in ₪');
    final netflix = txs.firstWhere((t) => t.merchant == 'NETFLIX.COM');
    expect(netflix.amountEstimated, isTrue, reason: 'charged in dollars: converted at the Bank of Israel rate until a later statement');

    final fuel = txs.firstWhere((t) => t.merchant == 'תחנת דלק');
    expect(fuel.status, 'pending');
    expect(fuel.chargeEstimated, isTrue);
  }, skip: hasFile ? false : 'needs python3 to write test/fixtures/isracard_sample.xlsx');

  test('each card\'s ₪ charges add up to its "סה״כ לחיוב החודש"', () {
    final sheets = XlsxReader.read(sample.readAsBytesSync());
    final txs = CardStatementParser.parse(sheets).transactions.map(CardTransaction.new).toList();
    double total(String card) => txs
        .where((t) => t.cardLast4 == card && t.status == 'charged')
        .fold(0.0, (s, t) => s + t.amount);
    expect(total('1111'), closeTo(289.9, 0.005));
    expect(total('2222'), closeTo(18, 0.005));
  }, skip: hasFile ? false : 'needs python3 to write test/fixtures/isracard_sample.xlsx');

  test('a statement that isn\'t from any known company still says so', () {
    expect(() => CardStatementParser.parse([XlsxSheet('x', [['שלום', 'עולם']])]), throwsA(CardImportException.notMax));
  });

  test('the Swift app reads the Isracard statement exactly the same', () {
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
  }, skip: !hasFile ? 'needs test/fixtures/isracard_sample.xlsx' : (canRunSwift ? false : 'needs swiftc (macOS)'));
}
