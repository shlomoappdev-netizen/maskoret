import 'package:flutter/material.dart';

import '../data/fmt.dart';
import '../data/json.dart';
import '../data/models.dart';
import 'common.dart';

// MARK: - Incomes

class IncomesScreen extends StatelessWidget {
  const IncomesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final b = store.budget;
      return Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          icon: const Icon(Icons.add),
          label: const Text('הכנסה'),
          onPressed: () => editIncome(context, null),
        ),
        body: PageList(children: [
          SectionCard(
            title: 'הכנסות',
            subtitle: 'ברוטו ${Fmt.money(b.gross)}${b.netIncomes > 0 ? ' · נטו נוסף ${Fmt.money(b.netIncomes)}' : ''}',
            children: [
              if (b.incomes.isEmpty) const EmptyHint('עוד אין הכנסות. הוסף את המשכורת שלך.'),
              for (final i in b.incomes)
                ListTile(
                  leading: Switch(
                    value: i.isActive,
                    onChanged: (v) => store.edit((f) => IncomeItem(i.json).isActive = v),
                  ),
                  title: Text(i.name.isEmpty ? 'הכנסה' : i.name),
                  subtitle: Text((i.kind == IncomeKind.fixed
                          ? 'סכום חודשי קבוע'
                          : '${Fmt.number(i.hours)} שעות × ${Fmt.money(i.hourlyRate)}') +
                      (i.isNet ? ' · נטו, ללא ניכויים' : ' · ברוטו')),
                  trailing: Text(Fmt.money(i.rawTotal), textDirection: TextDirection.rtl,
                      style: Theme.of(context).textTheme.titleMedium),
                  onTap: () => editIncome(context, i),
                ),
            ],
          ),
        ]),
      );
    });
  }

  static Future<void> editIncome(BuildContext context, IncomeItem? existing) async {
    final store = context.store;
    // A copy of the original object: unknown fields come along unchanged.
    final draft = IncomeItem(existing != null ? deepCopy(existing.json) as Json : IncomeItem.create());
    await showEditor(
      context,
      title: existing == null ? 'הכנסה חדשה' : 'עריכת הכנסה',
      builder: (ctx, setState) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextInput(label: 'שם', initial: draft.name, autofocus: existing == null, onChanged: (v) => draft.name = v),
        gap,
        SegmentedButton<IncomeKind>(
          segments: const [
            ButtonSegment(value: IncomeKind.fixed, label: Text('סכום חודשי')),
            ButtonSegment(value: IncomeKind.hourly, label: Text('לפי שעות')),
          ],
          selected: {draft.kind},
          onSelectionChanged: (s) => setState(() => draft.kind = s.first),
        ),
        gap,
        if (draft.kind == IncomeKind.fixed)
          NumberField(label: 'סכום לחודש', suffix: '₪', value: draft.amount, onChanged: (v) => draft.amount = v)
        else
          Row(children: [
            Expanded(child: NumberField(label: 'שעות', value: draft.hours, onChanged: (v) => setState(() => draft.hours = v))),
            const SizedBox(width: 12),
            Expanded(
                child: NumberField(
                    label: 'לשעה', suffix: '₪', value: draft.hourlyRate, onChanged: (v) => setState(() => draft.hourlyRate = v))),
          ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('הסכום כבר נטו'),
          subtitle: const Text('למשל משכורת צבאית — לא יורדים ממנו מס וניכויים'),
          value: draft.isNet,
          onChanged: (v) => setState(() => draft.isNet = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('פעיל החודש'),
          value: draft.isActive,
          onChanged: (v) => setState(() => draft.isActive = v),
        ),
      ]),
      onSave: () => store.edit((f) {
        if (draft.name.trim().isEmpty) draft.name = 'הכנסה';
        f.budget.upsertIncome(draft.json);
      }),
      onDelete: existing == null ? null : () => store.edit((f) => f.budget.removeIncome(existing.id)),
    );
  }
}

// MARK: - Deductions

class DeductionsScreen extends StatelessWidget {
  const DeductionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final b = store.budget;
      final ts = b.taxSettings;
      final missing = AutoDeduction.values.where((t) => !b.hasAuto(t)).toList();
      return Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          icon: const Icon(Icons.add),
          label: const Text('ניכוי'),
          onPressed: () => _add(context, missing),
        ),
        body: PageList(children: [
          SectionCard(
            title: 'ניכויים מהתלוש',
            subtitle: 'סה״כ ${Fmt.money(b.totalDeductions)} מתוך ברוטו ${Fmt.money(b.gross)}',
            children: [
              if (b.deductions.isEmpty) const EmptyHint('אין ניכויים.'),
              for (final d in b.deductions)
                ListTile(
                  leading: Switch(value: d.isActive, onChanged: (v) => store.edit((f) => CostItem(d.json).isActive = v)),
                  title: Text(d.name),
                  subtitle: Text(_detail(d)),
                  trailing: Text(Fmt.money(b.rawDeductionAmount(d)), textDirection: TextDirection.rtl,
                      style: Theme.of(context).textTheme.titleMedium),
                  onTap: () => _edit(context, d),
                ),
            ],
          ),
          SectionCard(
            title: 'הגדרות מס',
            subtitle: 'נתוני ${b.rates.year} (עודכן ${b.rates.updated})',
            children: [
              ListTile(
                title: const Text('נקודות זיכוי'),
                subtitle: const Text('2.25 לגבר תושב, 2.75 לאישה תושבת, ועוד לפי הנסיבות'),
                trailing: Text(Fmt.number(ts.creditPoints), style: Theme.of(context).textTheme.titleMedium),
                onTap: () => _editTax(context),
              ),
              ListTile(
                title: const Text('פנסיה'),
                subtitle: Text(ts.pensionMode.title +
                    (ts.pensionMode == PensionMode.startsLater && ts.pensionStart != null
                        ? ' — ${Fmt.date(ts.pensionStart!)}'
                        : '')),
                onTap: () => _editTax(context),
              ),
            ],
          ),
        ]),
      );
    });
  }

  static String _detail(CostItem d) {
    switch (d.kind) {
      case CostKind.automatic:
        final a = d.auto;
        if (a == null) return 'אוטומטי';
        return a.usesPercent ? 'אוטומטי · ${Fmt.percent(d.value)} מהברוטו' : 'מחושב אוטומטית לפי השיעורים הרשמיים';
      case CostKind.percent:
        return '${Fmt.percent(d.value)} מהברוטו';
      case CostKind.fixed:
        return 'סכום קבוע';
    }
  }

  Future<void> _add(BuildContext context, List<AutoDeduction> missing) async {
    final store = context.store;
    if (missing.isEmpty) return editCost(context, null, deductions: true);
    final choice = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(leading: const Icon(Icons.edit_note), title: const Text('ניכוי ידני (סכום או אחוז)'),
              onTap: () => Navigator.pop(ctx, 'manual')),
          const Divider(),
          for (final t in missing)
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: Text(t.title),
              subtitle: Text(t.explanation, maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(ctx, t),
            ),
        ]),
      ),
    );
    if (!context.mounted) return;
    if (choice == 'manual') {
      await editCost(context, null, deductions: true);
    } else if (choice is AutoDeduction) {
      store.edit((f) => f.budget.upsertDeduction(CostItem.automatic(choice)));
    }
  }

  Future<void> _edit(BuildContext context, CostItem d) async {
    if (d.kind != CostKind.automatic) return editCost(context, d, deductions: true);
    final store = context.store;
    final draft = CostItem(deepCopy(d.json) as Json);
    final type = d.auto;
    await showEditor(
      context,
      title: d.name,
      builder: (ctx, setState) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (type != null) Text(type.explanation),
        gap,
        TextInput(label: 'שם', initial: draft.name, onChanged: (v) => draft.name = v),
        if (type?.usesPercent == true) ...[
          gap,
          NumberField(label: 'אחוז מהברוטו', suffix: '%', value: draft.value, onChanged: (v) => draft.value = v),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('פעיל'),
          value: draft.isActive,
          onChanged: (v) => setState(() => draft.isActive = v),
        ),
      ]),
      onSave: () => store.edit((f) => f.budget.upsertDeduction(draft.json)),
      onDelete: () => store.edit((f) => f.budget.removeDeduction(d.id)),
    );
  }

  Future<void> _editTax(BuildContext context) async {
    final store = context.store;
    final ts = store.budget.taxSettings;
    var points = ts.creditPoints;
    var mode = ts.pensionMode;
    var start = ts.pensionStart;
    await showEditor(
      context,
      title: 'הגדרות מס',
      builder: (ctx, setState) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        NumberField(
          label: 'נקודות זיכוי',
          value: points,
          helper: '2.25 לגבר תושב, 2.75 לאישה תושבת. נקודות נוספות: ילדים, חייל משוחרר, תואר ועוד.',
          onChanged: (v) => points = v,
        ),
        gap,
        Text('הפרשה לפנסיה', style: Theme.of(ctx).textTheme.titleSmall),
        for (final m in PensionMode.values)
          RadioListTile<PensionMode>(
            contentPadding: EdgeInsets.zero,
            title: Text(m.title),
            value: m,
            groupValue: mode,
            onChanged: (v) => setState(() => mode = v!),
          ),
        if (mode == PensionMode.startsLater)
          DateField(label: 'ההפרשה מתחילה ב-', value: start, onChanged: (v) => setState(() => start = v)),
      ]),
      onSave: () => store.edit((f) {
        final t = f.budget.taxSettings;
        t.creditPoints = points;
        t.pensionMode = mode;
        if (mode == PensionMode.startsLater) t.pensionStart = start;
      }),
    );
  }
}

// MARK: - Fixed expenses

class ExpensesScreen extends StatelessWidget {
  const ExpensesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final b = store.budget;
      final money = store.money;
      return Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          icon: const Icon(Icons.add),
          label: const Text('הוצאה'),
          onPressed: () => editCost(context, null, deductions: false),
        ),
        body: PageList(children: [
          SectionCard(
            title: 'הוצאות קבועות',
            subtitle: 'סה״כ ${Fmt.money(b.totalExpenses)} מתוך נטו ${Fmt.money(b.net)}',
            children: [
              if (b.expenses.isEmpty) const EmptyHint('עוד אין הוצאות קבועות.'),
              for (final e in b.expenses)
                ListTile(
                  leading: Switch(value: e.isActive, onChanged: (v) => store.edit((f) => CostItem(e.json).isActive = v)),
                  title: Text(e.name),
                  subtitle: Text([
                    if (e.kind == CostKind.percent) '${Fmt.percent(e.value)} מהנטו' else 'סכום קבוע',
                    if (e.targetAccountID != null) 'עובר ל${money.account(e.targetAccountID)?.name ?? 'חשבון'}',
                  ].join(' · ')),
                  trailing: Text(Fmt.money(e.rawAmount(b.expenseBase)), textDirection: TextDirection.rtl,
                      style: Theme.of(context).textTheme.titleMedium),
                  onTap: () => editCost(context, e, deductions: false),
                ),
            ],
          ),
          if (b.periodicTotal > 0)
            SectionCard(
              title: 'קניות חוזרות',
              subtitle: 'נעליים, בגדים, טלפון… — העריכה שלהן באפליקציה לאייפון ולמק',
              children: [AmountRow('ממוצע לחודש', b.periodicTotal)],
            ),
        ]),
      );
    });
  }
}

/// Editing a manual deduction (percent of gross) or a fixed expense (percent of net).
Future<void> editCost(BuildContext context, CostItem? existing, {required bool deductions}) async {
  final store = context.store;
  final draft = CostItem(existing != null ? deepCopy(existing.json) as Json : CostItem.create());
  final savings = store.money.accounts.where((a) => a.kind != AccountKind.checking).toList();
  await showEditor(
    context,
    title: existing == null ? (deductions ? 'ניכוי חדש' : 'הוצאה חדשה') : existing.name,
    builder: (ctx, setState) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextInput(label: 'שם', initial: draft.name, autofocus: existing == null, onChanged: (v) => draft.name = v),
      gap,
      SegmentedButton<CostKind>(
        segments: [
          const ButtonSegment(value: CostKind.fixed, label: Text('סכום קבוע')),
          ButtonSegment(value: CostKind.percent, label: Text(deductions ? 'אחוז מהברוטו' : 'אחוז מהנטו')),
        ],
        selected: {draft.kind == CostKind.percent ? CostKind.percent : CostKind.fixed},
        onSelectionChanged: (s) => setState(() => draft.kind = s.first),
      ),
      gap,
      NumberField(
        key: ValueKey(draft.kind),
        label: draft.kind == CostKind.percent ? 'אחוז' : 'סכום לחודש',
        suffix: draft.kind == CostKind.percent ? '%' : '₪',
        value: draft.value,
        onChanged: (v) => draft.value = v,
      ),
      if (!deductions && savings.isNotEmpty) ...[
        gap,
        DropdownButtonFormField<String?>(
          initialValue: savings.any((a) => a.id == draft.targetAccountID) ? draft.targetAccountID : null,
          decoration: const InputDecoration(
            labelText: 'הכסף עובר לחשבון',
            helperText: 'למשל חיסכון חודשי — הכסף לא נעלם, הוא עובר לחשבון',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem(value: null, child: Text('לא — זו הוצאה')),
            for (final a in savings) DropdownMenuItem(value: a.id, child: Text(a.name)),
          ],
          onChanged: (v) => draft.targetAccountID = v,
        ),
      ],
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('פעיל'),
        value: draft.isActive,
        onChanged: (v) => setState(() => draft.isActive = v),
      ),
    ]),
    onSave: () => store.edit((f) {
      if (draft.name.trim().isEmpty) draft.name = 'ללא שם';
      deductions ? f.budget.upsertDeduction(draft.json) : f.budget.upsertExpense(draft.json);
    }),
    onDelete: existing == null
        ? null
        : () => store.edit((f) => deductions ? f.budget.removeDeduction(existing.id) : f.budget.removeExpense(existing.id)),
  );
}
