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
          children: monthBreakdown(context, pic),
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
            onPressed: () => showSaveMonth(context),
          ),
        ),
      ]);
    });
  }
}

/// The lines of "מה נשאר בסוף החודש" (MonthBreakdown in SummaryView.swift) — the summary and the months screen.
List<Widget> monthBreakdown(BuildContext context, MonthPicture pic) {
  final error = Theme.of(context).colorScheme.error;
  return [
    AmountRow(pic.isActual ? 'נטו שנכנס בפועל' : 'נטו (משוער)', pic.net, bold: true),
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
    AmountRow('נשאר', pic.remaining, bold: true, color: pic.remaining >= 0 ? null : error),
    if (pic.installmentsAfterThisMonth > 0)
      AmountRow('תשלומים שנשארו לחודשים הבאים', pic.installmentsAfterThisMonth, detail: 'לא יורד החודש — מוצג לידיעה'),
  ];
}

/// "מהברוטו לנטו" of a budget (the payslip part of BudgetBreakdown).
List<Widget> payslipBreakdown(BuildContext context, Budget b) => [
      AmountRow('ברוטו', b.gross),
      for (final d in b.deductions.where((d) => d.isActive && b.deductionAmount(d) != 0))
        AmountRow(d.name, b.deductionAmount(d), negative: true, color: Theme.of(context).colorScheme.error),
      if (b.netIncomes != 0) AmountRow('הכנסות נטו (ללא ניכויים)', b.netIncomes),
      const Divider(indent: 16, endIndent: 16),
      AmountRow('נטו', b.net, bold: true),
    ];

/// What was left at the end of a saved month — like Store.monthResult (the current month uses today's budget).
MonthPicture monthResult(SaveFile file, MonthRecord r) {
  final now = DateTime.now();
  if (r.year == now.year && r.month == now.month) return MonthPicture.of(file, r.year, r.month);
  final budget = r.json['budget'];
  return MonthPicture.of(file, r.year, r.month, budgetOverride: budget is Json ? Budget(JObj(budget)) : null);
}

/// Saving a month in the history — port of SaveMonthSheet / Store.saveMonth: a copy of the budget, the actual
/// net from the payslip, and optionally the salary into the checking account.
Future<void> showSaveMonth(BuildContext context) async {
  final store = context.store;
  final now = DateTime.now();
  var year = now.year, month = now.month;
  MonthRecord? existing() => store.file.history.where((r) => r.year == year && r.month == month).firstOrNull;
  var note = existing()?.note ?? '';
  double actual = existing()?.actualNet ?? 0;
  var addToChecking = true;
  var version = 0; // rebuilds the fields when another month is chosen
  await showEditor(
    context,
    title: 'שמירת חודש בהיסטוריה${store.members.length > 1 ? ' — ${store.activeMember?.title ?? ''}' : ''}',
    builder: (ctx, setState) {
      void pick(int y, int m) => setState(() {
            year = y;
            month = m;
            note = existing()?.note ?? '';
            actual = existing()?.actualNet ?? 0;
            version++;
          });
      return Column(key: ValueKey(version), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<int>(
              initialValue: month,
              decoration: const InputDecoration(labelText: 'חודש', border: OutlineInputBorder()),
              items: [for (var m = 1; m <= 12; m++) DropdownMenuItem(value: m, child: Text(Fmt.monthNames[m - 1]))],
              onChanged: (v) => pick(year, v!),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<int>(
              initialValue: year,
              decoration: const InputDecoration(labelText: 'שנה', border: OutlineInputBorder()),
              items: [for (var y = now.year - 5; y <= now.year + 1; y++) DropdownMenuItem(value: y, child: Text('$y'))],
              onChanged: (v) => pick(v!, month),
            ),
          ),
        ]),
        gap,
        TextInput(label: 'הערה (לא חובה)', initial: note, onChanged: (v) => note = v),
        gap,
        NumberField(
          label: 'משכורת בפועל',
          value: actual,
          suffix: '₪',
          helper: 'הסכום ״נטו לתשלום״ מהתלוש. התחזית משתמשת בממוצע של החודשים האחרונים. ההוספה לעו״ש מעדכנת את היתרה '
              'המשוערת עד שתעדכן יתרה ידנית.',
          onChanged: (v) => actual = v,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('להוסיף את המשכורת לעו״ש'),
          value: addToChecking,
          onChanged: (v) => setState(() => addToChecking = v),
        ),
        Text(existing() != null
            ? 'החודש הזה כבר שמור — השמירה תחליף את הרשומה הקיימת.'
            : 'נשמר עותק של כל הנתונים הנוכחיים (הכנסות, ניכויים והוצאות).'),
      ]);
    },
    onSave: () => store.edit((f) {
      final old = f.history.where((r) => r.year == year && r.month == month).firstOrNull;
      f.upsertRecord({
        'id': old?.id ?? newId(),
        'year': year,
        'month': month,
        'note': note,
        'budget': deepCopy(f.json['budget'] ?? Starter.budget()),
        'savedAt': dateTimeToSwift(DateTime.now()),
        if (actual > 0) 'actualNet': jsonNumber(actual),
      });
      // Optionally record the salary as an income into the checking account.
      final key = year * 100 + month;
      f.money.removeTransactionsWhere((t) => t['salaryKey'] == key);
      final checking = f.money.checking;
      if (addToChecking && actual > 0 && checking != null) {
        final monthEnd = DateTime(year, month + 1, 0);
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
