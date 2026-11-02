import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/data/payslip.dart';

// Made-up payslips, laid out the way payroll programs' text layers come out (no real data: the repo is public).
const payslipA = '''
חברה לדוגמה בע"מ
תלוש שכר
8/26
עובד לדוגמה
שכר יסוד
2,750.00
10
29.00
89.00
מס הכנסה שולי%
ביטוח לאומי
מס בריאות
סה״כ תשלומים
2,750.00
ניכויי חובה וגמל
118.00
שכר נטו
2,632.00
נטו לתשלום
2,632.00
''';

// The "נ" is missing or comes out as "ð", as in some payroll fonts.
const payslipB = '''
תלוש משכורת לחודש 03/2026
לחודש 03/2026
ðקודות זיכוי
2.25
1,113.00
114.00
999.00
81.00
918.00
סה״כ תשלומים
יכויי חובה וגמל
שכר ðטו
יכויי רשות
טו לתשלום
''';

// No gross − deductions = net chain: the amount after the label.
const payslipC = '''
11/2025
סה״כ תשלומים
5,000.00
טו לתשלום
4,321.00
''';

const payslipNone = '''
תלוש
אין כאן סכומים
''';

void main() {
  test('payslip A: gross, deductions, net to pay, national insurance and health, the month', () {
    final r = PayslipParser.parse(payslipA);
    expect((r.month, r.year), (8, 2026));
    expect(r.gross, 2750);
    expect(r.deductions, 118);
    expect(r.net, 2632);
    expect(r.netToPay, 2632);
    expect(r.nationalInsurance, 29);
    expect(r.health, 89);
    expect(r.incomeTax, isNull);
  });

  test('payslip B: voluntary deductions after the net, and labels without "נ"', () {
    final r = PayslipParser.parse(payslipB);
    expect(r.gross, 1113);
    expect(r.deductions, 114);
    expect(r.net, 999);
    expect(r.netToPay, 918);
  });

  test('no chain: the amount after "טו לתשלום"; nothing: not useful', () {
    final r = PayslipParser.parse(payslipC);
    expect((r.month, r.year), (11, 2025));
    expect(r.netToPay, 4321);
    expect(r.gross, 5000);
    expect(PayslipParser.parse(payslipNone).isUseful, isFalse);
  });

  test('the Swift app reads every payslip the same way', () {
    final texts = [payslipA, payslipB, payslipC, payslipNone, payslipA.replaceAll('\n', '\r\n')];
    final p = Process.start('tool/swift_payslip.sh', []);
    return p.then((proc) async {
      proc.stdin.write(jsonEncode(texts));
      await proc.stdin.close();
      final out = await proc.stdout.transform(utf8.decoder).join();
      final err = await proc.stderr.transform(utf8.decoder).join();
      expect(await proc.exitCode, 0, reason: err);
      final swift = jsonDecode(out.trim().split('\n').last) as List;
      for (var i = 0; i < texts.length; i++) {
        final dart = PayslipParser.parse(texts[i]).toJson();
        for (final k in dart.keys) {
          final s = swift[i][k], d = dart[k];
          expect(s == null ? null : (s as num).toDouble(), d == null ? null : (d as num).toDouble(), reason: 'payslip $i $k');
        }
      }
    });
  }, skip: Platform.isMacOS ? false : 'needs swiftc (macOS)');
}
