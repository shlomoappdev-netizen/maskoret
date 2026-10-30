import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../data/fmt.dart';
import '../data/forecast.dart';
import '../data/json.dart';
import '../data/models.dart';
import '../data/money_calc.dart';
import '../data/month_picture.dart';
import 'common.dart';
import 'theme.dart';

/// The current month: what's left, where the net goes, the money now — the same layout as SummaryView.swift.
class SummaryScreen extends StatelessWidget {
  const SummaryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final b = store.budget;
      final money = store.money;
      final calc = MoneyCalc(money.primeRate);
      final now = DateTime.now();
      // The same number as "נשאר בסוף החודש" in the iPhone/Mac app.
      final pic = MonthPicture.of(store.file, now.year, now.month);
      final members = store.members;
      final wide = isWide(context);
      final checking = calc.total(money, {AccountKind.checking});
      final savings = calc.total(money, {AccountKind.savings, AccountKind.deposit});
      final forecast = Forecaster.run(store.file);
      final last = forecast.last;

      final hero = _Hero(pic: pic);
      final donut = pic.net > 0 ? _NetDonut(pic: pic) : null;
      final breakdown = SectionCard(title: 'החודש — מהנטו ועד מה שנשאר', children: monthBreakdown(context, pic));
      final payslip = b.gross > 0
          ? SectionCard(title: 'מהברוטו לנטו (הערכה לפי התלוש)', children: payslipBreakdown(context, b))
          : null;
      final stats = _StatsGrid(pic: pic, budget: b);

      return PageList(children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            icon: const Icon(Icons.event_available, size: 18),
            label: Text(pic.isActual ? 'עדכן נטו בפועל' : 'רשום נטו בפועל'),
            onPressed: () => showSaveMonth(context),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('העתק סיכום'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _shareText(pic, checking, savings)));
              showMessage(context, 'הסיכום הועתק');
            },
          ),
        ]),
        const SizedBox(height: 14),
        if (wide && donut != null)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: hero),
            const SizedBox(width: 14),
            Expanded(child: donut),
          ])
        else ...[
          hero,
          if (donut != null) ...[const SizedBox(height: 14), donut],
        ],
        const SizedBox(height: 14),
        TileGrid(minWidth: 130, children: [
          StatTile(title: 'עו״ש עכשיו (משוער)', value: Fmt.money(checking), icon: Icons.credit_card),
          StatTile(title: 'חיסכון ופיקדונות', value: Fmt.money(savings), icon: Icons.lock_outline),
          StatTile(title: 'בעוד ${last.index} חודשים (עו״ש + חיסכון)', value: Fmt.money(last.liquid), icon: Icons.trending_up),
          StatTile(title: 'פנסיה', value: Fmt.money(calc.total(money, {AccountKind.pension})), icon: Icons.beach_access_outlined),
        ]),
        const SizedBox(height: 14),
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Column(children: [breakdown, ?payslip])),
            const SizedBox(width: 14),
            SizedBox(width: 340, child: stats),
          ])
        else ...[
          breakdown,
          ?payslip,
          stats,
        ],
        if (members.length > 1)
          SectionCard(title: 'נטו לפי בן משפחה', subtitle: 'כל אחד לפי התלוש שלו', children: [
            for (final m in members) AmountRow(m.title, store.family.file(m.id)?.budget.net ?? 0),
          ]),
      ]);
    });
  }

  static String _shareText(MonthPicture p, double checking, double savings) {
    String m(double v) => Fmt.money((v * 100).round() / 100);
    final lines = ['סיכום ${p.title} — מחשבון שכר', ''];
    lines.add('${p.isActual ? 'נטו בפועל: ' : 'נטו (משוער): '}${m(p.net)}');
    for (final l in p.spending) {
      lines.add('  − ${l.title}: ${Fmt.money(l.amount)}');
    }
    if (p.periodic > 0) lines.add('  − רכישות תקופתיות: ${m(p.periodic)}');
    for (final l in p.card) {
      lines.add('  − 💳 ${l.title}: ${m(l.amount)}');
    }
    for (final l in p.installments) {
      lines.add('  − 🗓 ${l.title}: ${m(l.amount)} (${l.detail})');
    }
    for (final l in p.toSavings) {
      lines.add('  → ${l.title}: ${Fmt.money(l.amount)}');
    }
    for (final l in p.oneOffs) {
      lines.add('  ± ${l.title}: ${Fmt.money(l.amount)}');
    }
    lines
      ..add('')
      ..add('נשאר בסוף החודש: ${m(p.remaining)}')
      ..add('עו״ש עכשיו (משוער): ${Fmt.money(checking)}')
      ..add('חיסכון ופיקדונות: ${Fmt.money(savings)}');
    return lines.join('\n');
  }
}

/// "נשאר לך בסוף החודש" on the teal → blue gradient (red when negative), with three small numbers under it.
class _Hero extends StatelessWidget {
  const _Hero({required this.pic});
  final MonthPicture pic;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final positive = pic.remaining >= 0;
    Widget mini(String title, double value) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: theme.textTheme.labelMedium?.copyWith(color: Colors.white.withValues(alpha: 0.75))),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(Fmt.money(value),
                  textDirection: TextDirection.rtl,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600, fontFeatures: tabular)),
            ),
          ]),
        );
    return Container(
      constraints: BoxConstraints(minHeight: isWide(context) ? 262 : 230),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: positive ? const [AppColors.teal, AppColors.blue] : const [AppColors.red1, AppColors.red2],
        ),
        boxShadow: [
          BoxShadow(
            color: (positive ? AppColors.teal : AppColors.red1).withValues(alpha: 0.35),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('נשאר לך בסוף החודש',
            style: theme.textTheme.titleMedium?.copyWith(color: Colors.white.withValues(alpha: 0.85), fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(Fmt.money(pic.remaining),
              textDirection: TextDirection.rtl,
              style: theme.textTheme.displayMedium
                  ?.copyWith(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 52, fontFeatures: tabular, height: 1.1)),
        ),
        const SizedBox(height: 26),
        Row(children: [
          mini(pic.isActual ? 'נטו בפועל' : 'נטו (משוער)', pic.net),
          const SizedBox(width: 12),
          mini('הוצאות', pic.spendingTotal + pic.periodic + pic.cardWithInstallments),
          const SizedBox(width: 12),
          mini('לחיסכון', pic.toSavingsTotal),
        ]),
      ]),
    );
  }
}

/// "לאן הולך הנטו": a donut with its legend beside it (under it on a phone).
class _NetDonut extends StatelessWidget {
  const _NetDonut({required this.pic});
  final MonthPicture pic;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = [
      ('הוצאות קבועות', pic.spendingTotal, AppColors.pink),
      ('רכישות תקופתיות', pic.periodic, AppColors.purple),
      ('כרטיס אשראי (משתנות)', pic.cardTotal, AppColors.tealChart),
      ('תשלומים (החלק של החודש)', pic.installmentsTotal, AppColors.indigo),
      ('לחיסכון', pic.toSavingsTotal, AppColors.sky),
      ('הוצאות חריגות', pic.oneOffTotal < 0 ? -pic.oneOffTotal : 0.0, AppColors.orange),
      ('נשאר', pic.remaining > 0 ? pic.remaining : 0.0, AppColors.green),
    ].where((i) => i.$2 > 0).toList();
    final total = items.fold(0.0, (s, i) => s + i.$2).clamp(1.0, double.infinity);
    final donut = SizedBox(
      width: 170,
      height: 170,
      child: Stack(alignment: Alignment.center, children: [
        PieChart(PieChartData(
          sectionsSpace: 2,
          centerSpaceRadius: 54,
          startDegreeOffset: -90,
          sections: [
            for (final i in items) PieChartSectionData(value: i.$2, color: i.$3, radius: 31, showTitle: false),
          ],
        )),
        Column(mainAxisSize: MainAxisSize.min, children: [
          Text(pic.isActual ? 'נטו בפועל' : 'נטו', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          Text(Fmt.money(pic.net),
              textDirection: TextDirection.rtl,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, fontFeatures: tabular)),
        ]),
      ]),
    );
    final legend = Column(mainAxisSize: MainAxisSize.min, children: [
      for (final i in items)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Container(width: 9, height: 9, decoration: BoxDecoration(color: i.$3, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(child: Text(i.$1, style: theme.textTheme.bodyMedium)),
            Text(Fmt.money(i.$2), textDirection: TextDirection.rtl, style: theme.textTheme.bodyMedium?.copyWith(fontFeatures: tabular)),
            SizedBox(
              width: 44,
              child: Text(Fmt.percent((i.$2 / total * 100).roundToDouble()),
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontFeatures: tabular)),
            ),
          ]),
        ),
    ]);
    return Glass(
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('לאן הולך הנטו', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, c) => c.maxWidth >= 420
              ? Row(children: [donut, const SizedBox(width: 18), Expanded(child: legend)])
              : Column(children: [donut, const SizedBox(height: 14), legend]),
        ),
      ]),
    );
  }
}

/// The small numbers beside the breakdown (statsGrid in SummaryView.swift).
class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.pic, required this.budget});
  final MonthPicture pic;
  final Budget budget;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final daysLeft = DateTime(now.year, now.month + 1).difference(DateTime(now.year, now.month, now.day)).inDays.clamp(1, 31);
    String pct(double v) => Fmt.percent((v * 1000).roundToDouble() / 10);
    final spent = pic.spendingTotal + pic.periodic + pic.cardWithInstallments;
    final diff = pic.net - pic.estimatedNet;
    final tiles = [
      StatTile(title: 'תקציב יומי ($daysLeft ימים נשארו)', value: Fmt.money(pic.remaining / daysLeft), icon: Icons.wb_sunny_outlined),
      StatTile(title: 'חיסכון מהנטו', value: pic.net > 0 ? pct(pic.toSavingsTotal / pic.net) : '—', icon: Icons.savings_outlined),
      StatTile(title: 'הוצאות מהנטו', value: pic.net > 0 ? pct(spent / pic.net) : '—', icon: Icons.bar_chart),
      if (pic.installmentsAfterThisMonth > 0.005)
        StatTile(title: 'תשלומים לחודשים הבאים', value: Fmt.money(pic.installmentsAfterThisMonth), icon: Icons.event_repeat),
      StatTile(title: 'נשאר בשנה (בקצב הזה)', value: Fmt.money(pic.remaining * 12), icon: Icons.calendar_today),
      if (pic.isActual)
        StatTile(title: 'בפועל מול הערכה', value: '${diff >= 0 ? '+' : '−'}${Fmt.money(diff.abs())}', icon: Icons.exposure),
      if (budget.gross > 0)
        StatTile(title: 'ניכויים מהברוטו', value: pct(budget.totalDeductions / budget.gross), icon: Icons.percent),
      if (budget.totalHours > 0)
        StatTile(title: 'נטו לשעת עבודה', value: Fmt.money((pic.net / budget.totalHours * 100).roundToDouble() / 100), icon: Icons.schedule),
    ];
    return Padding(padding: const EdgeInsets.only(bottom: 14), child: TileGrid(minWidth: 130, children: tiles));
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
