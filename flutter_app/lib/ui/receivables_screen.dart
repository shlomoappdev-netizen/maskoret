import 'package:flutter/material.dart';

import '../data/card.dart';
import '../data/fmt.dart';
import '../data/json.dart';
import '../data/models.dart';
import '../data/receivables.dart';
import 'common.dart';
import 'theme.dart';

/// Debts you can link an income to: still open, or the one it's already linked to (Store.openReceivables).
List<Receivable> openReceivables(MoneyData money, {String? including}) {
  final cards = CardData(money);
  final tx = money.transactions;
  return cards.receivables
      .where((r) => (!r.forgiven && cards.outstanding(r, tx) > 0.005) || (including != null && r.incomeIDs.contains(including)))
      .toList()
    ..sort((a, b) => a.person.compareTo(b.person));
}

/// "חייבים לי" — what you paid for others and what came back (ReceivablesView.swift).
class ReceivablesScreen extends StatefulWidget {
  const ReceivablesScreen({super.key});

  @override
  State<ReceivablesScreen> createState() => _ReceivablesScreenState();
}

class _ReceivablesScreenState extends State<ReceivablesScreen> {
  var _showClosed = false;

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final money = store.money;
      final cards = CardData(money);
      final tx = money.transactions;
      final theme = Theme.of(context);
      final active = cards.receivables.where((r) => cards.outstanding(r, tx) > 0.005).toList();
      final settled = cards.receivables.where((r) => cards.outstanding(r, tx) <= 0.005).toList();
      void openNew() => Navigator.push(context, glassRoute((_) => const ReceivableEditor()));
      if (cards.receivables.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.assignment_return_outlined, size: 56, color: theme.colorScheme.primary),
                const SizedBox(height: 12),
                Text('אף אחד לא חייב לך', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text(
                  'קנית למישהו משהו והוא יחזיר לך? בעמוד ״כרטיס אשראי״ ← ״צמד ל…״ ← ״מישהו צריך להחזיר לי…״, או ״חוב חדש״ כאן.\n'
                  'מה ששילמת בשביל אחרים לא נספר כהוצאה שלך, וההחזר (למשל בביט) לא נספר כהכנסה — ורואים בדיוק מי חייב כמה.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: openNew, child: const Text('חוב חדש')),
              ]),
            ),
          ),
        );
      }
      final debtors = cards.debtors(tx).where((d) => d.amount > 0.005).toList();
      return Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          heroTag: 'new-debt',
          icon: const Icon(Icons.add),
          label: const Text('חוב חדש'),
          onPressed: openNew,
        ),
        body: PageList(children: [
          Text('סה״כ פתוח: ${Fmt.money(cards.totalOwedToMe(tx))}', style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          SectionCard(title: 'מי חייב לי', children: [
            if (debtors.isEmpty) const EmptyHint('כולם החזירו 🎉'),
            for (final d in debtors) AmountRow(d.person.isEmpty ? 'ללא שם' : d.person, d.amount, color: Colors.orange.shade700),
          ]),
          for (final r in active) _Row(r: r, cards: cards, transactions: tx),
          if (settled.isNotEmpty)
            SectionCard(children: [
              ListTile(
                title: Text('הוחזרו / ויתרתי (${settled.length})'),
                trailing: Icon(_showClosed ? Icons.expand_less : Icons.expand_more),
                onTap: () => setState(() => _showClosed = !_showClosed),
              ),
            ]),
          if (_showClosed)
            for (final r in settled) _Row(r: r, cards: cards, transactions: tx),
        ]),
      );
    });
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.r, required this.cards, required this.transactions});
  final Receivable r;
  final CardData cards;
  final List<MoneyTransaction> transactions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final out = cards.outstanding(r, transactions);
    final back = cards.returned(r, transactions);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Glass(
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => Navigator.push(context, glassRoute((_) => ReceivableEditor(id: r.id))),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(r.person.isEmpty ? 'ללא שם' : r.person,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    Text(
                      '${r.note.isEmpty ? '' : '${r.note} · '}${Fmt.date(r.createdAt)} · שילמתי ${Fmt.money(r.expected)} · הוחזר ${Fmt.money(back)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ]),
                ),
                if (r.forgiven)
                  Text('ויתרתי', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))
                else if (out > 0.005)
                  Text(Fmt.money(out),
                      textDirection: TextDirection.rtl,
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w600, color: Colors.orange.shade700, fontFeatures: tabular))
                else
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.check_circle, color: Colors.green.shade700, size: 18),
                    const SizedBox(width: 4),
                    Text('הוחזר', style: TextStyle(color: Colors.green.shade700)),
                  ]),
              ]),
              if (r.expected > 0 && !r.forgiven) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (back / r.expected).clamp(0, 1).toDouble(),
                    minHeight: 6,
                    color: Colors.green.shade600,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// One debt: who, what you paid for them, and what came back (ReceivableEditor in Swift). Works on a copy that's
/// saved with "שמירה"; a return added "to the checking account" becomes a transaction right away, like in Swift.
class ReceivableEditor extends StatefulWidget {
  const ReceivableEditor({super.key, this.id});
  final String? id;

  @override
  State<ReceivableEditor> createState() => _ReceivableEditorState();
}

class _ReceivableEditorState extends State<ReceivableEditor> {
  late Json r;
  late final bool exists;
  var _returnAmount = 0.0;
  var _returnNote = 'ביט';
  var _returnDate = DateTime.now();
  var _toChecking = true;
  var _returnKey = 0;
  final _person = TextEditingController();

  @override
  void dispose() {
    _person.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final saved = widget.id == null
        ? null
        : CardData(context.getInheritedWidgetOfExactType<AppScope>()!.store.money).receivables.where((x) => x.id == widget.id).firstOrNull;
    exists = saved != null;
    r = saved == null ? ReceivableActions.create() : deepCopy(saved.json) as Json;
    for (final k in ['cardShares', 'transactionShares']) {
      r[k] = (r[k] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    }
    for (final k in ['incomeIDs', 'cardCreditIDs', 'returns']) {
      r[k] = (r[k] as List?) ?? <dynamic>[];
    }
    _person.text = r['person'] as String? ?? '';
  }

  Receivable get view => Receivable(r);
  Map<String, dynamic> get cardShares => r['cardShares'] as Map<String, dynamic>;
  Map<String, dynamic> get transactionShares => r['transactionShares'] as Map<String, dynamic>;
  List<dynamic> get incomeIDs => r['incomeIDs'] as List;
  List<dynamic> get cardCreditIDs => r['cardCreditIDs'] as List;
  List<dynamic> get returns => r['returns'] as List;

  void _save() {
    final store = context.store;
    r['person'] = (r['person'] as String? ?? '').trim();
    // Links added through the store while the editor was open.
    final saved = CardData(store.money).receivables.where((x) => x.id == r['id']).firstOrNull;
    for (final id in saved?.incomeIDs ?? const <String>[]) {
      if (!incomeIDs.contains(id)) incomeIDs.add(id);
    }
    store.edit((f) => ReceivableActions(f).upsert(r));
    Navigator.pop(context);
  }

  void _addReturn() {
    final entry = ReceivableActions.returnEntry(date: _returnDate, amount: _returnAmount, note: _returnNote.trim());
    if (_toChecking) {
      final person = (r['person'] as String? ?? '').trim();
      late String id;
      context.store.edit((f) => id = ReceivableActions(f).addReturnIncome(person.isEmpty ? 'חבר' : person, entry));
      setState(() => incomeIDs.add(id));
    } else {
      setState(() => returns.add(entry));
    }
    setState(() {
      _returnAmount = 0;
      _returnKey++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final money = store.money;
      final cards = CardData(money);
      final theme = Theme.of(context);
      final since = DateTime.now().subtract(const Duration(days: 120));
      final recentCharges = cards.cardTransactions.where((t) => !t.date.isBefore(since) && t.amount > 0 && !t.ignored).toList()
        ..sort((a, b) => b.date.compareTo(a.date));
      final recentExpenses = money.transactions.where((t) => t.kind == TransactionKind.expense && !t.date.isBefore(since)).toList()
        ..sort((a, b) => b.date.compareTo(a.date));
      final used = {for (final x in cards.receivables) if (x.id != r['id']) ...x.incomeIDs};
      final incomes = money.transactions
          .where((t) => t.kind == TransactionKind.income && t.salaryKey == null && !t.date.isBefore(since) && !used.contains(t.id))
          .toList()
        ..sort((a, b) => b.date.compareTo(a.date));
      final credits = cards.cardTransactions.where((t) => t.amount < 0).toList()..sort((a, b) => b.date.compareTo(a.date));
      final returnedNow = cards.returned(view, money.transactions);
      final people = cards.people;
      final person = r['person'] as String? ?? '';

      Widget share(String id, Map<String, dynamic> shares, String title, String subtitle, double full) {
        final value = (shares[id] as num?)?.toDouble();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            Checkbox(
              value: value != null,
              onChanged: (on) => setState(() => on == true ? shares[id] = jsonNumber(full) : shares.remove(id)),
            ),
            Expanded(child: _Line(title, subtitle, full)),
            if (value != null)
              SizedBox(
                width: 120,
                child: NumberField(label: 'החלק שלו', suffix: '₪', value: value, onChanged: (v) => shares[id] = jsonNumber(v)),
              ),
          ]),
        );
      }

      Widget check(bool on, ValueChanged<bool> changed, Widget child) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              Checkbox(value: on, onChanged: (v) => setState(() => changed(v == true))),
              Expanded(child: child),
            ]),
          );

      return Scaffold(
        appBar: AppBar(
          title: Text(person.isEmpty ? 'חוב חדש' : 'חייב/ת לי: $person'),
          actions: [
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 12),
              child: FilledButton(onPressed: _save, child: const Text('שמירה')),
            ),
          ],
        ),
        body: PageList(children: [
          SectionCard(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _person,
                decoration: const InputDecoration(labelText: 'מי', hintText: 'שם', border: OutlineInputBorder()),
                onChanged: (v) => setState(() => r['person'] = v),
              ),
            ),
            if (people.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(spacing: 8, children: [
                  for (final p in people)
                    ChoiceChip(label: Text(p), selected: person == p, onSelected: (_) => setState(() {
                          r['person'] = p;
                          _person.text = p;
                        })),
                ]),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextInput(label: 'על מה', initial: r['note'] as String? ?? '', onChanged: (v) => r['note'] = v),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: NumberField(
                label: 'שילמתי במזומן / בלי רישום',
                suffix: '₪',
                value: view.manualAmount,
                onChanged: (v) => setState(() => r['manualAmount'] = jsonNumber(v)),
              ),
            ),
          ]),
          SectionCard(
            title: 'מה שילמתי בשבילו — ${Fmt.money(view.expected)}',
            subtitle: 'סמן את החיובים, ושנה את הסכום אם רק חלק מהקנייה שלו. החלק הזה לא נספר כהוצאה שלך.',
            children: [
              for (final t in recentCharges) share(t.id, cardShares, t.merchant, '${Fmt.date(t.date)} · אשראי', t.amount),
              for (final t in recentExpenses) share(t.id, transactionShares, t.title, '${Fmt.date(t.date)} · תנועה', t.amount),
              if (recentCharges.isEmpty && recentExpenses.isEmpty) const EmptyHint('אין חיובים או הוצאות מ-4 החודשים האחרונים'),
            ],
          ),
          SectionCard(
            title: 'מה הוחזר — ${Fmt.money(returnedNow)} · נשאר ${Fmt.money((view.expected - returnedNow).clamp(0, double.infinity))}',
            subtitle: 'סמן הכנסה שכבר רשומה (למשל העברה בביט), זיכוי באשראי, או רשום החזר חדש. הכנסה שמסומנת כאן לא נספרת '
                'כהכנסה רגילה — גם לא במעשרות.',
            children: [
              for (final t in incomes)
                check(incomeIDs.contains(t.id), (on) => on ? incomeIDs.add(t.id) : incomeIDs.remove(t.id),
                    _Line(t.title, '${Fmt.date(t.date)} · הכנסה', t.amount)),
              for (final t in credits)
                check(cardCreditIDs.contains(t.id), (on) => on ? cardCreditIDs.add(t.id) : cardCreditIDs.remove(t.id),
                    _Line(t.merchant, '${Fmt.date(t.date)} · זיכוי באשראי', t.amount.abs())),
              for (final e in returns.whereType<Map>())
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(children: [
                    IconButton(
                      tooltip: 'הסר',
                      icon: Icon(Icons.remove_circle_outline, color: theme.colorScheme.error),
                      onPressed: () => setState(() => returns.remove(e)),
                    ),
                    Expanded(
                      child: _Line(
                        (e['note'] as String? ?? '').isEmpty ? 'החזר' : e['note'] as String,
                        '${Fmt.date(swiftDateToDateTime(e['date'] as num? ?? 0))} · נרשם ידנית',
                        (e['amount'] as num?)?.toDouble() ?? 0,
                      ),
                    ),
                  ]),
                ),
              const Divider(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  SizedBox(
                    width: 180,
                    child: DateField(label: 'תאריך', value: _returnDate, onChanged: (v) => setState(() => _returnDate = v ?? _returnDate)),
                  ),
                  SizedBox(
                    width: 180,
                    child: TextInput(label: 'איך (ביט, מזומן…)', initial: _returnNote, onChanged: (v) => _returnNote = v),
                  ),
                  SizedBox(
                    width: 150,
                    child: NumberField(
                        key: ValueKey(_returnKey),
                        label: 'סכום',
                        suffix: '₪',
                        value: 0,
                        onChanged: (v) => setState(() => _returnAmount = v)),
                  ),
                  FilledButton.tonal(onPressed: _returnAmount > 0 ? _addReturn : null, child: const Text('קיבלתי')),
                ]),
              ),
              SwitchListTile(
                title: const Text('להוסיף את ההחזר לעו״ש (כתנועה)'),
                value: _toChecking,
                onChanged: (v) => setState(() => _toChecking = v),
              ),
            ],
          ),
          SectionCard(children: [
            SwitchListTile(
              title: const Text('ויתרתי — זו הוצאה שלי'),
              value: view.forgiven,
              onChanged: (v) => setState(() => r['forgiven'] = v),
            ),
            if (exists)
              ListTile(
                leading: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                title: Text('מחיקת החוב', style: TextStyle(color: theme.colorScheme.error)),
                onTap: () async {
                  if (await confirm(context, 'למחוק את החוב?', 'אי אפשר לבטל את זה.', ok: 'מחק') && context.mounted) {
                    store.edit((f) => ReceivableActions(f).delete(r['id'] as String));
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

class _Line extends StatelessWidget {
  const _Line(this.title, this.subtitle, this.amount);
  final String title;
  final String subtitle;
  final double amount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title),
            Text(subtitle, style: theme.textTheme.bodySmall),
          ]),
        ),
        const SizedBox(width: 8),
        Text(Fmt.money(amount), textDirection: TextDirection.rtl, style: const TextStyle(fontFeatures: tabular)),
      ]),
    );
  }
}

/// "מישהו צריך להחזיר לי" from a card charge (OwedQuickSheet).
Future<void> showOwedQuick(BuildContext context, CardTransaction tx) async {
  final store = context.store;
  final people = CardData(store.money).people;
  var person = '';
  var amount = tx.amount;
  var note = '';
  final personController = TextEditingController();
  await showEditor(
    context,
    title: 'מישהו צריך להחזיר לי',
    builder: (context, setState) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('${tx.merchant} · ${Fmt.date(tx.date)} · ${Fmt.money(tx.amount)}', style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 12),
      TextField(
        controller: personController,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'מי', hintText: 'שם', border: OutlineInputBorder()),
        onChanged: (v) => person = v,
      ),
      if (people.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          for (final p in people)
            ChoiceChip(
              label: Text(p),
              selected: person == p,
              onSelected: (_) => setState(() {
                person = p;
                personController.text = p;
              }),
            ),
        ]),
      ],
      const SizedBox(height: 12),
      NumberField(label: 'כמה הוא צריך להחזיר', suffix: '₪', value: amount, onChanged: (v) => amount = v),
      const SizedBox(height: 12),
      TextInput(label: 'הערה', initial: '', onChanged: (v) => note = v),
      const SizedBox(height: 8),
      Text('אם יש לו כבר חוב פתוח — החיוב יתווסף אליו. את ההחזר (למשל ביט) מסמנים בעמוד ״חייבים לי״.',
          style: Theme.of(context).textTheme.bodySmall),
    ]),
    onSave: () {
      if (amount <= 0) return;
      store.edit((f) => ReceivableActions(f).addCardToReceivable(tx,
          person: person.trim().isEmpty ? 'חבר' : person, amount: amount, note: note.trim().isEmpty ? tx.merchant : note.trim()));
    },
  );
  // Not disposed here: the window's closing animation still shows the field (it's collected with it).
}
