import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/card.dart';
import '../data/maaser.dart';
import '../data/receivables.dart';
import '../data/fmt.dart';
import '../data/json.dart';
import '../data/max_import.dart';
import '../data/models.dart';
import 'common.dart';
import 'receivables_screen.dart';
import 'theme.dart';

/// Credit card: importing the Max statement, the month's charges, linking them to fixed expenses,
/// categories, installments — port of CardView.swift.
class CardScreen extends StatefulWidget {
  const CardScreen({super.key});

  @override
  State<CardScreen> createState() => _CardScreenState();
}

enum _Filter {
  all('הכל'),
  open('לא מצומד'),
  linked('מצומד'),
  ignored('מוסתר');

  const _Filter(this.title);
  final String title;
}

String billingTitle(int key) => Fmt.monthTitle(key ~/ 100, key % 100);

double _r(double v) => (v * 100).round() / 100;

class _CardScreenState extends State<CardScreen> {
  int? selectedKey;
  var filter = _Filter.all;
  String? message;
  var isError = false;

  Future<void> _import() async {
    final store = context.store;
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx'],
      dialogTitle: 'ייבוא קובץ מ-Max',
    );
    if (!mounted) return;
    for (final f in picked) {
      final List<int> bytes;
      try {
        bytes = await f.xFile.readAsBytes();
      } catch (_) {
        continue;
      }
      if (!mounted) return;
      try {
        late CardImportRecord record;
        store.edit((file) => record = CardActions(file).importFile(bytes, f.name));
        setState(() {
          isError = false;
          message = record.summary;
          selectedKey = CardData(store.money).cardStatementKeys.firstOrNull;
        });
      } catch (e) {
        setState(() {
          isError = true;
          message = e is CardImportException ? e.message : CardImportException.unreadable.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final cards = CardData(store.money);
      final keys = cards.cardBillingKeys;
      final key = selectedKey != null && keys.contains(selectedKey)
          ? selectedKey
          : (cards.cardStatementKeys.firstOrNull ?? keys.firstOrNull);
      final monthTxs = key == null ? <CardTransaction>[] : cards.chargedIn(key);
      if (cards.cardTransactions.isEmpty) return _empty(context, cards);
      final shown = switch (filter) {
        _Filter.all => monthTxs,
        _Filter.open => monthTxs.where((t) => t.isVariable).toList(),
        _Filter.linked => monthTxs.where((t) => !t.ignored && (t.linkedExpenseID != null || t.linkedTrackedID != null)).toList(),
        _Filter.ignored => monthTxs.where((t) => t.ignored).toList(),
      };
      final last = cards.imports.firstOrNull;
      final wide = isWide(context);
      final cats = _categories(context, cards, monthTxs);
      final fixed = _fixed(context, store, cards, key);
      return Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          heroTag: 'card-import',
          icon: const Icon(Icons.file_download_outlined),
          label: const Text('ייבוא מ-Max'),
          onPressed: _import,
        ),
        body: PageList(children: [
          Row(children: [
            Expanded(
              child: Text(
                last == null
                    ? 'ייבוא פירוט עסקאות מ-Max וצימוד להוצאות הקבועות'
                    : 'ייבוא אחרון: ${Fmt.date(JObj(last).date('importedAt') ?? DateTime.now())} · ${JObj(last).s('fileName')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (keys.length > 1)
              DropdownButton<int>(
                value: key,
                items: [for (final k in keys) DropdownMenuItem(value: k, child: Text('חיוב ${billingTitle(k)}'))],
                onChanged: (v) => setState(() => selectedKey = v),
              ),
          ]),
          const SizedBox(height: 8),
          if (message != null) _message(context),
          if (cards.importDue())
            _Banner(
              icon: Icons.notifications_active,
              iconColor: Colors.orange,
              title: 'החיוב של ${Fmt.monthNames[DateTime.now().month - 1]} כבר ירד מהבנק — זה הזמן לייבא את הפירוט שלו',
              text: 'אחרי הייבוא תוכל לצמד כל חיוב להוצאה הקבועה שלו. בתי עסק שכבר צימדת בעבר יצומדו לבד.',
              action: 'ייבוא…',
              onAction: _import,
            ),
          if (monthTxs.any((t) => t.isVariable) && filter != _Filter.open)
            _Banner(
              icon: Icons.add_link,
              text: '${monthTxs.where((t) => t.isVariable).length} חיובים עוד לא מצומדים. חיוב שהוא בעצם הוצאה קבועה '
                  '(חשמל, טלפון, מנוי) — צמד אותו כדי שלא ייספר פעמיים.',
              action: 'הצג אותם',
              onAction: () => setState(() => filter = _Filter.open),
            ),
          _tiles(context, monthTxs, key),
          if (wide)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: cats),
              const SizedBox(width: 12),
              Expanded(child: fixed),
            ])
          else ...[
            cats,
            fixed,
          ],
          if (cards.installmentPlans.isNotEmpty) _installments(context, cards),
          SectionCard(
            title: 'חיובים',
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: SegmentedButton<_Filter>(
                  showSelectedIcon: false,
                  segments: [for (final f in _Filter.values) ButtonSegment(value: f, label: Text(f.title))],
                  selected: {filter},
                  onSelectionChanged: (s) => setState(() => filter = s.first),
                ),
              ),
              if (shown.isEmpty) const EmptyHint('אין חיובים להצגה.'),
              for (final t in shown) CardTxRow(tx: t, cards: cards),
            ],
          ),
        ]),
      );
    });
  }

  Widget _message(BuildContext context) {
    final color = isError ? Theme.of(context).colorScheme.error : Colors.green.shade700;
    return SectionCard(children: [
      ListTile(
        leading: Icon(isError ? Icons.warning_amber : Icons.check_circle, color: color),
        title: Text(message!, style: TextStyle(color: color)),
        trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => message = null)),
      ),
    ]);
  }

  Widget _empty(BuildContext context, CardData cards) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(children: [
            Icon(Icons.credit_card, size: 56, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text('עוד לא יובא פירוט אשראי', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            _howTo(context, cards),
            const SizedBox(height: 16),
            FilledButton.icon(icon: const Icon(Icons.file_download_outlined), label: const Text('ייבוא קובץ מ-Max…'), onPressed: _import),
            if (message != null) ...[const SizedBox(height: 12), _message(context)],
          ]),
        ),
      ),
    );
  }

  Widget _howTo(BuildContext context, CardData cards) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('איך מייצאים מ-Max:', style: Theme.of(context).textTheme.titleSmall),
        const Text('1. נכנסים לאתר max.co.il ← ״פירוט עסקאות וחיובים״.'),
        const Text('2. בוחרים את חודש החיוב (״כל הכרטיסים״).'),
        const Text('3. לוחצים על אייקון האקסל (״ייצוא לאקסל״) ושומרים.'),
        Text('4. מייבאים כאן. הכי טוב — ביום שהחיוב יורד מהבנק (אצלך בדרך כלל ב-${cards.usualChargeDay ?? 2} לחודש).'),
      ]);

  Widget _tiles(BuildContext context, List<CardTransaction> txs, int? key) {
    final s = CardMonthSummary.of(txs);
    final tiles = <(String, double, IconData)>[
      ('סה״כ חיוב${key == null ? '' : ' — ${billingTitle(key)}'}', s.total, Icons.credit_card),
      ('מצומד להוצאות קבועות', s.fixedLinked, Icons.link),
      if (s.trackedLinked != 0) ('רכישות במעקב', s.trackedLinked, Icons.shopping_bag_outlined),
      ('הוצאות משתנות', s.variable, Icons.shopping_cart_outlined),
      if (s.installments != 0) ('מתוכן תשלומים', s.installments, Icons.event_repeat),
      if (s.owed > 0) ('שילמתי בשביל אחרים', s.owed, Icons.undo),
      if (s.pending != 0) ('ממתין לקליטה (כלול)', s.pending, Icons.hourglass_empty),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TileGrid(minWidth: 130, children: [
        for (final (title, value, icon) in tiles) StatTile(title: title, value: Fmt.money(_r(value)), icon: icon),
      ]),
    );
  }

  Widget _categories(BuildContext context, CardData cards, List<CardTransaction> txs) {
    final items = CardMonthSummary.of(txs).byCategory.where((c) => c.amount > 0).toList();
    final top = items.isEmpty ? 1.0 : (items.first.amount < 1 ? 1.0 : items.first.amount);
    final avg = cards.averageCardVariable();
    final theme = Theme.of(context);
    return SectionCard(title: 'הוצאות משתנות לפי קטגוריה', children: [
      if (items.isEmpty) const EmptyHint('אין הוצאות משתנות בחודש הזה — הכל מצומד.'),
      for (final c in items)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(c.name)),
              Text(Fmt.money(_r(c.amount)), textDirection: TextDirection.rtl, style: theme.textTheme.bodySmall),
            ]),
            const SizedBox(height: 3),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: (c.amount / top).clamp(0.02, 1.0), minHeight: 8, color: Colors.teal),
            ),
          ]),
        ),
      if (avg > 0) ...[
        const Divider(indent: 16, endIndent: 16),
        AmountRow('ממוצע הוצאות משתנות בחודש (עד 3 חיובים אחרונים)', avg,
            detail: 'הממוצע נכנס לסיכום החודש ולתחזית בחודשים שעוד לא יובא להם פירוט.'),
      ],
    ]);
  }

  Widget _fixed(BuildContext context, dynamic store, CardData cards, int? key) {
    final budget = store.budget as Budget;
    final actuals = key == null ? <String, double>{} : cards.actuals(key);
    final expenses = budget.expenses.where((e) => actuals.containsKey(e.id)).toList();
    final theme = Theme.of(context);
    return SectionCard(title: 'הוצאות קבועות — מתוכנן מול אשראי', children: [
      if (expenses.isEmpty) const EmptyHint('עוד לא צימדת חיובים להוצאות קבועות. בחר ״צמד ל…״ ליד חיוב ברשימה למטה.'),
      for (final e in expenses)
        () {
          final planned = e.amount(budget.expenseBase);
          final actual = actuals[e.id] ?? 0;
          final over = actual > planned + 0.5;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(e.name, style: const TextStyle(fontWeight: FontWeight.w500))),
                Text('${Fmt.money(_r(actual))} / ${Fmt.money(planned)}',
                    textDirection: TextDirection.rtl, style: TextStyle(color: over ? theme.colorScheme.error : null)),
              ]),
              const SizedBox(height: 3),
              LinearProgressIndicator(
                value: planned <= 0 ? 1 : (actual / planned).clamp(0.0, 1.0),
                color: over ? theme.colorScheme.error : Colors.green,
              ),
            ]),
          );
        }(),
      if (expenses.isNotEmpty)
        const EmptyHint('הוצאה קבועה כבר נספרת בתקציב, ולכן חיוב שמצומד אליה לא נספר שוב בהוצאות המשתנות.'),
    ]);
  }

  Widget _installments(BuildContext context, CardData cards) {
    final plans = cards.installmentPlans;
    final active = plans.where((p) => p.isActive).toList();
    final done = plans.where((p) => !p.isActive).take(3).toList();
    final now = DateTime.now();
    final future = active.fold(0.0,
        (s, p) => s + p.payments.where((x) => x.chargeDate.isAfter(now)).fold(0.0, (a, x) => a + x.amount));
    final theme = Theme.of(context);
    return SectionCard(
      title: 'תשלומים',
      subtitle: 'קנייה גדולה בתשלומים נספרת רק לפי מה שיורד בכל חודש. תשלומים שעוד לא הופיעו בקובץ נכנסים לסיכום ולתחזית לפי הצפי.',
      trailing: future > 0 ? Text('עוד יחויב: ${Fmt.money(_r(future))}', style: theme.textTheme.bodySmall) : null,
      children: [
        for (final p in [...active, ...done])
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(p.merchant, style: const TextStyle(fontWeight: FontWeight.w500))),
                if (!p.countsAsVariable)
                  const Padding(padding: EdgeInsetsDirectional.only(end: 6), child: Chip(label: Text('מצומד'), visualDensity: VisualDensity.compact)),
                Text('${Fmt.money(p.total)} ב-${p.count} תשלומים', textDirection: TextDirection.rtl),
              ]),
              Text(
                'נקנה ${Fmt.date(p.purchaseDate)}'
                '${p.next == null ? ' · הסתיים' : ' · תשלום הבא ${Fmt.date(p.next!.chargeDate)} — ${Fmt.money(p.next!.amount)}'}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 6),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (final x in p.payments)
                    Container(
                      margin: const EdgeInsetsDirectional.only(end: 6),
                      padding: const EdgeInsets.all(6),
                      constraints: const BoxConstraints(minWidth: 64),
                      decoration: BoxDecoration(
                        color: !x.chargeDate.isAfter(now)
                            ? Colors.green.withValues(alpha: 0.18)
                            : x.imported
                                ? theme.colorScheme.primary.withValues(alpha: 0.14)
                                : theme.colorScheme.onSurface.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(8),
                        border: x.imported ? null : Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.5)),
                      ),
                      child: Column(children: [
                        Text('${x.number}/${p.count}', style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
                        Text(Fmt.money(x.amount), textDirection: TextDirection.rtl, style: theme.textTheme.labelSmall),
                        Text('${x.chargeDate.day}.${x.chargeDate.month}', style: theme.textTheme.labelSmall),
                      ]),
                    ),
                ]),
              ),
            ]),
          ),
        const EmptyHint('ירוק = כבר ירד · כחול = מופיע בקובץ ויחויב · עם מסגרת = צפוי'),
      ],
    );
  }
}

/// A notice with its button under the text (fits a narrow phone).
class _Banner extends StatelessWidget {
  const _Banner({required this.icon, this.iconColor, this.title, required this.text, required this.action, required this.onAction});
  final IconData icon;
  final Color? iconColor;
  final String? title;
  final String text;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Glass(
      tint: theme.colorScheme.primary.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: iconColor ?? theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (title != null) Text(title!, style: theme.textTheme.titleSmall),
                Text(text, style: theme.textTheme.bodyMedium),
              ]),
            ),
          ]),
          Align(alignment: AlignmentDirectional.centerEnd, child: TextButton(onPressed: onAction, child: Text(action))),
        ]),
      ),
      ),
    );
  }
}

/// One charge, with its details, tags and the "צמד ל…" menu.
class CardTxRow extends StatelessWidget {
  const CardTxRow({super.key, required this.tx, required this.cards});
  final CardTransaction tx;
  final CardData cards;

  String _details(BuildContext context) {
    final parts = <String>['${tx.date.day}.${tx.date.month}'];
    if (tx.category.isNotEmpty) parts.add(tx.category);
    if (tx.cardLast4.isNotEmpty) parts.add('כרטיס ${tx.cardLast4}');
    if (tx.note.isNotEmpty) parts.add(tx.note);
    if (tx.status == 'pending') parts.add('ממתין לקליטה');
    if (tx.status == 'foreign') parts.add('חו״ל');
    final occurrence = CardData.occurrence(tx);
    if (occurrence > 1) {
      parts.add('רכישה זהה מס׳ $occurrence באותו יום');
    } else if (cards.cardTransactions.any((t) => t.id == '${CardData.baseID(tx)}#2')) {
      parts.add('נקנה יותר מפעם אחת באותו יום');
    }
    final currency = JObj(tx.json).s('originalCurrency', '₪');
    if (currency != '₪' && currency.isNotEmpty) {
      parts.add('${Fmt.number(tx.originalAmount)} $currency');
    } else if ((tx.originalAmount - tx.amount).abs() > 0.01 && tx.originalAmount != 0) {
      parts.add('עסקה מקורית ${Fmt.money(tx.originalAmount)}');
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final theme = Theme.of(context);
    final budget = store.budget;
    String? linked;
    if (tx.linkedExpenseID != null) linked = budget.expenses.where((e) => e.id == tx.linkedExpenseID).firstOrNull?.name;
    if (tx.linkedTrackedID != null) {
      final t = JObj(store.file.json['budget'] as Json).objects('trackedItems').where((t) => t['id'] == tx.linkedTrackedID).firstOrNull;
      if (t != null) linked = '${t['emoji'] ?? ''} ${t['name'] ?? ''}';
    }
    final trends = JObj(store.money.raw).objects('trends').where((t) => (t['cardIDs'] as List?)?.contains(tx.id) == true);
    final amountColor = tx.amount < 0 ? Colors.green.shade700 : (tx.ignored ? theme.colorScheme.onSurfaceVariant : null);
    Widget tag(String text, Color color) => Container(
          margin: const EdgeInsetsDirectional.only(end: 6, top: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
          child: Text(text, style: theme.textTheme.labelSmall),
        );
    return Opacity(
      opacity: tx.ignored ? 0.5 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tx.merchant,
                  style: TextStyle(
                      fontWeight: FontWeight.w500, decoration: tx.ignored ? TextDecoration.lineThrough : null)),
              Text(_details(context), style: theme.textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
              Wrap(children: [
                if (tx.owedPortion > 0) tag('↩︎ יחזירו ${Fmt.money(tx.owedPortion)}', Colors.orange),
                if (MaaserSettings(JObj((store.money.raw['maaser'] as Json?) ?? {})).isMaaser(tx)) tag('🤲 מעשרות', Colors.green),
                for (final t in trends) tag('${t['emoji'] ?? ''} ${t['name'] ?? ''}', Colors.purple),
                if (linked != null) tag('🔗 $linked', theme.colorScheme.primary),
              ]),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(Fmt.money(_r(tx.amount)),
                textDirection: TextDirection.rtl,
                style: TextStyle(fontWeight: FontWeight.w600, color: amountColor)),
            _LinkMenu(tx: tx),
          ]),
        ]),
      ),
    );
  }
}

class _LinkMenu extends StatelessWidget {
  const _LinkMenu({required this.tx});
  final CardTransaction tx;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final budget = store.budget;
    final tracked = JObj(store.file.json['budget'] as Json).objects('trackedItems');
    final trends = JObj(store.money.raw).objects('trends');
    final unlinked = tx.linkedExpenseID == null && tx.linkedTrackedID == null;
    final maaser = MaaserSettings(JObj((store.money.raw['maaser'] as Json?) ?? {}));
    PopupMenuEntry<void Function()> header(String text) =>
        PopupMenuItem(enabled: false, height: 32, child: Text(text, style: Theme.of(context).textTheme.labelSmall));
    PopupMenuEntry<void Function()> item(String text, void Function(SaveFile f) action, {bool checked = false}) =>
        CheckedPopupMenuItem(checked: checked, value: () => store.edit(action), child: Text(text));
    return PopupMenuButton<void Function()>(
      tooltip: unlinked ? 'צמד ל…' : 'שנה',
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        header('הוצאה קבועה — כל החיובים מבית העסק הזה'),
        if (budget.expenses.isEmpty) const PopupMenuItem(enabled: false, child: Text('אין הוצאות קבועות')),
        for (final e in budget.expenses)
          item(e.name, (f) => CardActions(f).linkToExpense(tx.id, e.id), checked: tx.linkedExpenseID == e.id),
        if (tracked.isNotEmpty) ...[
          const PopupMenuDivider(),
          header('מעקב רכישות — נרשם כרכישה'),
          for (final t in tracked)
            item('${t['emoji'] ?? ''} ${t['name'] ?? ''}', (f) => CardActions(f).linkToTracked(tx.id, t['id'] as String),
                checked: tx.linkedTrackedID == t['id']),
        ],
        if (trends.isNotEmpty) ...[
          const PopupMenuDivider(),
          header('מגמות — לניתוח, לא משנה את התקציב'),
          for (final t in trends)
            item('${t['emoji'] ?? ''} ${t['name'] ?? ''}', (f) => CardActions(f).toggleInTrend(tx.id, t['id'] as String),
                checked: (t['cardIDs'] as List?)?.contains(tx.id) == true),
        ],
        const PopupMenuDivider(),
        header('חייבים לי'),
        if (tx.owedPortion > 0)
          item('ביטול — לא צריך להחזיר', (f) => ReceivableActions(f).removeCardFromReceivables(tx.id))
        else if (tx.amount > 0)
          PopupMenuItem(value: () => showOwedQuick(context, tx), child: const Text('מישהו צריך להחזיר לי…')),
        if (maaser.enabled) ...[
          const PopupMenuDivider(),
          header('מעשרות'),
          if (maaser.isMaaser(tx))
            item('בטל סימון מעשרות', (f) => MaaserCalc.setCardMaaser(f, tx, on: false, merchant: false))
          else ...[
            item('החיוב הזה הוא מעשרות', (f) => MaaserCalc.setCardMaaser(f, tx, on: true, merchant: false)),
            item('כל החיובים מבית העסק הזה הם מעשרות', (f) => MaaserCalc.setCardMaaser(f, tx, on: true, merchant: true)),
          ],
        ],
        const PopupMenuDivider(),
        if (tx.linkedExpenseID != null) item('בטל צימוד (הוצאה משתנה)', (f) => CardActions(f).linkToExpense(tx.id, null)),
        if (tx.linkedTrackedID != null) item('בטל צימוד למעקב', (f) => CardActions(f).linkToTracked(tx.id, null)),
        item(tx.ignored ? 'החזר לחישוב' : 'הסתר מהחישוב (כבר נרשם / כפול)', (f) => CardActions(f).setIgnored(tx.id, !tx.ignored)),
      ],
      child: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.link, size: 16, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 2),
          Text(unlinked ? 'צמד ל…' : 'שנה', style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 13)),
        ]),
      ),
    );
  }
}
