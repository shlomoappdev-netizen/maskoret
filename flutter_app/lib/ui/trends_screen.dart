import 'package:flutter/material.dart';

import '../data/card.dart';
import '../data/fmt.dart';
import '../data/json.dart';
import '../data/models.dart';
import '../data/trends.dart';
import 'common.dart';
import 'theme.dart';

List<Trend> _trends(MoneyData money) => JObj(money.raw).objects('trends').map(Trend.new).toList();

/// "מגמות" — how much really goes on things that have no category (TrendsView.swift).
class TrendsScreen extends StatelessWidget {
  const TrendsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final theme = Theme.of(context);
      final trends = _trends(store.money);
      if (trends.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.sell_outlined, size: 56, color: theme.colorScheme.primary),
                const SizedBox(height: 12),
                Text('אין עדיין מגמות', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text(
                  'מגמה מרכזת הוצאות שמפוזרות בין בתי עסק וקטגוריות. למשל ״דייטים״: מסעדה, קולנוע, פרחים ומונית.\n'
                  'אחרי שיוצרים מגמה משייכים אליה חיובים ממסך ״אשראי״ (בכפתור ״מה זה?״), תנועות, או הוצאות במזומן — '
                  'ורואים כמה זה יוצא בחודש.\nמגמות הן לניתוח בלבד — הן לא משנות את התקציב ולא נספרות פעמיים.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: () => newTrend(context), child: const Text('מגמה חדשה')),
              ]),
            ),
          ),
        );
      }
      return Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          heroTag: 'new-trend',
          icon: const Icon(Icons.add),
          label: const Text('מגמה חדשה'),
          onPressed: () => newTrend(context),
        ),
        body: PageList(children: [
          Text('כמה באמת הולך על דברים שאין להם קטגוריה — דייטים, מתנות, יציאות', style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          if (TrendLimits.of(store.file) case final limits?) _LimitsSummary(limits: limits),
          TileGrid(minWidth: 320, spacing: 14, children: [
            for (final t in trends) _TrendCard(trend: t, stats: TrendCalc.stats(store.money, t)),
          ]),
        ]),
      );
    });
  }
}

/// "סך התקרות": every trend's limit together, this month's spending against it, and the limits against the latest
/// income and the recent average, with a warning when they're more than the income (TrendLimitsSummary).
class _LimitsSummary extends StatelessWidget {
  const _LimitsSummary({required this.limits});
  final TrendLimits limits;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = limits;
    final error = theme.colorScheme.error;
    Widget bar(Widget label, double value, double total, Color color) => Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DefaultTextStyle.merge(style: theme.textTheme.bodySmall, child: label),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: total <= 0 ? 0 : (value / total).clamp(0.0, 1.0),
              color: color,
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
            ),
          ]),
        );
    // How much of an income the limits take.
    Widget incomeBar(String title, double income) {
      final share = l.total / income;
      return bar(
        Row(children: [
          Expanded(child: Text('$title · ${Fmt.money(income)}')),
          Text('התקרות: ${(share * 100).round()}%', style: const TextStyle(fontFeatures: tabular)),
        ]),
        l.total < income ? l.total : income,
        income,
        share > 1 ? Colors.red : (share > 0.8 ? Colors.orange : Colors.green),
      );
    }

    final warning = l.warning;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Glass(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('סך התקרות', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                Text('${l.count} מגמות עם תקרה',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ]),
            ),
            Text(Fmt.money(l.total),
                textDirection: TextDirection.rtl,
                style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700, fontFeatures: tabular, color: warning != null ? error : null)),
          ]),
          bar(Text('הוצאתם החודש ${Fmt.money(l.spentThisMonth)} מתוך ${Fmt.money(l.total)}'), l.spentThisMonth, l.total,
              l.spentThisMonth > l.total ? Colors.red : Colors.green),
          if (l.lastIncome > 0) incomeBar(l.lastLabel, l.lastIncome),
          if ((l.averageIncome ?? 0) > 0) incomeBar('ממוצע ${l.months} החודשים האחרונים', l.averageIncome!),
          if (warning != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.warning_rounded, color: error, size: 20),
                const SizedBox(width: 6),
                Expanded(child: Text(warning, style: TextStyle(color: error))),
              ]),
            ),
        ]),
      ),
    );
  }
}

class _TrendCard extends StatelessWidget {
  const _TrendCard({required this.trend, required this.stats});
  final Trend trend;
  final TrendStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final limit = trend.monthlyLimit;
    final over = limit > 0 && stats.thisMonth > limit;
    Widget mini(String title, double value) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: theme.textTheme.labelSmall),
            Text(Fmt.money(value),
                textDirection: TextDirection.rtl,
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontFeatures: tabular)),
          ]),
        );
    return Glass(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => Navigator.push(context, glassRoute((_) => TrendDetailScreen(trendId: trend.id))),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 38, height: 38, child: FittedBox(child: Text(trend.emoji, style: const TextStyle(fontSize: 28)))),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(trend.name, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  Text('${stats.count} פריטים', style: theme.textTheme.bodySmall),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('החודש', style: theme.textTheme.labelSmall),
                Text(Fmt.money(stats.thisMonth),
                    textDirection: TextDirection.rtl,
                    style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700, fontFeatures: tabular, color: over ? theme.colorScheme.error : null)),
              ]),
            ]),
            if (limit > 0) ...[
              const SizedBox(height: 10),
              Text('תקרה: ${Fmt.money(limit)}', style: theme.textTheme.labelSmall),
              const SizedBox(height: 4),
              LinearProgressIndicator(
                value: (stats.thisMonth / limit).clamp(0, 1).toDouble(),
                minHeight: 5,
                borderRadius: BorderRadius.circular(3),
                color: over ? theme.colorScheme.error : Colors.green.shade600,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ],
            const SizedBox(height: 12),
            TrendBars(months: stats.months, limit: limit),
            const SizedBox(height: 8),
            Row(children: [
              mini('חודש שעבר', stats.lastMonth),
              mini('ממוצע לחודש', stats.monthlyAverage),
              mini('סה״כ', stats.total),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Monthly bars, oldest → newest (right → left in Hebrew).
class TrendBars extends StatelessWidget {
  const TrendBars({super.key, required this.months, this.limit = 0, this.height = 70});
  final List<TrendMonth> months;
  final double limit;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var top = limit > 1 ? limit : 1.0;
    for (final m in months) {
      if (m.amount > top) top = m.amount;
    }
    return SizedBox(
      height: height + 36,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (final m in months)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                FittedBox(fit: BoxFit.scaleDown, child: Text(m.amount == 0 ? ' ' : Fmt.compact(m.amount), maxLines: 1, style: theme.textTheme.labelSmall?.copyWith(fontSize: 10))),
                const SizedBox(height: 2),
                Container(
                  height: (height * (m.amount > 0 ? m.amount : 0) / top).clamp(3, height).toDouble(),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: (limit > 0 && m.amount > limit ? theme.colorScheme.error : AppColors.teal)
                        .withValues(alpha: m.amount == 0 ? 0.2 : 1),
                  ),
                ),
                const SizedBox(height: 2),
                FittedBox(fit: BoxFit.scaleDown, child: Text('${m.key % 100}/${(m.key ~/ 100) % 100}', style: theme.textTheme.labelSmall?.copyWith(fontSize: 10))),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// NewTrendSheet, then straight into the new trend — or, from "מה זה?" with [withCard], the new trend starts with
/// that charge and the window stays where it was.
Future<void> newTrend(BuildContext context, {String? withCard}) async {
  final store = context.store;
  var name = '', emoji = '🏷️';
  var limit = 0.0;
  final nameController = TextEditingController();
  final emojiController = TextEditingController(text: emoji);
  final trend = Trend.create();
  final saved = await showEditor(
    context,
    title: 'מגמה חדשה',
    builder: (context, setState) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: nameController,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'שם', hintText: 'למשל: דייטים', border: OutlineInputBorder()),
        onChanged: (v) => name = v,
      ),
      const SizedBox(height: 12),
      TextField(
        controller: emojiController,
        decoration: const InputDecoration(labelText: 'אימוג׳י', border: OutlineInputBorder()),
        onChanged: (v) => emoji = v,
      ),
      const SizedBox(height: 12),
      NumberField(
        label: 'תקרה חודשית (לא חובה)',
        suffix: '₪',
        value: 0,
        helper: 'אחרי היצירה משייכים חיובים ממסך ״אשראי״ או מתוך המגמה עצמה.',
        onChanged: (v) => limit = v,
      ),
      const SizedBox(height: 12),
      Text('הצעות', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (e, n) in Trend.suggestions)
          ActionChip(
            label: Text('$e $n'),
            onPressed: () => setState(() {
              emoji = e;
              name = n;
              emojiController.text = e;
              nameController.text = n;
            }),
          ),
      ]),
    ]),
    onSave: () => store.edit((f) => TrendActions(f).upsert(trend
      ..['name'] = name.trim().isEmpty ? 'מגמה חדשה' : name.trim()
      ..['emoji'] = emoji.trim().isEmpty ? '🏷️' : emoji.trim()
      ..['monthlyLimit'] = jsonNumber(limit)
      ..['cardIDs'] = [?withCard])),
  );
  if (saved && withCard == null && context.mounted) {
    Navigator.push(context, glassRoute((_) => TrendDetailScreen(trendId: trend['id'] as String)));
  }
}

/// One trend: its months, items and settings (TrendDetailView).
class TrendDetailScreen extends StatefulWidget {
  const TrendDetailScreen({super.key, required this.trendId});
  final String trendId;

  @override
  State<TrendDetailScreen> createState() => _TrendDetailScreenState();
}

class _TrendDetailScreenState extends State<TrendDetailScreen> {
  var _date = DateTime.now();
  var _amount = 0.0;
  var _note = '';
  var _key = 0;

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final trend = _trends(store.money).where((t) => t.id == widget.trendId).firstOrNull;
      if (trend == null) return const Scaffold(body: Center(child: Text('המגמה נמחקה')));
      final stats = TrendCalc.stats(store.money, trend);
      final items = TrendCalc.items(store.money, trend);
      final id = widget.trendId;
      void setField(String key, dynamic value) => store.edit((f) {
            final t = JObj(f.money.raw).objects('trends').where((t) => t['id'] == id).firstOrNull;
            if (t != null) t[key] = value;
          });
      return Scaffold(
        appBar: AppBar(title: Text('${trend.emoji} ${trend.name}')),
        body: PageList(children: [
          SectionCard(
            title: 'לפי חודש',
            subtitle: 'החודש נקבע לפי תאריך הקנייה. מגמות הן לניתוח בלבד — הן לא משנות את התקציב והסיכום.',
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: TrendBars(months: stats.months, limit: trend.monthlyLimit, height: 90),
              ),
              AmountRow('החודש', stats.thisMonth),
              AmountRow('חודש שעבר', stats.lastMonth),
              AmountRow('ממוצע לחודש', stats.monthlyAverage),
              AmountRow('סה״כ (${stats.count} פריטים)', stats.total, bold: true),
            ],
          ),
          SectionCard(
            title: 'הוספה',
            subtitle: 'הוצאה ידנית — למשל מזומן, ביט, או מישהו אחר ששילם ואתה החזרת. היא נרשמת רק במגמה, לא בעו״ש.',
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.add_circle_outline, size: 18),
                    label: const Text('הוספת חיובי אשראי ותנועות…'),
                    onPressed: () => Navigator.push(context, glassRoute((_) => _TrendPicker(trendId: id))),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  SizedBox(width: 180, child: DateField(label: 'תאריך', value: _date, onChanged: (v) => setState(() => _date = v ?? _date))),
                  SizedBox(
                    width: 230,
                    child: TextInput(key: ValueKey('note$_key'), label: 'תיאור (למשל: מזומן במסעדה)', initial: '', onChanged: (v) => _note = v),
                  ),
                  SizedBox(
                    width: 140,
                    child: NumberField(key: ValueKey('amount$_key'), label: 'סכום', suffix: '₪', value: 0, onChanged: (v) => setState(() => _amount = v)),
                  ),
                  FilledButton.tonal(
                    onPressed: _amount == 0
                        ? null
                        : () {
                            store.edit((f) => TrendActions(f).addEntry(id, date: _date, amount: _amount, note: _note.trim()));
                            setState(() {
                              _amount = 0;
                              _note = '';
                              _key++;
                            });
                          },
                    child: const Text('הוסף'),
                  ),
                ]),
              ),
            ],
          ),
          SectionCard(title: 'פריטים (${items.length})', children: [
            if (items.isEmpty) const EmptyHint('עוד אין פריטים במגמה.'),
            for (final item in items) _ItemRow(item: item, trendId: id),
          ]),
          SectionCard(title: 'הגדרות', children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextInput(label: 'שם', initial: trend.name, onChanged: (v) => setField('name', v)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextInput(label: 'אימוג׳י', initial: trend.emoji, onChanged: (v) => setField('emoji', v)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: NumberField(
                  label: 'תקרה חודשית (0 = בלי)', suffix: '₪', value: trend.monthlyLimit, onChanged: (v) => setField('monthlyLimit', jsonNumber(v))),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text('מחיקת המגמה…', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () async {
                if (await confirm(context, 'למחוק את המגמה?', 'החיובים עצמם לא נמחקים — רק השיוך שלהם למגמה.', ok: 'מחק') && context.mounted) {
                  store.edit((f) => TrendActions(f).delete(id));
                  Navigator.pop(context);
                }
              },
            ),
          ]),
        ]),
      );
    });
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, required this.trendId});
  final TrendItem item;
  final String trendId;

  Future<void> _share(BuildContext context) async {
    final store = context.store;
    var value = item.amount;
    await showEditor(
      context,
      title: 'רק חלק מהחיוב שייך למגמה',
      builder: (context, setState) => NumberField(label: 'סכום', suffix: '₪', value: value, autofocus: true, onChanged: (v) => value = v),
      onSave: () => store.edit((f) => TrendActions(f).setShare(value > 0 ? value : null, item.sourceId, trendId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final isCard = item.source == TrendSource.card;
    return ListTile(
      title: Text(item.title),
      subtitle: Text('${Fmt.date(item.date)} · ${item.detail}${item.fullAmount == null ? '' : ' · מתוך ${Fmt.money(item.fullAmount!)}'}'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(Fmt.money(item.amount), textDirection: TextDirection.rtl, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontFeatures: tabular)),
        PopupMenuButton<VoidCallback>(
          tooltip: 'פעולות',
          onSelected: (a) => a(),
          itemBuilder: (_) => [
            if (isCard) PopupMenuItem(value: () => _share(context), child: const Text('רק חלק מהחיוב שייך למגמה…')),
            if (isCard && item.fullAmount != null)
              PopupMenuItem(
                value: () => store.edit((f) => TrendActions(f).setShare(null, item.sourceId, trendId)),
                child: const Text('החזר לסכום המלא'),
              ),
            PopupMenuItem(value: () => store.edit((f) => TrendActions(f).removeItem(item, trendId)), child: const Text('הסר מהמגמה')),
          ],
        ),
      ]),
    );
  }
}

/// TrendPickerSheet: card charges and expenses to add to the trend.
class _TrendPicker extends StatefulWidget {
  const _TrendPicker({required this.trendId});
  final String trendId;

  @override
  State<_TrendPicker> createState() => _TrendPickerState();
}

class _TrendPickerState extends State<_TrendPicker> {
  var _search = '';
  var _onlyUnassigned = false;

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final money = store.money;
      final trends = _trends(money);
      final trend = trends.where((t) => t.id == widget.trendId).firstOrNull;
      if (trend == null) return const Scaffold(body: Center(child: Text('המגמה נמחקה')));
      final q = _search.trim().toLowerCase();
      final assigned = {for (final t in trends) ...t.cardIDs};
      final cards = CardData(money)
          .cardTransactions
          .where((t) => q.isEmpty || t.merchant.toLowerCase().contains(q) || t.category.toLowerCase().contains(q))
          .where((t) => !_onlyUnassigned || !assigned.contains(t.id))
          .toList()
        ..sort((a, b) => b.date.compareTo(a.date));
      final transactions = money.transactions
          .where((t) => t.kind == TransactionKind.expense && t.salaryKey == null)
          .where((t) => q.isEmpty || t.title.toLowerCase().contains(q))
          .toList()
        ..sort((a, b) => b.date.compareTo(a.date));
      final inCards = trend.cardIDs.toSet(), inTx = trend.transactionIDs.toSet();
      return Scaffold(
        appBar: AppBar(title: Text('הוספה ל${trend.name}')),
        body: PageList(children: [
          SectionCard(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'חיפוש לפי בית עסק או קטגוריה', border: OutlineInputBorder()),
                onChanged: (v) => setState(() => _search = v),
              ),
            ),
            SwitchListTile(
              title: const Text('רק חיובים שלא שויכו לאף מגמה'),
              value: _onlyUnassigned,
              onChanged: (v) => setState(() => _onlyUnassigned = v),
            ),
          ]),
          SectionCard(title: 'חיובי אשראי', children: [
            if (cards.isEmpty) const EmptyHint('אין חיובים. מייבאים אותם במסך ״אשראי״.'),
            for (final t in cards)
              CheckboxListTile(
                controlAffinity: ListTileControlAffinity.leading,
                value: inCards.contains(t.id),
                onChanged: (_) => store.edit((f) => TrendActions(f).toggleCard(t.id, widget.trendId)),
                title: Text(t.merchant),
                subtitle: Text('${Fmt.date(t.date)}${t.category.isEmpty ? '' : ' · ${t.category}'}'),
                secondary: Text(Fmt.money(t.amount), textDirection: TextDirection.rtl, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontFeatures: tabular)),
              ),
          ]),
          if (transactions.isNotEmpty)
            SectionCard(title: 'תנועות (הוצאות)', children: [
              for (final t in transactions)
                CheckboxListTile(
                  controlAffinity: ListTileControlAffinity.leading,
                  value: inTx.contains(t.id),
                  onChanged: (_) => store.edit((f) => TrendActions(f).toggleTransaction(t.id, widget.trendId)),
                  title: Text(t.title),
                  subtitle: Text(Fmt.date(t.date)),
                  secondary: Text(Fmt.money(t.amount), textDirection: TextDirection.rtl, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontFeatures: tabular)),
                ),
            ]),
        ]),
      );
    });
  }
}
