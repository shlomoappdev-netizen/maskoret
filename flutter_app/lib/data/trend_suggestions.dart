import 'dart:convert';

import 'card.dart';
import 'json.dart';
import 'models.dart';
import 'trends.dart';

/// New card charges of one merchant that aren't in any trend yet, with the trend the app would put them in
/// (TrendSuggestionItem in TrendSuggestions.swift).
class TrendSuggestionItem {
  TrendSuggestionItem(this.merchantKey, this.merchant, this.category, this.cardIDs, this.total, this.trendID, this.reason);
  final String merchantKey;
  final String merchant;
  final String category;
  final List<String> cardIDs;
  final double total;

  /// The suggested trend (null: none found).
  String? trendID;

  /// Why: "history" (this merchant was put in the trend before), "category" (the bank's category is the trend's
  /// name), "name" (the merchant's name has the trend's name in it), "ai", or "" when there's no suggestion.
  String reason;

  String get reasonText => switch (reason) {
        'history' => 'בית העסק הזה כבר שויך למגמה הזו',
        'category' => 'לפי הקטגוריה בפירוט',
        'name' => 'לפי שם בית העסק',
        'ai' => 'הצעה של ה-AI',
        _ => '',
      };
}

/// After a card statement is imported: which trend each new charge probably belongs to — the same logic as
/// `TrendSuggestions` in TrendSuggestions.swift. Nothing is assigned without the user, except by a rule the user set
/// ("תמיד לבית העסק הזה").
class TrendSuggestions {
  static String _n(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

  static List<Trend> _trends(MoneyData money) => JObj(money.raw).objects('trends').map(Trend.new).toList();

  /// The new charges that can go into a trend: purchases that count as spending and aren't in a trend yet.
  static List<CardTransaction> _candidates(MoneyData money, Set<String> newIDs, List<Trend> trends) {
    final inTrends = {for (final t in trends) ...t.cardIDs};
    return CardData(money).cardTransactions
        .where((t) => newIDs.contains(t.id) && t.isVariable && t.myAmount > 0 && !inTrends.contains(t.id))
        .toList();
  }

  /// Puts the new charges of merchants with an "always" rule in their trend. Returns how many were assigned.
  static int applyRules(SaveFile file, Set<String> newIDs) {
    final money = file.money;
    final trends = _trends(money);
    final rules = money.merchantTrends;
    if (trends.isEmpty || rules.isEmpty) return 0;
    var assigned = 0;
    for (final t in _candidates(money, newIDs, trends)) {
      final trend = trends.where((x) => x.id == rules[t.merchantKey]).firstOrNull;
      if (trend == null) continue;
      JObj(trend.json).writeList('cardIDs').add(t.id);
      assigned++;
    }
    return assigned;
  }

  /// The new charges that aren't in a trend, merchant by merchant, each with a suggestion when there is one: first
  /// by a trend this merchant was put in before, then by the bank's category or the merchant's name against the
  /// trends' names. Empty when there are no trends. Those with a suggestion come first, then the bigger amounts.
  static List<TrendSuggestionItem> items(MoneyData money, Set<String> newIDs) {
    final trends = _trends(money);
    if (trends.isEmpty) return [];
    final all = CardData(money).cardTransactions;
    final keyOf = {for (final t in all) t.id: t.merchantKey};
    final items = <String, TrendSuggestionItem>{};
    for (final t in _candidates(money, newIDs, trends)) {
      final item = items[t.merchantKey];
      if (item == null) {
        items[t.merchantKey] = TrendSuggestionItem(t.merchantKey, t.merchant, t.category, [t.id], t.myAmount, null, '');
      } else {
        items[t.merchantKey] = TrendSuggestionItem(item.merchantKey, item.merchant, item.category.isEmpty ? t.category : item.category,
            [...item.cardIDs, t.id], item.total + t.myAmount, null, '');
      }
    }
    for (final item in items.values) {
      // 1. A trend that already has charges of this merchant (the one with the most of them).
      var best = 0;
      for (final trend in trends) {
        final count = trend.cardIDs.where((id) => keyOf[id] == item.merchantKey).length;
        if (count > best) {
          best = count;
          item.trendID = trend.id;
          item.reason = 'history';
        }
      }
      if (item.trendID != null) continue;
      // 2. The bank's category against the trends' names, then the merchant's name.
      final category = _n(item.category), merchant = _n(item.merchant);
      for (final trend in trends) {
        final name = _n(trend.name);
        if (name.length >= 2 && category.isNotEmpty && (category.contains(name) || name.contains(category))) {
          item.trendID = trend.id;
          item.reason = 'category';
          break;
        }
      }
      if (item.trendID != null) continue;
      for (final trend in trends) {
        final name = _n(trend.name);
        if (name.length >= 3 && merchant.contains(name)) {
          item.trendID = trend.id;
          item.reason = 'name';
          break;
        }
      }
    }
    return items.values.toList()
      ..sort((a, b) {
        if ((a.trendID == null) != (b.trendID == null)) return a.trendID == null ? 1 : -1;
        if ((a.total - b.total).abs() > 0.005) return b.total.compareTo(a.total);
        return a.merchantKey.compareTo(b.merchantKey);
      });
  }

  /// Assigns a merchant's new charges to a trend; `always` also remembers it for the next statements.
  static void assign(SaveFile file, TrendSuggestionItem item, String trendID, {bool always = false}) {
    final money = file.money;
    final trend = _trends(money).where((t) => t.id == trendID).firstOrNull;
    if (trend == null) return;
    final ids = JObj(trend.json).writeList('cardIDs');
    for (final id in item.cardIDs) {
      if (!ids.contains(id)) ids.add(id);
    }
    if (always) money.merchantTrends = {...money.merchantTrends, item.merchantKey: trendID};
  }

  // MARK: One request to the model for what the rules above couldn't place

  static const aiSystem = 'אתה מסווג עסקאות אשראי למגמות — קבוצות הוצאה שהמשתמש הגדיר. ענה אך ורק ב-JSON תקין, בלי שום טקסט נוסף: '
      'אובייקט שהמפתחות בו הם המספרים של בתי העסק, והערך של כל אחד הוא שם המגמה בדיוק כפי שהוא ברשימה, או null כשאף מגמה לא מתאימה. '
      'אל תנחש: כשלא ברור — null.';

  /// The merchants without a suggestion, numbered, and the trends' names.
  static String aiPrompt(MoneyData money, List<TrendSuggestionItem> items) {
    final open = items.where((i) => i.trendID == null).toList();
    final lines = ['המגמות:', for (final t in _trends(money)) '- ${t.name}', '', 'בתי העסק:'];
    for (var i = 0; i < open.length; i++) {
      lines.add('${i + 1}. ${open[i].merchant}${open[i].category.isEmpty ? '' : ' (קטגוריה: ${open[i].category})'}');
    }
    return lines.join('\n');
  }

  /// Reads the model's answer into the items it was asked about. Returns how many got a suggestion.
  static int applyAIAnswer(MoneyData money, List<TrendSuggestionItem> items, String raw) {
    final first = raw.indexOf('{'), last = raw.lastIndexOf('}');
    if (first < 0 || last <= first) return 0;
    dynamic object;
    try {
      object = jsonDecode(raw.substring(first, last + 1));
    } catch (_) {
      return 0;
    }
    if (object is! Map) return 0;
    final open = items.where((i) => i.trendID == null).toList();
    final trends = _trends(money);
    var placed = 0;
    for (final e in object.entries) {
      final index = int.tryParse('${e.key}'.trim());
      final value = e.value;
      if (index == null || index < 1 || index > open.length || value is! String) continue;
      final trend = trends.where((t) => _n(t.name) == _n(value) && _n(value).isNotEmpty).firstOrNull;
      if (trend == null || open[index - 1].trendID != null) continue;
      open[index - 1]
        ..trendID = trend.id
        ..reason = 'ai';
      placed++;
    }
    return placed;
  }
}
