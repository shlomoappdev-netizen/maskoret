import 'package:flutter/material.dart';

import '../data/fmt.dart';
import '../data/json.dart';
import '../data/models.dart';
import '../data/money_calc.dart';
import 'common.dart';
import 'tax_settings_screen.dart';
import 'theme.dart';

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
            title: 'יום המשכורת',
            subtitle: 'ביום הזה ״נשאר מההכנסה האחרונה״ מתחיל מחדש. אם המשכורת נכנסת בימים שונים, בחר את היום הרגיל.',
            children: [
              ListTile(
                title: Text('ב-${store.money.payDay} לחודש'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton.outlined(
                    tooltip: 'יום קודם',
                    icon: const Icon(Icons.remove, size: 18),
                    onPressed: store.money.payDay <= 1 ? null : () => store.edit((f) => f.money.payDay -= 1),
                  ),
                  const SizedBox(width: 8),
                  IconButton.outlined(
                    tooltip: 'יום הבא',
                    icon: const Icon(Icons.add, size: 18),
                    onPressed: store.money.payDay >= 31 ? null : () => store.edit((f) => f.money.payDay += 1),
                  ),
                ]),
              ),
            ],
          ),
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
              ListTile(
                leading: const Icon(Icons.percent),
                title: const Text('כל נתוני המס'),
                subtitle: const Text('מדרגות, ביטוח לאומי, עדכון השיעורים ומקורות'),
                trailing: const Icon(Icons.chevron_left),
                onTap: () => Navigator.push(
                    context, glassRoute((_) => Scaffold(appBar: AppBar(title: const Text('נתוני מס')), body: const TaxSettingsScreen()))),
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
                  subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text([
                      if (e.kind == CostKind.percent) '${Fmt.percent(e.value)} מהנטו' else 'סכום קבוע',
                      if (e.targetAccountID != null) 'עובר ל${money.account(e.targetAccountID)?.name ?? 'חשבון'}',
                      if (e.chargeDay != null) 'יורד ב-${e.chargeDay} לחודש',
                    ].join(' · ')),
                    // A shared charge: who shares it and what they paid toward it this period (CostRow.shared).
                    if (sharedCostText(e, money) case final shared?)
                      Row(children: [
                        Icon(Icons.people, size: 14, color: AppColors.teal),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(shared,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.teal)),
                        ),
                      ]),
                  ]),
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

/// "משותף עם דני · השתתף החודש ב-₪25 מתוך ₪30" (sharedText in CostsView.swift).
String? sharedCostText(CostItem item, MoneyData money) {
  if (!item.isShared) return null;
  final (y, m) = money.period(DateTime.now());
  final back = money.costShareReceived(item.id, money.periodStart(y, m), money.periodEnd(y, m));
  var text = 'משותף עם ${item.sharedWith}';
  if (back > 0.005) {
    text += ' · השתתף החודש ב-${Fmt.money(back)}';
    if (item.partnerShare > 0) text += ' מתוך ${Fmt.money(item.partnerShare)}';
  } else if (item.partnerShare > 0) {
    text += ' · החלק שלו ${Fmt.money(item.partnerShare)} — עוד לא הגיע החודש';
  }
  return text;
}

/// Editing a manual deduction (percent of gross) or a fixed expense (percent of net).
Future<void> editCost(BuildContext context, CostItem? existing, {required bool deductions}) async {
  final store = context.store;
  final draft = CostItem(existing != null ? deepCopy(existing.json) as Json : CostItem.create());
  // Deposits into savings are set on the savings account itself; a pension comes out of the salary.
  final savings = store.money.accounts.where((a) => a.kind == AccountKind.pension).toList();
  // The "shared" switch is on while the name is still empty.
  var sharingOn = false;
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
      if (!deductions)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('יום החיוב בבנק'),
          subtitle: Text(draft.chargeDay == null ? 'ביום המשכורת' : 'ב-${draft.chargeDay} לחודש'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton.outlined(
              tooltip: 'יום קודם',
              icon: const Icon(Icons.remove, size: 18),
              // 0 is "on the pay day", like the Mac stepper.
              onPressed: draft.chargeDay == null ? null : () => setState(() => draft.chargeDay = draft.chargeDay! <= 1 ? null : draft.chargeDay! - 1),
            ),
            const SizedBox(width: 8),
            IconButton.outlined(
              tooltip: 'יום הבא',
              icon: const Icon(Icons.add, size: 18),
              onPressed: (draft.chargeDay ?? 0) >= 31 ? null : () => setState(() => draft.chargeDay = (draft.chargeDay ?? 0) + 1),
            ),
          ]),
        ),
      if (!deductions && savings.isNotEmpty) ...[
        gap,
        DropdownButtonFormField<String?>(
          initialValue: savings.any((a) => a.id == draft.targetAccountID) ? draft.targetAccountID : null,
          decoration: const InputDecoration(
            labelText: 'הכסף עובר לחשבון',
            helperText: 'הפקדות לחיסכון מגדירים בחשבון החיסכון עצמו',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem(value: null, child: Text('לא — זו הוצאה')),
            for (final a in savings) DropdownMenuItem(value: a.id, child: Text(a.name)),
          ],
          onChanged: (v) => setState(() => draft.targetAccountID = v),
        ),
      ],
      // A charge shared with someone (a subscription, a joint bill): their participation comes off it (sharedSection).
      if (!deductions && draft.kind != CostKind.automatic && draft.targetAccountID == null) ...[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('חיוב משותף'),
          value: draft.isShared || sharingOn,
          onChanged: (on) => setState(() {
            sharingOn = on;
            if (!on) {
              draft.sharedWith = '';
              draft.partnerShare = 0;
            }
          }),
        ),
        if (draft.isShared || sharingOn) ...[
          TextInput(label: 'עם מי', initial: draft.sharedWith, onChanged: (v) => draft.sharedWith = v),
          gap,
          NumberField(
              label: 'החלק שלו בחודש (לא חובה)', suffix: '₪', value: draft.partnerShare, onChanged: (v) => draft.partnerShare = v),
          const SizedBox(height: 6),
          Text(
            'כשמגיע ממנו כסף על החיוב (למשל העברה בביט), סמן את ההכנסה במסך ״עו״ש״ כ״השתתפות בחיוב משותף״. '
            'הסכום יורד מההוצאה, ולא נספר כהכנסה (גם לא במעשרות).',
            style: Theme.of(ctx).textTheme.bodySmall?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
          ),
          gap,
        ],
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
