import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/data/card.dart';
import 'package:maskoret/data/exchange_rates.dart';

void main() {
  test('Bank of Israel rates: ₪ for one unit (JPY comes per 100)', () {
    const body = '{"exchangeRates":[{"key":"USD","currentExchangeRate":3.157,"unit":1,"lastUpdate":"2026-11-03T13:21:05.8665609Z"},'
        '{"key":"JPY","currentExchangeRate":1.9957,"unit":100,"lastUpdate":"2026-11-02T13:21:05Z"},'
        '{"key":"BAD","currentExchangeRate":0,"unit":1}]}';
    final reply = ExchangeRatesUpdate.parse(body);
    expect(reply.published, DateTime(2026, 11, 3));
    final r = reply.rates;
    expect(r['USD'], 3.157);
    expect(r['JPY'], closeTo(0.019957, 1e-9));
    expect(r.containsKey('BAD'), isFalse);
  });

  test('currency codes: shekels are null, symbols and Hebrew names become ISO codes', () {
    for (final s in ['', '₪', 'ILS', 'nis', 'ש"ח', 'ש״ח', 'שח', 'שקל']) {
      expect(CardTransaction.currencyCode(s), isNull, reason: s);
    }
    expect(CardTransaction.currencyCode(r'$'), 'USD');
    expect(CardTransaction.currencyCode('us\$'), 'USD');
    expect(CardTransaction.currencyCode('דולר'), 'USD');
    expect(CardTransaction.currencyCode('€'), 'EUR');
    expect(CardTransaction.currencyCode('ליש״ט'), 'GBP');
    expect(CardTransaction.currencyCode(' jpy '), 'JPY');
    expect(CardTransaction.currencyCode('AB'), isNull);
  });
}
