import 'package:flutter/material.dart';

import '../data/fmt.dart';
import '../data/json.dart';
import '../data/models.dart';
import '../data/money_calc.dart';
import '../data/month_picture.dart';
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
      // The same number as "נשאר בסוף החודש" in the iPhone/Mac app.
      final pic = MonthPicture.of(store.file, now.year, now.month);
      final remaining = pic.remaining;
      final members = store.members;
      final positive = remaining >= 0;
      final error = theme.colorScheme.error;

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
        SectionCard(
          title: 'מה נשאר בסוף החודש',
          subtitle: 'הנטו, פחות הוצאות קבועות, קניות חוזרות, חיסכון ואשראי, ועם התנועות החד-פעמיות',
          children: [
            AmountRow(pic.isActual ? 'נטו בפועל (מהתלוש)' : 'נטו משוער', pic.net, bold: true),
            if (pic.spending.isNotEmpty) ...[
              _Header('הוצאות קבועות', pic.spendingTotal),
              for (final l in pic.spending) AmountRow(l.title, l.amount, negative: true),
            ],
            if (pic.periodic > 0) AmountRow('קניות חוזרות (ממוצע לחודש)', pic.periodic, negative: true),
            if (pic.toSavings.isNotEmpty) ...[
              _Header('לחיסכון', pic.toSavingsTotal),
              for (final l in pic.toSavings) AmountRow(l.title, l.amount, negative: true),
            ],
            if (pic.card.isNotEmpty) ...[
              _Header(pic.cardEstimated ? 'אשראי (הערכה — הפירוט של החודש עוד לא יובא)' : 'אשראי', pic.cardTotal),
              for (final l in pic.card) AmountRow(l.title, l.amount, negative: true),
            ],
            if (pic.installments.isNotEmpty) ...[
              _Header('תשלומים באשראי', pic.installmentsTotal),
              for (final l in pic.installments) AmountRow(l.title, l.amount, negative: true, detail: l.detail),
            ],
            if (pic.oneOffs.isNotEmpty) ...[
              _Header('תנועות החודש', pic.oneOffTotal),
              for (final l in pic.oneOffs) AmountRow(l.title, l.amount.abs(), negative: l.amount < 0),
            ],
            const Divider(indent: 16, endIndent: 16),
            AmountRow('נשאר', remaining, bold: true, color: positive ? null : error),
            if (pic.installmentsAfterThisMonth > 0)
              AmountRow('תשלומים שנשארו לחודשים הבאים', pic.installmentsAfterThisMonth,
                  detail: 'לא יורד החודש — מוצג לידיעה'),
          ],
        ),
        SectionCard(title: 'הכסף שלך עכשיו', subtitle: 'הערכה לפי היתרות שעדכנת והתנועות מאז', children: [
          AmountRow('עו״ש', calc.total(money, {AccountKind.checking})),
          AmountRow('חסכונות ופיקדונות', calc.total(money, {AccountKind.savings, AccountKind.deposit})),
          AmountRow('פנסיה', calc.total(money, {AccountKind.pension})),
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

/// A sub-heading inside the month breakdown, with its total.
class _Header extends StatelessWidget {
  const _Header(this.title, this.total);
  final String title;
  final double total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(children: [
        Expanded(child: Text(title, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary))),
        Text(Fmt.money(total.abs()), textDirection: TextDirection.rtl, style: theme.textTheme.labelLarge),
      ]),
    );
  }
}
