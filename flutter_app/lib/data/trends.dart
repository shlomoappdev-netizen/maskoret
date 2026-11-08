import 'card.dart';
import 'fmt.dart';
import 'json.dart';
import 'models.dart';
import 'money_calc.dart';

/// A user-defined group of spending (e.g. "דייטים") that cuts across card categories — port of Trends.swift.
class Trend {
  Trend(this.json);
  final Json json;
  JObj get _o => JObj(json);

  String get id => _o.s('id');
  String get name => _o.s('name');
  String get emoji => _o.s('emoji', '🏷️');
  double get monthlyLimit => _o.d('monthlyLimit');
  List<String> get cardIDs => ((_o.raw('cardIDs') as List?) ?? const []).whereType<String>().toList();
  List<String> get transactionIDs => ((_o.raw('transactionIDs') as List?) ?? const []).whereType<String>().toList();
  Map<String, dynamic> get shares => (_o.raw('shares') as Map?)?.cast<String, dynamic>() ?? const {};
  List<Json> get entries => _o.objects('entries');

  static Json create({String name = '', String emoji = '🏷️', double monthlyLimit = 0}) => {
        'id': newId(),
        'name': name,
        'emoji': emoji,
        'cardIDs': <dynamic>[],
        'shares': <String, dynamic>{},
        'transactionIDs': <dynamic>[],
        'entries': <dynamic>[],
        'monthlyLimit': jsonNumber(monthlyLimit),
        'createdAt': dateTimeToSwift(DateTime.now()),
      };

  static const suggestions = [
    ('💕', 'דייטים'),
    ('🎁', 'מתנות'),
    ('🍔', 'אוכל בחוץ'),
    ('🎉', 'יציאות עם חברים'),
    ('🚕', 'מוניות'),
    ('☕️', 'קפה'),
    ('🎮', 'תחביבים'),
    ('✈️', 'חופשות'),
  ];
}

enum TrendSource { card, transaction, manual }

/// One line in a trend, whatever its source.
class TrendItem {
  TrendItem(this.source, this.sourceId, this.date, this.title, this.detail, this.amount, this.fullAmount);
  final TrendSource source;
  final String sourceId;
  final DateTime date;
  final String title;
  final String detail;
  final double amount;

  /// The full charge when only part of it is counted.
  final double? fullAmount;

  int get monthKey => date.year * 100 + date.month;
}

class TrendMonth {
  TrendMonth(this.key, this.amount);
  final int key;
  final double amount;
}

class TrendStats {
  double total = 0;
  int count = 0;
  double thisMonth = 0;
  double lastMonth = 0;
  double monthlyAverage = 0;

  /// The last 6 months, oldest first.
  List<TrendMonth> months = [];
}

/// The calculations of the MoneyData extension in Trends.swift.
class TrendCalc {
  /// Everything in a trend, newest first. Months are by purchase date.
  static List<TrendItem> items(MoneyData money, Trend trend) {
    final result = <TrendItem>[];
    final cards = <String, CardTransaction>{};
    for (final t in CardData(money).cardTransactions) {
      cards.putIfAbsent(t.id, () => t);
    }
    final shares = trend.shares;
    for (final id in trend.cardIDs) {
      final t = cards[id];
      if (t == null) continue;
      final share = (shares[id] as num?)?.toDouble();
      result.add(TrendItem(
          TrendSource.card,
          id,
          t.date,
          t.merchant,
          'אשראי${t.cardLast4.isEmpty ? '' : ' ${t.cardLast4}'}${t.note.isEmpty ? '' : ' · ${t.note}'}',
          share ?? t.amount,
          share == null ? null : t.amount));
    }
    final transactions = money.transactions;
    for (final id in trend.transactionIDs) {
      final t = transactions.where((x) => x.id == id).firstOrNull;
      if (t == null) continue;
      final sign = t.kind == TransactionKind.income ? -1 : 1;
      result.add(TrendItem(TrendSource.transaction, id, t.date, t.title, 'תנועה', sign * t.amount, null));
    }
    for (final e in trend.entries) {
      final o = JObj(e);
      final note = o.s('note');
      result.add(TrendItem(TrendSource.manual, o.s('id'), o.date('date') ?? DateTime.now(),
          note.isEmpty ? 'הוצאה ידנית' : note, 'ידני / מזומן', o.d('amount'), null));
    }
    return result..sort((a, b) => b.date.compareTo(a.date));
  }

  static TrendStats stats(MoneyData money, Trend trend, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final list = items(money, trend);
    int key(DateTime d) => d.year * 100 + d.month;
    final byMonth = <int, double>{};
    for (final i in list) {
      byMonth[i.monthKey] = (byMonth[i.monthKey] ?? 0) + i.amount;
    }
    final s = TrendStats()
      ..total = list.fold(0.0, (a, i) => a + i.amount)
      ..count = list.length
      ..thisMonth = byMonth[key(at)] ?? 0
      ..lastMonth = byMonth[key(addMonths(at, -1))] ?? 0
      ..months = [
        for (var back = 5; back >= 0; back--) TrendMonth(key(addMonths(at, -back)), byMonth[key(addMonths(at, -back))] ?? 0)
      ];
    // Average over the months since the first item (at least 1).
    if (list.isNotEmpty) {
      final first = list.map((i) => i.date).reduce((a, b) => a.isBefore(b) ? a : b);
      final months = wholeMonths(DateTime(first.year, first.month, first.day), at) + 1;
      s.monthlyAverage = s.total / (months < 1 ? 1 : months);
    }
    return s;
  }
}

/// The Store actions of Trends.swift, on one member's data.
class TrendActions {
  TrendActions(this.file);
  final SaveFile file;

  JObj get _money => JObj.lazy(file.json, 'money');
  Json? _trend(String id) => _money.objects('trends').where((t) => t['id'] == id).firstOrNull;

  void upsert(Json trend) => _money.upsertById('trends', trend);
  void delete(String id) => _money.removeWhere('trends', (t) => t['id'] == id);

  void toggleCard(String cardID, String trendID) {
    final t = _trend(trendID);
    if (t == null) return;
    final ids = JObj(t).writeList('cardIDs');
    if (ids.remove(cardID)) {
      (t['shares'] as Map?)?.remove(cardID);
    } else {
      ids.add(cardID);
    }
  }

  void toggleTransaction(String id, String trendID) {
    final t = _trend(trendID);
    if (t == null) return;
    final ids = JObj(t).writeList('transactionIDs');
    if (!ids.remove(id)) ids.add(id);
  }

  /// Count only `amount` of a card charge in the trend (null = the whole charge).
  void setShare(double? amount, String cardID, String trendID) {
    final t = _trend(trendID);
    if (t == null) return;
    final shares = (t['shares'] ??= <String, dynamic>{}) as Map;
    if (amount == null) {
      shares.remove(cardID);
    } else {
      shares[cardID] = jsonNumber(amount);
    }
  }

  void removeItem(TrendItem item, String trendID) {
    final t = _trend(trendID);
    if (t == null) return;
    switch (item.source) {
      case TrendSource.card:
        (t['cardIDs'] as List?)?.remove(item.sourceId);
        (t['shares'] as Map?)?.remove(item.sourceId);
      case TrendSource.transaction:
        (t['transactionIDs'] as List?)?.remove(item.sourceId);
      case TrendSource.manual:
        JObj(t).removeWhere('entries', (e) => e['id'] == item.sourceId);
    }
  }

  void addEntry(String trendID, {required DateTime date, required double amount, String note = ''}) {
    final t = _trend(trendID);
    if (t == null) return;
    JObj(t).addObject('entries', {'id': newId(), 'date': dateTimeToSwift(date), 'amount': jsonNumber(amount), 'note': note});
  }
}

/// All the trends' limits together, against the latest income and the recent average (TrendLimitsSummary in
/// TrendsView.swift).
class TrendLimits {
  TrendLimits._(this.count, this.total, this.spentThisMonth, this.lastIncome, this.lastLabel, this.averageIncome, this.months);

  /// Trends with a monthly limit.
  final int count;
  final double total;

  /// What the trends with a limit spent this month.
  final double spentThisMonth;

  /// The last saved month's net (actual, or its estimate), or the current estimate when nothing is saved.
  final double lastIncome;
  final String lastLabel;

  /// The average of the last (up to 3) saved months, when there are at least 2.
  final double? averageIncome;
  final int months;

  bool get overLast => lastIncome > 0 && total > lastIncome;
  bool get overAverage => (averageIncome ?? 0) > 0 && total > averageIncome!;

  String? get warning {
    if (overLast) return 'סך התקרות גבוה מההכנסה האחרונה ב-${Fmt.money(total - lastIncome)}. כדאי להוריד תקרות.';
    if (overAverage) return 'סך התקרות גבוה מממוצע ההכנסות האחרונות ב-${Fmt.money(total - averageIncome!)}.';
    return null;
  }

  /// Null when no trend has a limit.
  static TrendLimits? of(SaveFile file, {DateTime? now}) {
    final money = file.money;
    final limited = JObj(money.raw).objects('trends').map(Trend.new).where((t) => t.monthlyLimit > 0).toList();
    if (limited.isEmpty) return null;
    final total = limited.fold(0.0, (s, t) => s + t.monthlyLimit);
    final spent = limited.fold(0.0, (s, t) {
      final m = TrendCalc.stats(money, t, now: now).thisMonth;
      return s + (m > 0 ? m : 0);
    });
    double net(MonthRecord r) {
      final b = r.json['budget'];
      return r.actualNet ?? (b is Json ? Budget(JObj(b)).net : 0);
    }

    final recent = (file.history..sort((a, b) => b.sortKey.compareTo(a.sortKey))).take(3).toList();
    final first = recent.firstOrNull;
    return TrendLimits._(
      limited.length,
      total,
      spent,
      first != null ? net(first) : file.budget.net,
      first != null ? 'ההכנסה האחרונה (${Fmt.monthTitle(first.year, first.month)})' : 'ההכנסה החודשית המשוערת',
      recent.length >= 2 ? recent.fold(0.0, (s, r) => s + net(r)) / recent.length : null,
      recent.length,
    );
  }
}
