import 'dart:convert';

import '../data/fmt.dart';
import '../data/json.dart';
import '../data/models.dart';
import '../data/trends.dart';

/// One change the model proposes in an ```actions block — port of AIActions.swift (same block, same fields).
/// Things are found by name in the data of the member being edited; nothing changes until the user approves.
class AIAction {
  AIAction(this.id, this.type, this.fields);
  final int id;
  final String type;
  final Map<String, dynamic> fields;

  static const types = {
    'add_account', 'update_account', 'add_trend', 'update_trend', 'add_expense', 'update_expense', 'add_transaction',
  };

  String? string(String key) {
    final v = fields[key];
    if (v is String) {
      final t = v.trim();
      return t.isEmpty ? null : t;
    }
    if (v is num) return v.toString();
    return null;
  }

  double? number(String key) {
    final v = fields[key];
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.replaceAll(RegExp(r'[^0-9.\-]'), ''));
    return null;
  }

  bool? boolean(String key) {
    final v = fields[key];
    if (v is bool) return v;
    if (v is String) return const ['true', 'כן', 'yes', '1'].contains(v.toLowerCase());
    return null;
  }

  DateTime? date(String key) {
    final s = string(key);
    if (s == null) return null;
    final iso = RegExp(r'^(\d{4})-(\d{1,2})(?:-(\d{1,2}))?$').firstMatch(s);
    if (iso != null) {
      return DateTime(int.parse(iso[1]!), int.parse(iso[2]!), int.tryParse(iso[3] ?? '') ?? 1, 12);
    }
    final dmy = RegExp(r'^(\d{1,2})[./](\d{1,2})[./](\d{4})$').firstMatch(s);
    if (dmy != null) return DateTime(int.parse(dmy[3]!), int.parse(dmy[2]!), int.parse(dmy[1]!), 12);
    return null;
  }

  String _m(double v) => Fmt.money(v);

  String get icon => switch (type) {
        'add_account' || 'update_account' => 'account',
        'add_trend' || 'update_trend' => 'trend',
        'add_expense' || 'update_expense' => 'expense',
        _ => 'transaction',
      };

  String get title => switch (type) {
        'add_account' => 'חשבון חדש: ${string('name') ?? ''}',
        'update_account' => 'עדכון חשבון: ${string('account') ?? string('name') ?? ''}',
        'add_trend' => 'מגמה חדשה: ${string('name') ?? ''}',
        'update_trend' => 'עדכון מגמה: ${string('trend') ?? string('name') ?? ''}',
        'add_expense' => 'הוצאה קבועה חדשה: ${string('name') ?? ''}',
        'update_expense' => 'עדכון הוצאה קבועה: ${string('expense') ?? string('name') ?? ''}',
        _ => '${switch (string('kind')) { 'income' => 'הכנסה', 'transfer' => 'העברה', _ => 'הוצאה' }} חד-פעמית: '
            '${string('title') ?? string('name') ?? ''}',
      };

  List<String> get details {
    final out = <String>[];
    final kind = AccountKind.values.where((k) => k.name == string('kind')).firstOrNull;
    if (type == 'add_account' && kind != null) out.add('סוג: ${kind.title}');
    final balance = number('balance');
    if (balance != null) out.add('יתרה: ${_m(balance)}${string('balance_date') != null ? ' (נכון ל-${string('balance_date')})' : ''}');
    final rate = number('annual_rate');
    if (rate != null) out.add('ריבית שנתית: ${Fmt.percent(rate)}');
    if (string('rate_type') == 'prime') {
      final pm = number('prime_minus');
      out.add('צמוד לפריים${pm != null ? ' מינוס ${Fmt.percent(pm)}' : ''}');
    }
    final contribution = number('monthly_contribution');
    if (contribution != null) out.add('הפקדה חודשית: ${_m(contribution)}');
    if (string('start_date') != null) out.add('התחלה: ${string('start_date')}');
    if (string('maturity_date') != null) out.add('סיום: ${string('maturity_date')}');
    final limit = number('monthly_limit');
    if (limit != null) out.add(limit > 0 ? 'תקרה חודשית: ${_m(limit)}' : 'בלי תקרה');
    if (string('new_name') != null) out.add('שם חדש: ${string('new_name')}');
    final amount = number('amount');
    if (amount != null) out.add('סכום: ${_m(amount)}');
    final day = number('charge_day');
    if (day != null) out.add('יורד ב-${day.toInt()} לחודש');
    if (string('to_account') != null) {
      out.add(type == 'add_transaction' ? 'אל: ${string('to_account')}' : 'מועבר לחיסכון: ${string('to_account')}');
    }
    if (type == 'add_transaction') {
      if (string('account') != null) out.add('מ: ${string('account')}');
      if (string('date') != null) out.add('תאריך: ${string('date')}');
      if (boolean('paid_by_card') == true) {
        final n = (number('installments') ?? 1).toInt();
        out.add(n > 1 ? 'באשראי, $n תשלומים' : 'באשראי');
      }
    }
    final active = boolean('active');
    if (active != null) out.add(active ? 'פעילה' : 'מושבתת');
    if (string('note') != null) out.add('הערה: ${string('note')}');
    if (string('why') != null) out.add('למה: ${string('why')}');
    return out;
  }
}

class AIActionPlan {
  AIActionPlan(this.summary, this.actions);
  final String summary;
  final List<AIAction> actions;

  /// Reads the JSON of an ```actions block; unknown action types are left out.
  static AIActionPlan? decode(String raw) {
    var json = raw
        .replaceAll('“', '"')
        .replaceAll('”', '"')
        .replaceAll('„', '"')
        .replaceAll(' ', ' ')
        .trim();
    final first = json.indexOf(RegExp(r'[\{\[]'));
    final last = json.lastIndexOf(RegExp(r'[\}\]]'));
    if (first >= 0 && last > first) json = json.substring(first, last + 1);
    dynamic object;
    try {
      object = jsonDecode(json);
    } catch (_) {
      return null;
    }
    var summary = '';
    var list = <dynamic>[];
    if (object is Map) {
      summary = object['summary'] is String ? object['summary'] as String : '';
      list = object['actions'] is List ? object['actions'] as List : const [];
    } else if (object is List) {
      list = object;
    }
    final actions = <AIAction>[];
    for (var i = 0; i < list.length; i++) {
      final item = list[i];
      if (item is Map && item['type'] is String && AIAction.types.contains(item['type'])) {
        actions.add(AIAction(i, item['type'] as String, item.cast<String, dynamic>()));
      }
    }
    return actions.isEmpty ? null : AIActionPlan(summary, actions);
  }
}

class AIActionError implements Exception {
  AIActionError(this.message);
  final String message;
  @override
  String toString() => message;
}

String _normalized(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

/// Finds by name, forgiving the family emoji the summary puts in front of names and small differences.
Json? _find(List<Json> items, String? name) {
  if (name == null) return null;
  final wanted = _normalized(name);
  for (final i in items) {
    if (_normalized(i['name'] as String? ?? '') == wanted) return i;
  }
  for (final i in items) {
    final n = _normalized(i['name'] as String? ?? '');
    if (n.isNotEmpty && (n.contains(wanted) || wanted.contains(n))) return i;
  }
  return null;
}

/// Applies one approved change to the member being edited (inside AppStore.edit).
void applyAIAction(AIAction a, SaveFile file) {
  final money = JObj.lazy(file.json, 'money');
  final budget = JObj.lazy(file.json, 'budget');
  Json account(String name) =>
      _find(money.objects('accounts'), name) ?? (throw AIActionError('לא נמצא חשבון בשם ״$name״'));

  switch (a.type) {
    case 'add_account':
      final name = a.string('name') ?? (throw AIActionError('חסר שם לחשבון'));
      final kind = AccountKind.values.where((k) => k.name == a.string('kind')).firstOrNull ?? AccountKind.savings;
      final json = Account.create(name: name, kind: kind);
      _fill(json, a);
      money.addObject('accounts', json);
    case 'update_account':
      final name = a.string('account') ?? a.string('name') ?? '';
      final json = account(name);
      if (a.string('new_name') != null) json['name'] = a.string('new_name');
      _fill(json, a);
    case 'add_trend':
      final name = a.string('name') ?? (throw AIActionError('חסר שם למגמה'));
      money.addObject('trends', Trend.create(name: name, emoji: a.string('emoji') ?? '🏷️', monthlyLimit: (a.number('monthly_limit') ?? 0).clamp(0, double.infinity).toDouble()));
    case 'update_trend':
      final name = a.string('trend') ?? a.string('name') ?? '';
      final t = _find(money.objects('trends'), name) ?? (throw AIActionError('לא נמצאה מגמה בשם ״$name״'));
      final limit = a.number('monthly_limit');
      if (limit != null) t['monthlyLimit'] = jsonNumber(limit < 0 ? 0 : limit);
      if (a.string('new_name') != null) t['name'] = a.string('new_name');
      if (a.string('emoji') != null) t['emoji'] = a.string('emoji');
    case 'add_expense':
      final name = a.string('name') ?? (throw AIActionError('חסר שם להוצאה'));
      final amount = a.number('amount') ?? (throw AIActionError('חסר סכום'));
      final json = CostItem.create(name: name, value: amount.abs());
      final day = a.number('charge_day');
      if (day != null) json['chargeDay'] = day.toInt().clamp(1, 31);
      final target = a.string('to_account');
      if (target != null) json['targetAccountID'] = account(target)['id'];
      budget.addObject('expenses', json);
    case 'update_expense':
      final name = a.string('expense') ?? a.string('name') ?? '';
      final e = _find(budget.objects('expenses'), name) ?? (throw AIActionError('לא נמצאה הוצאה קבועה בשם ״$name״'));
      final amount = a.number('amount');
      if (amount != null) {
        e['value'] = jsonNumber(amount.abs());
        e['kind'] = 'fixed';
      }
      final active = a.boolean('active');
      if (active != null) e['isActive'] = active;
      final day = a.number('charge_day');
      if (day != null) e['chargeDay'] = day.toInt().clamp(1, 31);
      if (a.string('new_name') != null) e['name'] = a.string('new_name');
    case 'add_transaction':
      final amount = a.number('amount') ?? (throw AIActionError('חסר סכום'));
      final kind = TransactionKind.values.where((k) => k.name == a.string('kind')).firstOrNull ?? TransactionKind.expense;
      final from = a.string('account');
      final checking = money.objects('accounts').where((x) => x['kind'] == 'checking').firstOrNull;
      final json = MoneyTransaction.create(kind: kind, accountID: from != null ? account(from)['id'] as String? : checking?['id'] as String?);
      json['title'] = a.string('title') ?? a.string('name') ?? 'תנועה';
      json['amount'] = jsonNumber(amount.abs());
      json['date'] = dateTimeToSwift(a.date('date') ?? DateTime.now());
      if (a.string('note') != null) json['note'] = a.string('note');
      final to = a.string('to_account');
      if (to != null) json['toAccountID'] = account(to)['id'];
      if (kind == TransactionKind.expense && a.boolean('paid_by_card') == true) {
        json['paidByCard'] = true;
        final n = (a.number('installments') ?? 1).toInt();
        json['cardInstallments'] = n < 1 ? 1 : n;
      }
      money.addObject('transactions', json);
  }
}

void _fill(Json account, AIAction a) {
  final o = JObj(account);
  final kind = AccountKind.values.where((k) => k.name == a.string('kind')).firstOrNull;
  if (kind != null) account['kind'] = kind.name;
  final balance = a.number('balance');
  if (balance != null) {
    o.addObject('balances', {
      'id': newId(),
      'date': dateTimeToSwift(a.date('balance_date') ?? DateTime.now()),
      'amount': jsonNumber(balance),
      'note': 'עודכן על ידי ה-AI',
    });
  }
  final rate = a.number('annual_rate');
  if (rate != null) account['annualRate'] = jsonNumber(rate);
  final rateType = a.string('rate_type');
  if (rateType == 'fixed' || rateType == 'prime') account['rateType'] = rateType;
  final pm = a.number('prime_minus');
  if (pm != null) {
    account['primeMinus'] = jsonNumber(pm);
    if (rateType == null) account['rateType'] = 'prime';
  }
  final contribution = a.number('monthly_contribution');
  if (contribution != null) account['monthlyContribution'] = jsonNumber(contribution < 0 ? 0 : contribution);
  final day = a.number('contribution_day');
  if (day != null) account['contributionDay'] = day.toInt().clamp(1, 28);
  final tax = a.number('interest_tax');
  if (tax != null) account['interestTax'] = jsonNumber(tax);
  final start = a.date('start_date');
  if (start != null) account['startDate'] = dateTimeToSwift(start);
  final maturity = a.date('maturity_date');
  if (maturity != null) account['maturityDate'] = dateTimeToSwift(maturity);
  if (a.string('note') != null) account['note'] = a.string('note');
}
