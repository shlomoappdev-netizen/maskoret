import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'tax.dart';
import 'json.dart';

/// Port of `Store.refreshRates` (the online part): checks the rates file at the household's `ratesURL`
/// (twice a day at most unless forced) and takes it when its version is newer. Returns the status line.
class RatesUpdate {
  static String get statusWithoutURL => 'השיעורים מתעדכנים יחד עם עדכוני האפליקציה';

  static bool due(SaveFile f) {
    final last = JObj(f.json).date('lastRatesCheck');
    return last == null || DateTime.now().difference(last) >= const Duration(hours: 12);
  }

  static String url(SaveFile f) => JObj(f.json).s('ratesURL');

  /// Fetches the file; `apply` writes the result into the household (inside a store edit).
  static Future<(String status, Json? newer, bool fetched)> check(SaveFile f, {bool force = false}) async {
    if (!force && !due(f)) return ('', null, false);
    final uri = Uri.tryParse(url(f).trim());
    if (uri == null || uri.scheme != 'https') return (statusWithoutURL, null, false);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final response = await (await client.getUrl(uri)).close();
      if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}');
      final remote = jsonDecode(await response.transform(utf8.decoder).join());
      final parsed = TaxRates.effective(remote);
      final current = f.budget.rates;
      if (parsed.version > current.version) {
        return ('עודכן לנתוני ${parsed.year} (${parsed.updated})', parsed.json, true);
      }
      return ('הנתונים מעודכנים', null, true);
    } catch (_) {
      return ('לא ניתן לבדוק עדכונים כרגע — משתמש בנתונים השמורים', null, false);
    } finally {
      client.close();
    }
  }

  static void apply(SaveFile f, Json? newer, {required bool checked}) {
    if (checked) JObj(f.json).set('lastRatesCheck', DateTime.now());
    if (newer != null) JObj.lazy(f.json, 'budget').set('rates', deepCopy(newer));
  }
}
