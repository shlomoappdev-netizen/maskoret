import 'dart:convert';
import 'dart:io';

import '../state/store.dart';

/// Bank of Israel representative exchange rates, for card charges in a foreign currency — refreshExchangeRates in
/// Store.swift. Checked a few times a day at most; offline, the saved rates stay.
class ExchangeRatesUpdate {
  static const url = 'https://www.boi.org.il/PublicApi/GetExchangeRates?asJson=true';

  /// "exchangeRates": [{"key": "USD", "currentExchangeRate": 3.157, "unit": 1, "lastUpdate": "2026-11-03T13:21…Z"}, …]
  /// → {"USD": 3.157}, and the day they were published (the latest "lastUpdate"; null when it isn't there).
  static ({Map<String, double> rates, DateTime? published}) parse(String body) {
    final rates = <String, double>{};
    DateTime? published;
    final list = (jsonDecode(body) as Map)['exchangeRates'];
    if (list is! List) return (rates: rates, published: null);
    for (final r in list.whereType<Map>()) {
      final key = r['key'], rate = r['currentExchangeRate'], unit = r['unit'], updated = r['lastUpdate'];
      if (key is String && rate is num && unit is num && unit > 0 && rate > 0) rates[key.toUpperCase()] = rate / unit;
      // "2026-11-03T13:21:05.8665609Z": the day part, like rateDayFormat.date(from: prefix(10)).
      final day = updated is String && updated.length >= 10 ? DateTime.tryParse(updated.substring(0, 10)) : null;
      if (day != null && (published == null || day.isAfter(published))) published = day;
    }
    return (rates: rates, published: published);
  }

  static Future<void> refresh(AppStore store, {DateTime? now}) async {
    final at = now ?? DateTime.now();
    final last = store.file.money.exchangeRatesAt;
    if (last != null && at.difference(last) < const Duration(hours: 6)) return;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final response = await (await client.getUrl(Uri.parse(url))).close();
      if (response.statusCode != 200) return;
      final reply = parse(await response.transform(utf8.decoder).join());
      if (reply.rates.isEmpty) return;
      store.edit((f) {
        f.money.recordExchangeRates(reply.rates, reply.published ?? at);
        f.money.convertForeignCharges();
      });
    } catch (_) {
      // Offline: the saved rates stay.
    } finally {
      client.close();
    }
  }
}
