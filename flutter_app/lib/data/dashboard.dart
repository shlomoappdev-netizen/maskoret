import 'json.dart';
import 'models.dart';

/// What the summary, forecast and sidebar look at: one member's data, or several members merged into one household
/// view — port of `DataSnapshot.combine` (Family.swift). The result is a throwaway SaveFile, so every calculation
/// (MonthPicture, Forecaster…) runs on it unchanged. Each member's tax is calculated on their own payslip, so the
/// household gets everyone's *net*; percent expenses become their amount in shekels.
class Dashboard {
  static SaveFile combine(List<(FamilyMember, SaveFile)> parts, SaveFile base) {
    final budget = deepCopy(base.json['budget'] ?? <String, dynamic>{}) as Json;
    final incomes = <dynamic>[], expenses = <dynamic>[], tracked = <dynamic>[];
    budget['incomes'] = incomes;
    budget['deductions'] = <dynamic>[];
    budget['expenses'] = expenses;
    budget['trackedItems'] = tracked;

    final baseMoney = base.money.raw;
    final accounts = <dynamic>[], transactions = <dynamic>[], cards = <dynamic>[], rules = <dynamic>[];
    final receivables = <dynamic>[], imports = <dynamic>[], trends = <dynamic>[];
    final money = <String, dynamic>{
      for (final k in ['forecast', 'primeRate', 'primeAuto', 'boiRate', 'primeCheckedAt', 'nextRateDecision', 'rateLastChanged'])
        if (baseMoney[k] != null) k: deepCopy(baseMoney[k]),
      'accounts': accounts,
      'transactions': transactions,
      'cardTransactions': cards,
      'merchantRules': rules,
      'receivables': receivables,
      'cardImports': imports,
      'trends': trends,
    };
    final seenCards = <String>{};
    final records = <int, List<MonthRecord>>{};

    for (final (member, file) in parts) {
      final b = file.budget;
      final tag = '${member.emoji} ';
      incomes.add({
        'id': newId(),
        'name': '${member.title} — נטו',
        'kind': 'fixed',
        'amount': jsonNumber(b.net),
        'hours': 0,
        'hourlyRate': 0,
        'isActive': true,
        'isNet': true,
      });
      for (final e in b.expenses.where((e) => e.isActive)) {
        final item = deepCopy(e.json) as Json
          ..['kind'] = 'fixed'
          ..['value'] = jsonNumber(e.amount(b.expenseBase))
          ..remove('auto')
          ..['name'] = tag + e.name;
        expenses.add(item);
      }
      for (final t in JObj(file.json['budget'] as Json? ?? {}).objects('trackedItems')) {
        tracked.add(deepCopy(t)..['name'] = tag + (t['name'] as String? ?? ''));
      }
      final m = JObj(file.money.raw);
      for (final a in m.objects('accounts')) {
        accounts.add(deepCopy(a)..['name'] = tag + (a['name'] as String? ?? ''));
      }
      transactions.addAll(m.objects('transactions').map(deepCopy));
      // The same card imported by two members counts once.
      for (final t in m.objects('cardTransactions')) {
        if (seenCards.add(t['id'] as String? ?? '')) cards.add(deepCopy(t));
      }
      rules.addAll(m.objects('merchantRules').map(deepCopy));
      for (final r in m.objects('receivables')) {
        receivables.add(deepCopy(r)..['person'] = tag + (r['person'] as String? ?? ''));
      }
      imports.addAll(m.objects('cardImports').map(deepCopy));
      for (final t in m.objects('trends')) {
        trends.add(deepCopy(t)..['name'] = tag + (t['name'] as String? ?? ''));
      }
      for (final r in file.history) {
        (records[r.sortKey] ??= []).add(r);
      }
    }
    imports.sort((a, b) => ((b['importedAt'] as num?) ?? 0).compareTo((a['importedAt'] as num?) ?? 0));
    if (accounts.isEmpty) accounts.add(Account.create(name: 'עו״ש', kind: AccountKind.checking));

    // A month counts as "actual" only when every member recorded their actual net.
    final now = dateTimeToSwift(DateTime.now());
    final history = [
      for (final e in records.entries)
        () {
          final actuals = e.value.map((r) => r.actualNet).whereType<double>().toList();
          return {
            'id': newId(),
            'year': e.key ~/ 100,
            'month': e.key % 100,
            'note': '',
            'budget': budget,
            'savedAt': now,
            if (actuals.length == parts.length) 'actualNet': jsonNumber(actuals.fold(0.0, (s, v) => s + v)),
          };
        }(),
    ];
    return SaveFile({'budget': budget, 'history': history, 'money': money});
  }
}
