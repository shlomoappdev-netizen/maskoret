import 'package:flutter/material.dart';

import '../data/fmt.dart';
import '../data/json.dart';
import '../data/models.dart';
import 'common.dart';
import 'theme.dart';

Color _wearColor(double wear) => wear >= 1 ? AppColors.red1 : (wear >= 0.8 ? Colors.orange.shade700 : Colors.green.shade600);

/// "מעקב רכישות" — purchases outside the payslip that repeat every so often (TrackedItemsView.swift).
class TrackedScreen extends StatefulWidget {
  const TrackedScreen({super.key});

  @override
  State<TrackedScreen> createState() => _TrackedScreenState();
}

class _TrackedScreenState extends State<TrackedScreen> {
  String? _selected;

  Future<void> _add(Json draft) async {
    final id = await editTracked(context, draft, isNew: true);
    if (id == null || !mounted) return;
    if (isWide(context)) {
      setState(() => _selected = id);
    } else {
      Navigator.push(context, glassRoute((_) => TrackedDetailScreen(itemId: id)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final items = store.budget.trackedItems;
      final wide = isWide(context);
      final theme = Theme.of(context);
      final fab = PopupMenuButton<Json>(
        tooltip: 'פריט חדש',
        onSelected: _add,
        itemBuilder: (_) => [
          PopupMenuItem(value: TrackedItem.create(), child: const Text('פריט חדש…')),
          const PopupMenuDivider(),
          const PopupMenuItem(enabled: false, height: 32, child: Text('הצעות')),
          for (final (emoji, name, months) in TrackedItem.presets)
            PopupMenuItem(
              value: TrackedItem.create(name: name, emoji: emoji, expectedMonths: months),
              child: Text('$emoji $name'),
            ),
        ],
        child: IgnorePointer(
          child: FloatingActionButton.extended(heroTag: 'add-tracked', icon: const Icon(Icons.add), label: const Text('פריט חדש'), onPressed: () {}),
        ),
      );
      final list = PageList(children: [
        Text('רכישות מחוץ לתלוש שחוזרות מדי פעם', style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        if (items.isEmpty)
          const SectionCard(title: 'מעקב רכישות', children: [
            EmptyHint('הוסף דברים שאתה קונה שוב מדי פעם — נעליים, בגדים, טלפון, תספורת. בכל פעם שאתה קונה חדש, רשום את זה, '
                'והאפליקציה תחשב כמה זמן זה מחזיק לך וכמה זה עולה לך בחודש.'),
          ])
        else ...[
          Glass(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('עולה לך בממוצע בחודש', style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              Text(Fmt.money(store.budget.periodicTotal),
                  textDirection: TextDirection.rtl,
                  style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700, fontFeatures: tabular)),
              Text('≈ ${Fmt.money(store.budget.periodicTotal * 12)} בשנה · נכלל ביתרה בסיכום', style: theme.textTheme.bodySmall),
              ...() {
                final excluded = store.budget.trackedItems.where((t) => !t.includeInBudget && t.monthlyCost > 0).toList();
                if (excluded.isEmpty) return const <Widget>[];
                final sum = excluded.fold(0.0, (a, t) => a + t.monthlyCost);
                return [
                  const SizedBox(height: 6),
                  Text(
                      excluded.length == 1
                          ? '״${excluded.first.name}״ לא נכלל ביתרה (${Fmt.money(sum)}/חודש) — אפשר לכלול אותו בפריט'
                          : '${excluded.length} פריטים לא נכללים ביתרה (${Fmt.money(sum)}/חודש)',
                      style: theme.textTheme.bodySmall?.copyWith(color: Colors.orange.shade800)),
                ];
              }(),
            ]),
          ),
          const SizedBox(height: 14),
          SectionCard(title: 'פריטים', children: [
            for (final (i, item) in items.indexed)
              _Row(
                item: item,
                selected: wide && item.id == _selected,
                onTap: () => wide
                    ? setState(() => _selected = item.id)
                    : Navigator.push(context, glassRoute((_) => TrackedDetailScreen(itemId: item.id))),
                onUp: i == 0 ? null : () => store.edit((f) => f.budget.moveTracked(item.id, -1)),
                onDown: i == items.length - 1 ? null : () => store.edit((f) => f.budget.moveTracked(item.id, 1)),
                onDelete: () async {
                  if (await confirm(context, 'למחוק את ${item.name}?', 'הפריט וכל הקניות שלו יימחקו.', ok: 'מחק')) {
                    if (_selected == item.id) setState(() => _selected = null);
                    store.edit((f) => f.budget.removeTracked(item.id));
                  }
                },
              ),
          ]),
        ],
      ]);
      if (!wide) return Scaffold(floatingActionButton: fab, body: list);
      final selected = items.where((t) => t.id == _selected).firstOrNull ?? items.firstOrNull;
      return Scaffold(
        floatingActionButton: fab,
        body: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 380, child: list),
          Expanded(
            child: selected == null
                ? const Center(child: Text('בחר פריט מהרשימה כדי לראות כמה זמן הוא מחזיק לך ולרשום קנייה חדשה.'))
                : _Detail(key: ValueKey(selected.id), itemId: selected.id),
          ),
        ]),
      );
    });
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.item, required this.selected, required this.onTap, this.onUp, this.onDown, required this.onDelete});
  final TrackedItem item;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final VoidCallback onDelete;

  String get _subtitle {
    final life = item.averageLifespan;
    if (life == null) return item.purchases.isEmpty ? 'עוד לא נרשמה קנייה' : 'הוסף הערכה כמה זמן זה מחזיק';
    final age = item.ageMonths();
    return '${item.isLifespanMeasured ? 'מחזיק בממוצע ' : 'הערכה: '}${Fmt.duration(life)}'
        '${age == null ? '' : ' · בשימוש ${Fmt.duration(age)}'}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wear = item.wear();
    return ListTile(
      selected: selected,
      selectedTileColor: AppColors.teal.withValues(alpha: 0.1),
      onTap: onTap,
      leading: SizedBox(width: 36, height: 36, child: FittedBox(child: Text(item.emoji, style: const TextStyle(fontSize: 26)))),
      title: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${Fmt.money(item.monthlyCost)}/חודש',
            textDirection: TextDirection.rtl,
            style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: tabular,
                color: item.includeInBudget ? null : theme.colorScheme.onSurfaceVariant)),
        Text(_subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        if (!item.includeInBudget)
          Text('לא נכלל ביתרה', style: TextStyle(color: Colors.orange.shade800, fontSize: 11, fontWeight: FontWeight.w600)),
        if (wear != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: LinearProgressIndicator(
              value: wear.clamp(0, 1).toDouble(),
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
              color: _wearColor(wear),
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
      ]),
      trailing: PopupMenuButton<VoidCallback>(
        tooltip: 'פעולות',
        onSelected: (a) => a(),
        itemBuilder: (_) => [
          if (onUp != null) PopupMenuItem(value: onUp, child: const Text('הזז למעלה')),
          if (onDown != null) PopupMenuItem(value: onDown, child: const Text('הזז למטה')),
          PopupMenuItem(value: onDelete, child: const Text('מחיקת פריט')),
        ],
      ),
    );
  }
}

/// One item on a phone — the same content as the pane on a wide screen.
class TrackedDetailScreen extends StatelessWidget {
  const TrackedDetailScreen({super.key, required this.itemId});
  final String itemId;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('מעקב רכישות')),
        body: _Detail(itemId: itemId),
      );
}

class _Detail extends StatelessWidget {
  const _Detail({super.key, required this.itemId});
  final String itemId;

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final item = store.budget.trackedItems.where((t) => t.id == itemId).firstOrNull;
      if (item == null) return const Center(child: Text('הפריט נמחק'));
      final theme = Theme.of(context);
      final wear = item.wear(), next = item.nextReplacement, age = item.ageMonths(), life = item.averageLifespan;
      final purchases = item.sortedPurchases.reversed.toList();
      return PageList(children: [
        Wrap(spacing: 16, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(width: 60, height: 60, child: FittedBox(child: Text(item.emoji, style: const TextStyle(fontSize: 48)))),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.name, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
              if (wear != null && next != null) ...[
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: wear.clamp(0, 1).toDouble(),
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                  color: _wearColor(wear),
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
                const SizedBox(height: 4),
                Text(wear >= 1 ? 'עבר את הזמן הממוצע — אולי הגיע הזמן להחליף' : 'החלפה צפויה בערך ב-${Fmt.date(next)}',
                    style: theme.textTheme.bodySmall),
              ],
            ]),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.add_shopping_cart, size: 18),
            label: const Text('קניתי חדש'),
            onPressed: () => editPurchase(context, item.id, Purchase.create(price: item.lastPurchase?.price ?? 0), isNew: true),
          ),
          OutlinedButton(
            onPressed: () => editTracked(context, deepCopy(item.json) as Json, isNew: false),
            child: const Text('עריכת פריט'),
          ),
        ]),
        const SizedBox(height: 14),
        SectionCard(children: [
          SwitchListTile(
            title: const Text('כלול ביתרה החודשית'),
            subtitle: Text(
                item.includeInBudget
                    ? 'העלות החודשית של הפריט יורדת מהיתרה בסיכום ובתחזית'
                    : 'כרגע העלות של הפריט לא נספרת בסיכום ובתחזית',
                style: item.includeInBudget ? null : TextStyle(color: Colors.orange.shade800)),
            value: item.includeInBudget,
            onChanged: (v) => store.edit((f) {
              final t = f.budget.trackedItems.where((t) => t.id == item.id).firstOrNull;
              if (t != null) t.json['includeInBudget'] = v;
            }),
          ),
        ]),
        const SizedBox(height: 14),
        TileGrid(minWidth: 125, children: [
          StatTile(
              title: item.isLifespanMeasured ? 'מחזיק בממוצע' : 'הערכת משך שימוש',
              value: life == null ? '—' : Fmt.duration(life),
              icon: Icons.hourglass_bottom),
          StatTile(title: 'עלות לחודש', value: Fmt.money(item.monthlyCost), icon: Icons.calendar_today),
          StatTile(title: 'עלות לשנה', value: Fmt.money(item.monthlyCost * 12), icon: Icons.event_repeat),
          StatTile(title: 'מחיר ממוצע', value: item.purchases.isEmpty ? '—' : Fmt.money(item.averagePrice), icon: Icons.sell_outlined),
          StatTile(title: 'בשימוש כבר', value: age == null ? '—' : Fmt.duration(age), icon: Icons.schedule),
          StatTile(title: 'סה״כ הוצאת', value: Fmt.money(item.totalSpent), icon: Icons.functions),
        ]),
        const SizedBox(height: 14),
        SectionCard(
          title: 'היסטוריית קניות',
          trailing: Text('${item.purchases.length} קניות', style: theme.textTheme.bodySmall),
          children: [
            if (purchases.isEmpty) const EmptyHint('עוד לא נרשמו קניות. לחץ ״קניתי חדש״ כדי להתחיל.'),
            for (final p in purchases)
              () {
                final lasted = item.lasted(p);
                final current = TrackedItem.monthsBetween(p.date, DateTime.now());
                return AmountRow(
                  Fmt.date(p.date),
                  p.price,
                  detail: [
                    lasted != null ? 'החזיק ${Fmt.duration(lasted)}' : 'בשימוש כרגע · ${Fmt.duration(current > 0 ? current : 0)}',
                    if (p.note.isNotEmpty) p.note,
                  ].join(' · '),
                  onTap: () => editPurchase(context, item.id, deepCopy(p.json) as Json, isNew: false),
                );
              }(),
            const EmptyHint('משך השימוש של כל קנייה נמדד עד הקנייה הבאה. מ-2 קניות ומעלה האפליקציה משתמשת בממוצע האמיתי '
                'במקום בהערכה. לחיצה על קנייה לעריכה או מחיקה.'),
          ],
        ),
      ]);
    });
  }
}

const _emojis = ['👟', '👕', '👖', '🧥', '📱', '💻', '👓', '💈', '🔧', '🛞', '🦷', '🛏️', '🎧', '⌚️', '🎒', '🧴', '📄', '📦'];

/// TrackedItemEditor: returns the item's id when saved.
Future<String?> editTracked(BuildContext context, Json draft, {required bool isNew}) async {
  final store = context.store;
  final item = TrackedItem(draft);
  var emoji = item.emoji;
  var addFirst = isNew;
  var firstDate = DateTime.now();
  var firstPrice = 0.0;
  var name = item.name;
  var months = item.expectedMonths;
  var include = item.includeInBudget;
  final saved = await showEditor(
    context,
    title: isNew ? 'פריט חדש למעקב' : 'עריכת פריט',
    builder: (context, setState) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextInput(label: 'שם (למשל: נעלי ריצה)', initial: name, autofocus: isNew && name.isEmpty, onChanged: (v) => name = v),
      const SizedBox(height: 12),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final e in {..._emojis, emoji})
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => emoji = e),
            child: Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: e == emoji ? AppColors.teal.withValues(alpha: 0.3) : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: FittedBox(child: Text(e, style: const TextStyle(fontSize: 22))),
            ),
          ),
      ]),
      const SizedBox(height: 12),
      NumberField(
        label: 'כמה זמן זה מחזיק בערך',
        suffix: 'חודשים',
        value: months,
        helper: 'ההערכה משמשת רק עד שיש 2 קניות — אחר כך האפליקציה מחשבת לבד לפי מה שבאמת קרה. העלות החודשית (מחיר ÷ משך '
            'שימוש) יורדת מהיתרה בסיכום.',
        onChanged: (v) => months = v,
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('כלול ביתרה החודשית'),
        value: include,
        onChanged: (v) => setState(() => include = v),
      ),
      if (isNew) ...[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('רשום את הקנייה האחרונה'),
          subtitle: const Text('למשל: מתי קנית את זוג הנעליים שאתה נועל עכשיו וכמה הוא עלה.'),
          value: addFirst,
          onChanged: (v) => setState(() => addFirst = v),
        ),
        if (addFirst) ...[
          DateField(label: 'מתי קנית', value: firstDate, onChanged: (v) => setState(() => firstDate = v ?? firstDate)),
          const SizedBox(height: 12),
          NumberField(label: 'מחיר', suffix: '₪', value: firstPrice, onChanged: (v) => firstPrice = v),
        ],
      ],
    ]),
    onSave: () => store.edit((f) {
      draft
        ..['name'] = name.trim()
        ..['emoji'] = emoji
        ..['expectedMonths'] = jsonNumber(months)
        ..['includeInBudget'] = include;
      if (isNew && addFirst) {
        ((draft['purchases'] ??= <dynamic>[]) as List).add(Purchase.create(date: firstDate, price: firstPrice));
      }
      f.budget.upsertTracked(draft);
    }),
  );
  return saved ? draft['id'] as String : null;
}

/// PurchaseEditor.
Future<void> editPurchase(BuildContext context, String itemId, Json draft, {required bool isNew}) async {
  final store = context.store;
  final p = Purchase(draft);
  var date = p.date;
  var price = p.price;
  var note = p.note;
  await showEditor(
    context,
    title: isNew ? 'קנייה חדשה' : 'עריכת קנייה',
    builder: (context, setState) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DateField(label: 'תאריך', value: date, onChanged: (v) => setState(() => date = v ?? date)),
      const SizedBox(height: 12),
      NumberField(label: 'מחיר', suffix: '₪', value: price, onChanged: (v) => price = v),
      const SizedBox(height: 12),
      TextInput(label: 'הערה (למשל: דגם, חנות)', initial: note, onChanged: (v) => note = v),
    ]),
    onSave: () => store.edit((f) => f.budget.addPurchase(
        itemId,
        draft
          ..['date'] = dateTimeToSwift(date)
          ..['price'] = jsonNumber(price)
          ..['note'] = note.trim())),
    onDelete: isNew ? null : () => store.edit((f) => f.budget.deletePurchase(itemId, p.id)),
  );
}
