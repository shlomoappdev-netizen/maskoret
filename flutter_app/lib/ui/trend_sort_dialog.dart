import 'package:flutter/material.dart';

import '../data/fmt.dart';
import '../data/json.dart';
import '../data/trend_suggestions.dart';
import '../data/trends.dart';
import 'common.dart';

/// After a card statement was imported: the new charges that aren't in a trend, merchant by merchant, each with the
/// trend the app suggests (TrendSortSheet in TrendSortView.swift). Charges of merchants with an "always" rule were
/// already assigned. Shows nothing when there are no trends or nothing to sort.
Future<void> offerTrendSorting(BuildContext context, Set<String> newIDs) async {
  final store = context.store;
  if (newIDs.isEmpty) return;
  store.edit((f) => TrendSuggestions.applyRules(f, newIDs));
  final items = TrendSuggestions.items(store.money, newIDs);
  if (items.isEmpty || !context.mounted) return;
  await showDialog<void>(context: context, builder: (_) => TrendSortDialog(items: items));
}

class TrendSortDialog extends StatefulWidget {
  const TrendSortDialog({super.key, required this.items});
  final List<TrendSuggestionItem> items;

  @override
  State<TrendSortDialog> createState() => _TrendSortDialogState();
}

class _TrendSortDialogState extends State<TrendSortDialog> {
  int _index = 0;
  String? _trendID;
  bool _always = false;
  bool _asking = false;
  int _assigned = 0;

  TrendSuggestionItem get _item => widget.items[_index];

  @override
  void initState() {
    super.initState();
    _trendID = _item.trendID;
    WidgetsBinding.instance.addPostFrameCallback((_) => _askModel());
  }

  /// One request to the cloud model (when it's set up) for the merchants the app couldn't place by itself.
  Future<void> _askModel() async {
    if (!mounted) return;
    final scope = context.scope;
    if (!scope.insights.canAskCloud || widget.items.every((i) => i.trendID != null)) return;
    setState(() => _asking = true);
    final answer = await scope.insights.complete(TrendSuggestions.aiSystem, TrendSuggestions.aiPrompt(scope.store.money, widget.items));
    if (!mounted) return;
    setState(() {
      _asking = false;
      if (answer != null) TrendSuggestions.applyAIAnswer(scope.store.money, widget.items, answer);
      _trendID ??= _item.trendID;
    });
  }

  void _next() {
    if (_index + 1 >= widget.items.length) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _index++;
      _trendID = _item.trendID;
      _always = false;
    });
  }

  void _confirm() {
    final trend = _trendID;
    if (trend == null) return;
    final item = _item, always = _always;
    context.store.edit((f) => TrendSuggestions.assign(f, item, trend, always: always));
    _assigned++;
    _next();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = context.store;
    final trends = JObj(store.money.raw).objects('trends').map(Trend.new).toList();
    final item = _item;
    final selected = trends.any((t) => t.id == _trendID) ? _trendID : null;
    final suggested = item.trendID != null && item.trendID == selected;
    final secondary = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return AlertDialog(
      title: Text('לשייך למגמה? (${_index + 1} מתוך ${widget.items.length})'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(item.merchant, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          Text(
            '${item.cardIDs.length == 1 ? 'עסקה אחת' : '${item.cardIDs.length} עסקאות'} · ${Fmt.money(item.total)}'
            '${item.category.isEmpty ? '' : ' · ${item.category}'}',
            style: secondary,
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            key: ValueKey('$_index-$selected'),
            initialValue: selected,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'מגמה'),
            hint: const Text('בחר מגמה'),
            items: [for (final t in trends) DropdownMenuItem(value: t.id, child: Text('${t.emoji} ${t.name}'))],
            onChanged: (v) => setState(() => _trendID = v),
          ),
          if (suggested && item.reasonText.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 6), child: Text(item.reasonText, style: secondary))
          else if (_asking && item.trendID == null)
            Padding(padding: const EdgeInsets.only(top: 6), child: Text('מבקש הצעה מה-AI…', style: secondary)),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            value: _always,
            onChanged: (v) => setState(() => _always = v ?? false),
            title: const Text('תמיד לבית העסק הזה'),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(_assigned > 0 ? 'סיום' : 'לא עכשיו')),
        TextButton(onPressed: _next, child: const Text('דילוג')),
        FilledButton(onPressed: selected == null ? null : _confirm, child: const Text('אישור')),
      ],
    );
  }
}
