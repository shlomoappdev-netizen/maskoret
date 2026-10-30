import 'package:flutter/material.dart';

import '../data/fmt.dart';
import '../data/json.dart';
import '../data/maaser.dart';
import '../data/models.dart';
import 'common.dart';
import 'theme.dart';

MaaserSettings _read(SaveFile f) => MaaserSettings(JObj((f.money.raw['maaser'] as Json?) ?? <String, dynamic>{}));

String _balanceText(double v) => v.abs() < 0.5 ? '0' : '${v > 0 ? 'חוב' : 'זכות'} ${Fmt.money(v.abs())}';
Color _balanceColor(double v) => v > 0.5 ? Colors.orange.shade700 : Colors.green.shade700;

/// Maaser: what's owed from each month's actual net, what was given, and the running balance — MaaserView.swift.
class MaaserScreen extends StatelessWidget {
  const MaaserScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final s = _read(store.file);
      if (!s.enabled) return const _Intro();
      final status = MaaserCalc.status(store.file);
      final theme = Theme.of(context);
      return Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          heroTag: 'donation',
          icon: const Icon(Icons.add),
          label: const Text('נתתי מעשרות'),
          onPressed: () => showDonation(context),
        ),
        body: PageList(children: [
          Row(children: [
            Expanded(child: Text('${Fmt.percent(s.percent)} · ${s.base.title}', style: theme.textTheme.bodySmall)),
            TextButton.icon(
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('הגדרות'),
              onPressed: () => Navigator.push(context, glassRoute((_) => const MaaserSettingsScreen())),
            ),
          ]),
          const SizedBox(height: 8),
          TileGrid(minWidth: 150, children: [
            StatTile(
              title: status.balance > 0.5 ? 'חוב למעשרות' : (status.balance < -0.5 ? 'זכות (ניתן מעבר)' : 'מאוזן'),
              value: Fmt.money(status.balance.abs()),
              icon: Icons.volunteer_activism,
              valueColor: _balanceColor(status.balance),
            ),
            StatTile(title: 'צריך לתת החודש', value: Fmt.money(status.thisMonthOwed), icon: Icons.calendar_today),
            StatTile(title: 'ניתן החודש', value: Fmt.money(status.thisMonthPaid), icon: Icons.back_hand_outlined),
            StatTile(title: 'ניתן השנה', value: Fmt.money(status.paidThisYear), icon: Icons.functions),
          ]),
          const SizedBox(height: 14),
          if (status.missingMonths.isNotEmpty) ...[
            Glass(
              tint: Colors.orange.withValues(alpha: 0.12),
              padding: const EdgeInsets.all(14),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.error, color: Colors.orange.shade700),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      'עוד לא נרשם נטו בפועל ל: ${status.missingMonths.map((k) => Fmt.monthTitle(k ~/ 100, k % 100)).join(', ')}',
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'החובה של חודש נכנסת לחשבון רק אחרי שרושמים את הנטו בפועל (בסיכום ← ״רשום נטו בפועל״, או בעמוד '
                      '״חודשים״). התרומות של החודש כבר נספרות.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 14),
          ],
          SectionCard(title: 'חודש אחרי חודש', children: [
            if (s.openingBalance != 0)
              ListTile(
                title: const Text('יתרת פתיחה'),
                trailing: Text(_balanceText(s.openingBalance),
                    style: TextStyle(color: _balanceColor(s.openingBalance), fontFeatures: tabular)),
              ),
            for (final m in status.months.reversed) _MonthRow(m: m),
            const EmptyHint('יתרה חיובית = חוב שעובר לחודש הבא. שלילית = נתת יותר, והעודף מקטין את מה שצריך לתת בהמשך.'),
          ]),
          _Giving(s: s, budget: store.budget),
        ]),
      );
    });
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.volunteer_activism, size: 56, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text('מעשרות', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              'האפליקציה תחשב כמה צריך לתת בכל חודש לפי הנטו שנרשם בפועל, תספור מה שכבר נתת (תרומה ידנית, הוראת קבע '
              'או חיוב אשראי), ותזכור את היתרה: חודש שלא נתת בו נשאר כחוב לחודשים הבאים, ועודף נשאר כזכות.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                context.store.edit((f) {
                  final m = MaaserSettings.of(f)..enabled = true;
                  if (m.startKey == 0) m.startKey = MaaserCalc.key(DateTime.now());
                });
                Navigator.push(context, glassRoute((_) => const MaaserSettingsScreen()));
              },
              child: const Text('הפעלה והגדרה'),
            ),
          ]),
        ),
      ),
    );
  }
}

class _MonthRow extends StatelessWidget {
  const _MonthRow({required this.m});
  final MaaserMonth m;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = m.base == null
        ? ''
        : [
            'משכורת: ${Fmt.money(m.salaryBase)}',
            if (m.interest > 0) 'ריבית: ${Fmt.money(m.interest)}',
            if (m.oneOffs > 0) 'הכנסות חד-פעמיות: ${Fmt.money(m.oneOffs)}',
            if (m.deducted > 0) 'פחות הוצאות שמורידות: ${Fmt.money(m.deducted)}',
          ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Text(Fmt.monthTitle(m.key ~/ 100, m.key % 100), style: const TextStyle(fontWeight: FontWeight.w500))),
          Text(_balanceText(m.balance),
              style: TextStyle(fontWeight: FontWeight.w700, color: _balanceColor(m.balance), fontFeatures: tabular)),
        ]),
        Text(
          '${m.base == null ? 'בסיס — לא נרשם' : 'בסיס ${Fmt.money(m.base!)}'} · צריך לתת ${Fmt.money(m.owed)} · ניתן ${Fmt.money(m.paid)}',
          style: theme.textTheme.bodySmall?.copyWith(fontFeatures: tabular),
        ),
        if (detail.isNotEmpty)
          Text(detail, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

class _Giving extends StatelessWidget {
  const _Giving({required this.s, required this.budget});
  final MaaserSettings s;
  final Budget budget;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final theme = Theme.of(context);
    final fixed = budget.expenses.where((e) => s.maaserExpenseIDs.contains(e.id)).toList();
    final donations = s.donations..sort((a, b) => b.date.compareTo(a.date));
    Widget label(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
          child: Text(t, style: const TextStyle(fontWeight: FontWeight.w500)),
        );
    return SectionCard(title: 'מה נחשב מעשרות', children: [
      if (fixed.isNotEmpty) ...[
        label('הוצאות קבועות (נספרות כל חודש):'),
        for (final e in fixed) AmountRow(e.name, e.amount(budget.expenseBase)),
      ],
      if (s.maaserMerchants.isNotEmpty) ...[
        label('בתי עסק באשראי (כל החיובים שלהם):'),
        for (final m in s.maaserMerchants)
          ListTile(
            dense: true,
            title: Text('• $m'),
            trailing: TextButton(
              onPressed: () => store.edit((f) => MaaserSettings.of(f).toggle('maaserMerchants', m, false)),
              child: const Text('הסר'),
            ),
          ),
      ],
      if (s.maaserCardIDs.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text('${s.maaserCardIDs.length} חיובי אשראי בודדים מסומנים כמעשרות', style: theme.textTheme.bodySmall),
        ),
      if (donations.isNotEmpty) ...[
        label('תרומות שרשמת:'),
        for (final d in donations)
          AmountRow(
            '${Fmt.date(d.date)}${d.note.isEmpty ? '' : ' · ${d.note}'}',
            d.amount,
            onTap: () async {
              if (await confirm(context, 'למחוק את התרומה?', 'התנועה בעו״ש (אם נרשמה) נשארת — אפשר למחוק אותה ב״תנועות״.',
                      ok: 'מחק') &&
                  context.mounted) {
                store.edit((f) => MaaserSettings.of(f).deleteDonation(d.id));
              }
            },
          ),
      ],
      const EmptyHint('סימון חיוב אשראי כמעשרות: בעמוד ״כרטיס אשראי״ ← ״צמד ל…״ ← מעשרות. הוראת קבע: בהגדרות המעשרות. '
          'לחיצה על תרומה מוחקת אותה.'),
    ]);
  }
}

/// "נתתי מעשרות" — DonationSheet.
Future<void> showDonation(BuildContext context) async {
  var date = DateTime.now();
  var amount = 0.0;
  var note = '';
  var fromChecking = true;
  await showEditor(
    context,
    title: 'נתתי מעשרות',
    builder: (context, setState) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DateField(label: 'תאריך', value: date, onChanged: (v) => setState(() => date = v ?? date)),
      const SizedBox(height: 12),
      NumberField(label: 'סכום', suffix: '₪', value: amount, autofocus: true, onChanged: (v) => amount = v),
      const SizedBox(height: 12),
      TextInput(label: 'למי / הערה', initial: note, onChanged: (v) => note = v),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('להוריד גם מהעו״ש (נרשם בתנועות)'),
        value: fromChecking,
        onChanged: (v) => setState(() => fromChecking = v),
      ),
      Text(
        'כבה את ההורדה מהעו״ש אם התרומה כבר רשומה במקום אחר (למשל חיוב אשראי או הוראת קבע), כדי שלא תיספר פעמיים בעו״ש.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ]),
    onSave: () {
      if (amount > 0) {
        context.store.edit((f) => MaaserCalc.addDonation(f, date: date, amount: amount, note: note.trim(), fromChecking: fromChecking));
      }
    },
  );
}

/// MaaserSettingsSheet — every change is saved right away, like the bindings in Swift.
class MaaserSettingsScreen extends StatelessWidget {
  const MaaserSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final s = _read(store.file);
      final theme = Theme.of(context);
      final budget = store.budget;
      void edit(void Function(MaaserSettings m) change) => store.edit((f) => change(MaaserSettings.of(f)));
      final yearAgo = DateTime.now().subtract(const Duration(days: 365));
      final oneOffs = store.money.transactions
          .where((t) => t.kind == TransactionKind.income && t.salaryKey == null && !t.date.isBefore(yearAgo))
          .toList()
        ..sort((a, b) => b.date.compareTo(a.date));
      final now = DateTime.now();
      final startYear = s.startKey > 0 ? s.startKey ~/ 100 : now.year;
      final startMonth = s.startKey > 0 ? s.startKey % 100 : now.month;
      return Scaffold(
        appBar: AppBar(title: const Text('הגדרות מעשרות')),
        body: PageList(children: [
          SectionCard(
            title: 'כמה',
            subtitle: 'הבסיס מחושב מהנטו שנרשם בפועל, ומחזירים אליו את הניכויים מהתלוש לפי מה שבחרת (למשל ״פחות מס הכנסה״ '
                '= הנטו + ביטוח לאומי, בריאות ופנסיה).',
            children: [
              _Percent(value: s.percent, onChanged: (v) => edit((m) => m.percent = v)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: DropdownButtonFormField<MaaserBase>(
                  initialValue: s.base,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'לחשב מתוך', border: OutlineInputBorder()),
                  items: [for (final b in MaaserBase.values) DropdownMenuItem(value: b, child: Text(b.title))],
                  onChanged: (v) => edit((m) => m.base = v!),
                ),
              ),
            ],
          ),
          SectionCard(title: 'מה נכנס לבסיס', children: [
            SwitchListTile(
              title: const Text('ריבית מחיסכונות ופיקדונות'),
              value: s.includeInterest,
              onChanged: (v) => edit((m) => m.includeInterest = v),
            ),
            SwitchListTile(
              title: const Text('הכנסות חד-פעמיות מ״תנועות״ (מתנות, בונוסים)'),
              value: s.includeOneOffs,
              onChanged: (v) => edit((m) => m.includeOneOffs = v),
            ),
            if (s.includeOneOffs)
              for (final t in oneOffs)
                CheckboxListTile(
                  dense: true,
                  contentPadding: const EdgeInsetsDirectional.only(start: 32, end: 16),
                  title: Text('${Fmt.date(t.date)} · ${t.title} · ${Fmt.money(t.amount)}'),
                  value: !s.excludedIncomeIDs.contains(t.id),
                  onChanged: (on) => edit((m) => m.toggle('excludedIncomeIDs', t.id, on != true)),
                ),
          ]),
          SectionCard(
            title: 'הוצאות קבועות',
            subtitle: '״נחשב מעשרות״ — למשל הוראת קבע לצדקה: נספר כל חודש כמה שניתן. ״מוריד מהבסיס״ — הוצאה שבגללה '
                'המעשרות נמוכים יותר (למשל נסיעות לעבודה).',
            children: [
              if (budget.expenses.isEmpty) const EmptyHint('אין הוצאות קבועות'),
              for (final e in budget.expenses)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${e.name} · ${Fmt.money(e.amount(budget.expenseBase))}',
                        style: const TextStyle(fontWeight: FontWeight.w500)),
                    Wrap(spacing: 8, children: [
                      FilterChip(
                        label: const Text('נחשב מעשרות'),
                        selected: s.maaserExpenseIDs.contains(e.id),
                        onSelected: (on) => edit((m) => m.toggle('maaserExpenseIDs', e.id, on)),
                      ),
                      FilterChip(
                        label: const Text('מוריד מהבסיס'),
                        selected: s.deductedExpenseIDs.contains(e.id),
                        onSelected: (on) => edit((m) => m.toggle('deductedExpenseIDs', e.id, on)),
                      ),
                    ]),
                  ]),
                ),
            ],
          ),
          SectionCard(title: 'התחלה', subtitle: 'מאיזה חודש לספור, ומה היה המצב לפני כן.', children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: startMonth,
                    decoration: const InputDecoration(labelText: 'חודש התחלה', border: OutlineInputBorder()),
                    items: [for (var i = 1; i <= 12; i++) DropdownMenuItem(value: i, child: Text(Fmt.monthNames[i - 1]))],
                    onChanged: (v) => edit((m) => m.startKey = startYear * 100 + v!),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: startYear,
                    decoration: const InputDecoration(labelText: 'שנה', border: OutlineInputBorder()),
                    items: [
                      for (var y = now.year - 10; y <= now.year; y++) DropdownMenuItem(value: y, child: Text('$y')),
                      if (startYear < now.year - 10) DropdownMenuItem(value: startYear, child: Text('$startYear')),
                    ],
                    onChanged: (v) => edit((m) => m.startKey = v! * 100 + startMonth),
                  ),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: true, label: Text('חוב שעוד לא נתתי')),
                  ButtonSegment(value: false, label: Text('זכות — נתתי מראש')),
                ],
                selected: {s.openingBalance >= 0},
                onSelectionChanged: (sel) => edit((m) => m.openingBalance = sel.first ? m.openingBalance.abs() : -m.openingBalance.abs()),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: NumberField(
                label: 'סכום יתרת הפתיחה',
                suffix: '₪',
                value: s.openingBalance.abs(),
                onChanged: (v) => edit((m) => m.openingBalance = m.openingBalance < 0 ? -v.abs() : v.abs()),
              ),
            ),
          ]),
          SectionCard(children: [
            ListTile(
              leading: Icon(Icons.power_settings_new, color: theme.colorScheme.error),
              title: Text('כיבוי מעשרות', style: TextStyle(color: theme.colorScheme.error)),
              subtitle: const Text('הכיבוי שומר את ההגדרות והתרומות — אפשר להפעיל שוב בכל זמן.'),
              onTap: () {
                edit((m) => m.enabled = false);
                Navigator.pop(context);
              },
            ),
          ]),
        ]),
      );
    });
  }
}

/// The percent, with "מעשר 10%" / "חומש 20%" that also update the field.
class _Percent extends StatefulWidget {
  const _Percent({required this.value, required this.onChanged});
  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_Percent> createState() => _PercentState();
}

class _PercentState extends State<_Percent> {
  var _version = 0;

  void _set(double v) {
    widget.onChanged(v);
    setState(() => _version++);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          NumberField(key: ValueKey(_version), label: 'אחוז', suffix: '%', value: widget.value, onChanged: widget.onChanged),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            OutlinedButton(onPressed: () => _set(10), child: const Text('מעשר 10%')),
            OutlinedButton(onPressed: () => _set(20), child: const Text('חומש 20%')),
          ]),
        ]),
      );
}
