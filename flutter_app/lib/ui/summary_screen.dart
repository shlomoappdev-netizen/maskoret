import 'package:flutter/material.dart';

import '../data/fmt.dart';
import '../data/json.dart';
import '../data/models.dart';
import '../data/money_calc.dart';
import 'common.dart';

/// The current month: from gross to net, where the net goes, and what's left — like SummaryView.swift.
class SummaryScreen extends StatelessWidget {
  const SummaryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final theme = Theme.of(context);
      final b = store.budget;
      final money = store.money;
      final calc = MoneyCalc(money.primeRate);
      final now = DateTime.now();
      final remaining = b.remaining;
      final members = store.members;
      final positive = remaining >= 0;

      final thisMonth = money.transactions.where((t) => t.date.year == now.year && t.date.month == now.month).toList()
        ..sort((a, c) => a.date.compareTo(c.date));

      return PageList(children: [
        Card(
          color: positive ? theme.colorScheme.primaryContainer : theme.colorScheme.errorContainer,
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(children: [
              Text('נשאר לך בסוף החודש', style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(Fmt.money(remaining),
                  textDirection: TextDirection.rtl,
                  style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(Fmt.monthTitle(now.year, now.month), style: theme.textTheme.bodyMedium),
            ]),
          ),
        ),
        SectionCard(title: 'מהברוטו לנטו', subtitle: 'הערכה לפי התלוש', children: [
          AmountRow('ברוטו', b.gross),
          for (final d in b.deductions.where((d) => d.isActive && b.deductionAmount(d) != 0))
            AmountRow(d.name, b.deductionAmount(d), negative: true, color: theme.colorScheme.error),
          if (b.netIncomes != 0) AmountRow('הכנסות נטו (ללא ניכויים)', b.netIncomes),
          const Divider(indent: 16, endIndent: 16),
          AmountRow('נטו', b.net, bold: true),
        ]),
        SectionCard(title: 'לאן הולך הנטו', children: [
          for (final e in b.expenses.where((e) => e.isActive))
            AmountRow(e.name, e.amount(b.expenseBase),
                negative: true,
                detail: e.targetAccountID != null ? 'עובר ל${money.account(e.targetAccountID)?.name ?? 'חשבון'}' : null),
          if (b.periodicTotal > 0)
            AmountRow('קניות חוזרות (ממוצע לחודש)', b.periodicTotal, negative: true),
          const Divider(indent: 16, endIndent: 16),
          AmountRow('נשאר', remaining, bold: true, color: positive ? null : theme.colorScheme.error),
        ]),
        SectionCard(title: 'הכסף שלך עכשיו', subtitle: 'הערכה לפי היתרות שעדכנת והתנועות מאז', children: [
          AmountRow('עו״ש', calc.total(money, {AccountKind.checking})),
          AmountRow('חסכונות ופיקדונות', calc.total(money, {AccountKind.savings, AccountKind.deposit})),
          AmountRow('פנסיה', calc.total(money, {AccountKind.pension})),
        ]),
        if (thisMonth.isNotEmpty)
          SectionCard(title: 'תנועות החודש', children: [
            for (final t in thisMonth)
              AmountRow(t.title, t.amount,
                  negative: t.kind == TransactionKind.expense,
                  detail: '${Fmt.date(t.date)}${t.isPlanned ? ' · מתוכנן' : ''}${t.paidByCard ? ' · באשראי' : ''}'),
          ]),
        if (members.length > 1)
          SectionCard(title: 'נטו לפי בן משפחה', subtitle: 'כל אחד לפי התלוש שלו', children: [
            for (final m in members)
              AmountRow(m.title, store.family.file(m.id)?.budget.net ?? 0),
          ]),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.bookmark_add_outlined),
            label: Text('שמירת ${Fmt.monthTitle(now.year, now.month)} בהיסטוריה'),
            onPressed: () => _saveMonth(context, now),
          ),
        ),
      ]);
    });
  }

  /// Port of `Store.saveMonth`: a copy of the budget, the actual net, and optionally the salary into checking.
  Future<void> _saveMonth(BuildContext context, DateTime now) async {
    final store = context.store;
    final year = now.year, month = now.month;
    final existing = store.file.history.where((r) => r.year == year && r.month == month).firstOrNull;
    var note = existing?.note ?? '';
    double actual = existing?.actualNet ?? 0;
    var addToChecking = false;
    await showEditor(
      context,
      title: 'שמירת ${Fmt.monthTitle(year, month)}',
      builder: (ctx, setState) => Column(children: [
        NumberField(
          label: 'משכורת בפועל (נטו לתשלום)',
          value: actual,
          suffix: '₪',
          helper: 'הסכום ״נטו לתשלום״ מהתלוש (לא חובה).',
          onChanged: (v) => actual = v,
        ),
        gap,
        TextInput(label: 'הערה (לא חובה)', initial: note, onChanged: (v) => note = v),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('להוסיף את המשכורת לעו״ש'),
          value: addToChecking,
          onChanged: (v) => setState(() => addToChecking = v),
        ),
        if (existing != null)
          const Text('החודש הזה כבר שמור — השמירה תחליף את הרשומה הקיימת.'),
      ]),
      onSave: () => store.edit((f) {
        final record = <String, dynamic>{
          'id': existing?.id ?? newId(),
          'year': year,
          'month': month,
          'note': note,
          'budget': deepCopy(f.json['budget'] ?? Starter.budget()),
          'savedAt': dateTimeToSwift(DateTime.now()),
          if (actual > 0) 'actualNet': jsonNumber(actual),
        };
        f.upsertRecord(record);
        final key = year * 100 + month;
        f.money.removeTransactionsWhere((t) => t['salaryKey'] == key);
        if (addToChecking && actual > 0) {
          final checking = f.money.ensureChecking();
          final monthEnd = DateTime(year, month + 1, 0, 12);
          final date = DateTime.now().isBefore(monthEnd) ? DateTime.now() : monthEnd;
          f.money.upsertTransaction({
            ...MoneyTransaction.create(kind: TransactionKind.income, accountID: checking.id),
            'date': dateTimeToSwift(date),
            'title': 'משכורת ${Fmt.monthNames[month - 1]}',
            'amount': jsonNumber(actual),
            'salaryKey': key,
          });
        }
      }),
    );
  }
}
