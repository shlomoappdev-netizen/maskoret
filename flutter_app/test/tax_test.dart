import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/data/json.dart';
import 'package:maskoret/data/models.dart';
import 'package:maskoret/data/tax.dart';

void main() {
  final rates = TaxRates.bundled;

  test('bundled rates are the same as rates/tax-rates.json', () {
    final file = jsonDecode(File('../rates/tax-rates.json').readAsStringSync()) as Map;
    expect(rates.version, file['version']);
    expect(rates.brackets.length, (file['brackets'] as List).length);
    expect(rates.creditPointValue, file['creditPointValue']);
  });

  test('income tax, national insurance and health for 10,000 ₪ (worked by hand)', () {
    // Brackets: 7010×10% + 2990×14% = 1119.6; credits: 2.25×242 + 600×35% = 754.5.
    expect(TaxCalc.incomeTax(10000, 2.25, 600, rates), closeTo(365.1, 1e-9));
    // 7703×1.04% + 2297×7%
    expect(TaxCalc.nationalInsurance(10000, rates), closeTo(240.9012, 1e-9));
    // 7703×3.23% + 2297×5.17%
    expect(TaxCalc.healthInsurance(10000, rates), closeTo(367.5618, 1e-9));
  });

  test('surtax and the national insurance ceiling', () {
    final t = TaxCalc.bracketTax(70000, rates);
    final expected = 7010 * .10 + 3050 * .14 + 8940 * .20 + 6100 * .31 + 21590 * .35 + 23310 * .47 + 9870 * .03;
    expect(t, closeTo(expected, 1e-6));
    expect(TaxCalc.nationalInsurance(80000, rates), TaxCalc.nationalInsurance(rates.niMaxIncome, rates));
  });

  test('budget with the starter deductions', () {
    final b = Budget(JObj(Starter.budget()));
    b.incomes.first.amount = 12000;
    // pension 6% = 720
    expect(b.pensionContribution, 720);
    final byType = {for (final d in b.deductions) d.auto: b.deductionAmount(d)};
    expect(byType[AutoDeduction.pension], 720);
    expect(byType[AutoDeduction.incomeTax], closeTo(TaxCalc.incomeTax(12000, 2.25, 720, rates), 1e-9));
    expect(b.net, closeTo(12000 - byType.values.reduce((a, c) => a + c), 1e-9));
  });

  test('older saved rates are replaced by the bundled ones for the calculation only', () {
    final old = deepCopy(rates.json) as Json;
    old['version'] = 20250101;
    old['creditPointValue'] = 1;
    expect(TaxRates.effective(old).creditPointValue, 242);
    final newer = deepCopy(rates.json) as Json;
    newer['version'] = 20270101;
    newer['creditPointValue'] = 250;
    expect(TaxRates.effective(newer).creditPointValue, 250);
    expect(TaxRates.effective({'version': 1}).version, rates.version);
  });
}
