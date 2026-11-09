import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../data/card.dart';
import '../data/fmt.dart';
import '../data/receivables.dart';
import '../data/json.dart';
import '../data/models.dart';
import '../data/money_calc.dart';
import 'common.dart';
import 'home_shell.dart';
import 'receivables_screen.dart';
import 'theme.dart';

IconData accountIcon(AccountKind k) => switch (k) {
      AccountKind.checking => Icons.account_balance,
      AccountKind.savings => Icons.savings_outlined,
      AccountKind.deposit => Icons.lock_outline,
      AccountKind.pension => Icons.beach_access_outlined,
    };

// MARK: - Accounts and savings

class AccountsScreen extends StatelessWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final money = store.money;
      final budget = store.file.budget;
      final history = store.file.history;
      final calc = MoneyCalc(money.primeRate);
      final now = DateTime.now();
      final tx = money.transactions;
      return Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          heroTag: 'add-account',
          icon: const Icon(Icons.add),
          label: const Text('חשבון'),
          onPressed: () => editAccount(context, null),
        ),
        body: PageList(children: [
          SectionCard(title: 'סיכום', children: [
            AmountRow('עו״ש', calc.total(money, {AccountKind.checking}, budget: budget, history: history)),
            AmountRow('חסכונות ופיקדונות', calc.total(money, {AccountKind.savings, AccountKind.deposit}, budget: budget, history: history)),
            AmountRow('פנסיה', calc.total(money, {AccountKind.pension}, budget: budget, history: history)),
          ]),
          for (final kind in AccountKind.values)
            if (money.accounts.any((a) => a.kind == kind))
              SectionCard(
                title: kind.title,
                children: [
                  for (final a in money.accounts.where((a) => a.kind == kind))
                    ListTile(
                      leading: Icon(accountIcon(a.kind)),
                      title: Text(a.name),
                      subtitle: Text(_subtitle(a, calc, now)),
                      trailing: Text(Fmt.money(money.balance(a, now, budget, history)), textDirection: TextDirection.rtl,
                          style: Theme.of(context).textTheme.titleMedium),
                      onTap: () => Navigator.push(context, glassRoute((_) => AccountDetail(accountId: a.id))),
                    ),
                ],
              ),
        ]),
      );
    });
  }

  static String _subtitle(Account a, MoneyCalc calc, DateTime now) {
    final parts = <String>[];
    final last = a.latestBalance;
    parts.add(last == null ? 'עוד לא עודכנה יתרה' : 'יתרה עודכנה ב-${Fmt.date(last.date)}');
    if (a.kind != AccountKind.checking) {
      final rate = calc.effectiveRate(a, now);
      if (rate != 0) parts.add('${a.kind.rateTitle} ${Fmt.percent((rate * 100).round() / 100)}');
    }
    if (a.maturityDate != null) parts.add('פירעון ${Fmt.date(a.maturityDate!)}');
    return parts.join(' · ');
  }
}

class AccountDetail extends StatelessWidget {
  const AccountDetail({super.key, required this.accountId});
  final String accountId;

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final money = store.money;
      final a = money.account(accountId);
      if (a == null) return const Scaffold(body: Center(child: Text('החשבון נמחק')));
      final calc = MoneyCalc(money.primeRate);
      final now = DateTime.now();
      final balances = a.balances..sort((x, y) => y.date.compareTo(x.date));
      // Only what moves this account's balance: not a card purchase, nor an older income that still carries a stale target.
      final related = money.transactions.where((t) => t.effectOn(a.id) != 0).toList()
        ..sort((x, y) => y.date.compareTo(x.date));
      return Scaffold(
        appBar: AppBar(title: Text(a.name), actions: [
          IconButton(tooltip: 'עריכה', icon: const Icon(Icons.edit_outlined), onPressed: () => editAccount(context, a)),
        ]),
        floatingActionButton: FloatingActionButton.extended(
          icon: const Icon(Icons.edit_calendar_outlined),
          label: const Text('עדכון יתרה'),
          onPressed: () => _editBalance(context, a, null),
        ),
        body: PageList(children: [
          SectionCard(title: 'יתרה משוערת היום', children: [
            AmountRow(a.kind.title, money.balance(a, now, store.file.budget, store.file.history), bold: true),
            if (a.kind.hasInterest || a.kind == AccountKind.pension)
              ListTile(
                dense: true,
                title: Text(a.kind.rateTitle),
                trailing: Text(a.isPrimeLinked
                    ? 'P−${Fmt.percent(a.primeMinus)} = ${Fmt.percent(((calc.effectiveRate(a, now)) * 100).round() / 100)}'
                    : Fmt.percent(a.annualRate)),
              ),
            if (a.monthlyContribution > 0)
              ListTile(dense: true, title: const Text('הפקדה חודשית'), trailing: Text(Fmt.money(a.monthlyContribution))),
            if (a.note.isNotEmpty) ListTile(dense: true, title: Text(a.note)),
          ]),
          SectionCard(title: 'עדכוני יתרה', subtitle: 'מה היה בחשבון בתאריך שבדקת', children: [
            if (balances.isEmpty) const EmptyHint('עוד לא עדכנת יתרה. בדוק כמה יש בחשבון והוסף.'),
            for (final e in balances)
              AmountRow(Fmt.date(e.date), e.amount, detail: e.note.isEmpty ? null : e.note, onTap: () => _editBalance(context, a, e)),
          ]),
          if (related.isNotEmpty)
            SectionCard(title: 'תנועות', children: [
              for (final t in related)
                AmountRow(t.title, t.effectOn(a.id).abs(),
                    negative: t.effectOn(a.id) < 0, detail: Fmt.date(t.date), onTap: () => editTransaction(context, t)),
            ]),
        ]),
      );
    });
  }

  Future<void> _editBalance(BuildContext context, Account a, BalanceEntry? existing) async {
    final store = context.store;
    final draft = existing != null
        ? deepCopy(existing.json) as Json
        : BalanceEntry.create(date: DateTime.now(), amount: 0);
    final o = JObj(draft);
    await showEditor(
      context,
      title: existing == null ? 'עדכון יתרה' : 'עריכת עדכון',
      builder: (ctx, setState) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        NumberField(label: 'היתרה', suffix: '₪', value: o.d('amount'), autofocus: existing == null, onChanged: (v) => o.set('amount', v)),
        gap,
        DateField(label: 'בתאריך', value: o.date('date'), onChanged: (v) => setState(() => o.set('date', v))),
        gap,
        TextInput(label: 'הערה (לא חובה)', initial: o.s('note'), onChanged: (v) => o.set('note', v)),
      ]),
      onSave: () => store.edit((f) => f.money.account(a.id)?.upsertBalance(draft)),
      onDelete: existing == null ? null : () => store.edit((f) => f.money.account(a.id)?.removeBalance(existing.id)),
    );
  }
}

Future<void> editAccount(BuildContext context, Account? existing) async {
  final store = context.store;
  final draft = Account(existing != null ? deepCopy(existing.json) as Json : Account.create(kind: AccountKind.savings));
  await showEditor(
    context,
    title: existing == null ? 'חשבון חדש' : 'עריכת ${existing.name}',
    builder: (ctx, setState) {
      final k = draft.kind;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextInput(label: 'שם', initial: draft.name, autofocus: existing == null, onChanged: (v) => draft.name = v),
        gap,
        DropdownButtonFormField<AccountKind>(
          initialValue: k,
          decoration: const InputDecoration(labelText: 'סוג', border: OutlineInputBorder()),
          items: [for (final x in AccountKind.values) DropdownMenuItem(value: x, child: Text(x.title))],
          onChanged: (v) => setState(() => draft.kind = v!),
        ),
        if (k != AccountKind.checking) ...[
          gap,
          if (k != AccountKind.pension)
            SegmentedButton<RateType>(
              segments: [for (final r in RateType.values) ButtonSegment(value: r, label: Text(r.title))],
              selected: {draft.rateType},
              onSelectionChanged: (s) => setState(() => draft.rateType = s.first),
            ),
          gap,
          if (draft.isPrimeLinked)
            NumberField(
              label: 'פריים פחות',
              suffix: '%',
              value: draft.primeMinus,
              helper: 'הפריים כרגע ${Fmt.percent(store.money.primeRate)}${draft.rateTiers.isNotEmpty ? ' · לתוכנית יש מדרגות ריבית (נערכות באייפון/מק)' : ''}',
              onChanged: (v) => draft.primeMinus = v,
            )
          else
            NumberField(label: k.rateTitle, suffix: '%', value: draft.annualRate, onChanged: (v) => draft.annualRate = v),
          if (k != AccountKind.pension) ...[
            gap,
            DropdownButtonFormField<Compounding>(
              initialValue: draft.compounding,
              decoration: const InputDecoration(labelText: 'צבירת ריבית', border: OutlineInputBorder()),
              items: [for (final c in Compounding.values) DropdownMenuItem(value: c, child: Text(c.title))],
              onChanged: (v) => draft.compounding = v!,
            ),
            gap,
            NumberField(label: 'מס על הריבית', suffix: '%', value: draft.interestTax, onChanged: (v) => draft.interestTax = v),
          ],
          gap,
          NumberField(
            label: k == AccountKind.pension ? 'הפקדה חודשית (עובד + מעסיק)' : 'הפקדה חודשית קבועה',
            suffix: '₪',
            value: draft.monthlyContribution,
            onChanged: (v) => setState(() => draft.monthlyContribution = v),
          ),
          if (k != AccountKind.pension && draft.monthlyContribution > 0) ...[
            gap,
            NumberField(
              label: 'יום ההפקדה בחודש',
              value: draft.contributionDay.toDouble(),
              onChanged: (v) => draft.contributionDay = v.round().clamp(1, 28),
            ),
          ],
          if (k == AccountKind.deposit || k == AccountKind.savings) ...[
            gap,
            DateField(label: 'תחילת התוכנית', value: draft.startDate, allowClear: true,
                onChanged: (v) => setState(() => draft.startDate = v)),
            gap,
            DateField(label: 'תאריך פירעון', value: draft.maturityDate, allowClear: true,
                onChanged: (v) => setState(() => draft.maturityDate = v)),
          ],
        ],
        gap,
        TextInput(label: 'הערה', initial: draft.note, onChanged: (v) => draft.note = v),
      ]);
    },
    onSave: () => store.edit((f) {
      if (draft.name.trim().isEmpty) draft.name = draft.kind.title;
      f.money.upsertAccount(draft.json);
    }),
    onDelete: existing == null ? null : () => store.edit((f) => f.money.deleteAccount(existing.id, f.budget)),
    deleteLabel: 'מחיקת החשבון',
  );
}

// MARK: - Transactions

class TransactionsScreen extends StatelessWidget {
  const TransactionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(
      builder: (context, store) {
        final money = store.money;
        final now = DateTime.now();
        // How far ahead the statement shows what's expected: the next pay day and card charge, or the last plan.
        final ahead = DateTime(now.year, now.month, now.day + 35, now.hour, now.minute);
        final lastPlan = money.transactions
            .where((t) => t.isPlanned)
            .fold<DateTime?>(null, (d, t) => d == null || t.date.isAfter(d) ? t.date : d);
        final horizon = lastPlan != null && lastPlan.isAfter(ahead) ? lastPlan : ahead;
        final lines = money.checking == null
            ? <LedgerLine>[]
            : money.checkingStatement(horizon, store.file.budget, store.file.history);
        // The quick entry scrolls away with the list (on a phone it took half the screen when it stood still).
        return Scaffold(body: lines.isEmpty ? const _LegacyTransactions() : _Statement(lines: lines));
      },
    );
  }
}

/// "− הוצאה / + הכנסה", a description, an amount and a date — like typing a line into the bank. It goes to the checking.
class _QuickEntry extends StatefulWidget {
  const _QuickEntry();

  @override
  State<_QuickEntry> createState() => _QuickEntryState();
}

class _QuickEntryState extends State<_QuickEntry> {
  var kind = TransactionKind.expense;
  final title = TextEditingController();
  final amount = TextEditingController();
  DateTime date = DateTime.now();

  double? get value => double.tryParse(amount.text.replaceAll(',', '').replaceAll('₪', '').trim());

  @override
  void initState() {
    super.initState();
    amount.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    title.dispose();
    amount.dispose();
    super.dispose();
  }

  void add() {
    final v = value;
    if (v == null || v <= 0) return;
    final store = context.store;
    store.edit((f) {
      final checking = f.money.ensureChecking();
      f.money.upsertTransaction(
        MoneyTransaction.create(kind: kind, accountID: checking.id)
          ..['title'] = title.text.trim()
          ..['amount'] = jsonNumber(v)
          ..['date'] = dateTimeToSwift(date),
      );
    });
    setState(() {
      title.clear();
      amount.clear();
      date = DateTime.now();
    });
    FocusScope.of(context).unfocus();
  }

  Future<void> pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => date = DateTime(d.year, d.month, d.day, date.hour, date.minute));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kindPicker = SegmentedButton<TransactionKind>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: TransactionKind.expense, label: Text('− הוצאה')),
        ButtonSegment(value: TransactionKind.income, label: Text('+ הכנסה')),
      ],
      selected: {kind},
      onSelectionChanged: (v) => setState(() => kind = v.first),
    );
    final detailed = MenuAnchor(
      menuChildren: [
        MenuItemButton(onPressed: () => editTransaction(context, null), child: const Text('הוצאה גדולה…')),
        MenuItemButton(
          onPressed: () => editTransaction(context, null, kind: TransactionKind.income),
          child: const Text('הכנסה (מענק, בונוס, מתנה)…'),
        ),
        MenuItemButton(
          onPressed: () => editTransaction(context, null, kind: TransactionKind.transfer),
          child: const Text('העברה בין חשבונות…'),
        ),
      ],
      builder: (context, controller, _) => TextButton.icon(
        icon: const Icon(Icons.add),
        label: const Text('תנועה מפורטת'),
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
    final titleField = TextField(
      controller: title,
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
        hintText: 'תיאור (למשל: מתנה לחתונה)',
      ),
      onSubmitted: (_) => add(),
    );
    final amountField = SizedBox(
      width: 110,
      child: TextField(
        controller: amount,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.end,
        decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), hintText: '₪ 0'),
        onSubmitted: (_) => add(),
      ),
    );
    final dateButton = OutlinedButton(
      onPressed: pickDate,
      child: Text(
        DateFormat('dd.MM.yy').format(date),
        style: theme.textTheme.bodyMedium?.copyWith(fontFeatures: tabular),
      ),
    );
    final addButton = FilledButton(onPressed: (value ?? 0) > 0 ? add : null, child: const Text('הוסף'));
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: LayoutBuilder(
        builder: (context, c) {
          final header = Row(
            children: [
              Expanded(
                child: Text('עו״ש', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              ),
              detailed,
            ],
          );
          if (c.maxWidth >= 760) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                const SizedBox(height: 6),
                Row(
                  children: [
                    kindPicker,
                    const SizedBox(width: 8),
                    Expanded(child: titleField),
                    const SizedBox(width: 8),
                    amountField,
                    const SizedBox(width: 8),
                    dateButton,
                    const SizedBox(width: 8),
                    addButton,
                  ],
                ),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              const SizedBox(height: 6),
              Row(children: [Expanded(child: kindPicker)]),
              const SizedBox(height: 8),
              titleField,
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: amountField),
                  const SizedBox(width: 8),
                  dateButton,
                  const SizedBox(width: 8),
                  addButton,
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The checking account as a bank statement (statementList in TransactionsView.swift): what's expected first, then
/// month by month, newest first, with the balance after every line.
class _Statement extends StatelessWidget {
  const _Statement({required this.lines});
  final List<LedgerLine> lines;

  static String icon(LedgerLine l) => switch (l.source) {
    LedgerSource.balance => '✔︎',
    LedgerSource.salary => '💰',
    LedgerSource.fixed => '📌',
    LedgerSource.card => '💳',
    LedgerSource.savings => '→',
    LedgerSource.transfer => '⇄',
    LedgerSource.transaction => l.amount > 0 || (l.elsewhere ?? 0) > 0 ? '＋' : '−',
  };

  void open(BuildContext context, LedgerLine l) {
    switch (l.source) {
      case LedgerSource.transaction || LedgerSource.transfer:
        final t = context.store.money.transactions.where((t) => t.id == l.transactionId).firstOrNull;
        if (t != null) editTransaction(context, t);
      case LedgerSource.salary:
        openDest(context, Dest.history);
      case LedgerSource.fixed:
        openDest(context, Dest.expenses);
      case LedgerSource.card:
        if (l.cardKey != null) {
          showActualCharge(context, l);
        } else {
          openDest(context, Dest.card);
        }
      case LedgerSource.savings || LedgerSource.balance:
        openDest(context, Dest.accounts);
    }
  }

  Future<void> menu(BuildContext context, LedgerLine l, Offset at) async {
    final store = context.store;
    final money = store.money;
    final t = money.transactions.where((t) => t.id == l.transactionId).firstOrNull;
    if (t == null) return;
    // An income not linked yet: a payment on a debt, or participation in a shared fixed expense.
    final cards = CardData(money);
    final linkable = t.kind == TransactionKind.income &&
        t.salaryKey == null &&
        !cards.receivables.any((r) => r.incomeIDs.contains(t.id)) &&
        money.sharedCost(t.id) == null;
    final open = linkable ? openReceivables(money) : const <Receivable>[];
    final shared = linkable ? ReceivableActions(store.dashboard).sharedCosts : const <CostItem>[];
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        const PopupMenuItem(value: 'edit', child: Text('עריכה')),
        const PopupMenuItem(value: 'delete', child: Text('מחיקה')),
        if (open.isNotEmpty) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(enabled: false, height: 32, child: Text('זה תשלום על חוב של…')),
          for (final r in open)
            PopupMenuItem(
                value: 'debt:${r.id}',
                child: Text('${r.person} — נשאר ${Fmt.money(cards.outstanding(r, money.transactions))}')),
        ],
        if (shared.isNotEmpty) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(enabled: false, height: 32, child: Text('השתתפות בחיוב משותף')),
          for (final c in shared) PopupMenuItem(value: 'cost:${c.id}', child: Text('${c.name} — ${c.sharedWith}')),
        ],
      ],
    );
    if (!context.mounted || choice == null) return;
    if (choice.startsWith('debt:')) {
      store.edit((f) => ReceivableActions(f).linkIncome(t.id, choice.substring(5)));
      return;
    }
    if (choice.startsWith('cost:')) {
      store.edit((f) => ReceivableActions(f).linkIncomeToSharedCost(t.id, choice.substring(5)));
      return;
    }
    if (choice == 'edit') editTransaction(context, t);
    if (choice == 'delete' &&
        await confirm(context, 'למחוק את התנועה?', 'אי אפשר לבטל את הפעולה.', ok: 'מחיקה') &&
        context.mounted) {
      context.store.edit((f) => f.money.removeTransaction(t.id));
    }
  }

  Widget row(BuildContext context, LedgerLine l, {required bool expected}) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final shown = l.elsewhere ?? l.amount;
    final amountText =
        '${shown > 0
            ? '+'
            : shown < 0
            ? '−'
            : ''}${Fmt.money(shown.abs())}';
    final balance = l.balance.roundToDouble();
    return Opacity(
      opacity: expected ? 0.6 : 1,
      child: GestureDetector(
        onLongPressStart: l.isManual ? (d) => menu(context, l, d.globalPosition) : null,
        child: InkWell(
          onTap: () => open(context, l),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Text(
                    DateFormat('dd.MM').format(l.date),
                    style: theme.textTheme.bodySmall?.copyWith(color: muted, fontFeatures: tabular),
                  ),
                ),
                SizedBox(width: 24, child: Text(icon(l), textAlign: TextAlign.center)),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.title.isEmpty ? '—' : l.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: l.source == LedgerSource.balance ? const TextStyle(fontWeight: FontWeight.w600) : null,
                      ),
                      if (l.note.isNotEmpty) Text(l.note, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                      if (l.transactionId != null)
                        if (ReceivableActions.sharedCostTitle(context.store.dashboard, l.transactionId!) case final cost?)
                          Text('👥 השתתפות ב$cost', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // The amount, and the balance after it under it (leaves the title room on a phone).
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (l.source != LedgerSource.balance)
                      Text(
                        amountText,
                        textDirection: TextDirection.rtl,
                        style: TextStyle(
                          fontFeatures: tabular,
                          color: l.elsewhere != null ? muted : (shown > 0 ? AppColors.positive(context) : null),
                        ),
                      ),
                    Text(
                      'יתרה ${Fmt.money(balance)}',
                      textDirection: TextDirection.rtl,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFeatures: tabular,
                        color: l.balance < 0 ? theme.colorScheme.error : muted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final future = lines.where((l) => l.date.isAfter(now)).toList();
    final past = lines.where((l) => !l.date.isAfter(now)).toList();
    final months = <int, List<LedgerLine>>{};
    for (final l in past) {
      months.putIfAbsent(l.date.year * 100 + l.date.month, () => []).add(l);
    }
    final thisMonth = now.year * 100 + now.month;
    final keys = months.keys.toList()..sort((a, b) => b.compareTo(a));
    return PageList(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 110),
      children: [
        const _QuickEntry(),
        // Planned purchases and moves (also ones paid by card, which the statement folds into the card charge),
        // each on its own line so it can be found and changed.
        const _Planned(),
        if (future.isNotEmpty)
          SectionCard(
            title: 'צפוי — לפי ההכנסות, ההוצאות הקבועות והאשראי',
            children: [for (final l in future) row(context, l, expected: true)],
          ),
        for (final key in keys)
          SectionCard(
            title: '${key == thisMonth ? 'היום · ' : ''}${Fmt.monthTitle(key ~/ 100, key % 100)}',
            children: [for (final l in months[key]!) row(context, l, expected: false)],
          ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: EmptyHint(
            '💰 משכורת · 📌 מהוצאות קבועות · 💳 מכרטיס אשראי · → לחיסכון · ⇄ העברה · ✔︎ יתרה שהקלדת (ממנה החישוב '
            'מתחיל מחדש). לחיצה על שורה שנוצרה לבד פותחת את המסך שלה; שורה שרשמת כאן נפתחת לעריכה, ולחיצה ארוכה מוחקת.',
          ),
        ),
      ],
    );
  }
}

/// "ירד בפועל" for a card charge (ActualChargeSheet in TransactionsView.swift): the bank changed the amount at the last
/// minute — what it really took replaces the statement's (or the estimate) in the checking.
Future<void> showActualCharge(BuildContext context, LedgerLine line) async {
  final key = line.cardKey!;
  final store = context.store;
  final current = CardData(store.money).setting(key.card)?.actualCharge(key.month);
  var amount = -line.amount;
  await showEditor(
    context,
    title: line.title,
    builder: (ctx, setState) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AmountRow(current == null ? 'לפי האפליקציה' : 'רשמת שירד', -line.amount),
      gap,
      NumberField(label: 'ירד בפועל', value: amount, suffix: '₪', onChanged: (v) => amount = v),
      gap,
      Text('הבנק עדכן את הסכום ברגע האחרון? רשום כמה ירד, ודף העו״ש והיתרה יתעדכנו. כשהקובץ של החודש ייובא, הסכום '
          'שרשמת עדיין קובע — אפשר למחוק אותו כאן.',
          style: Theme.of(ctx).textTheme.bodySmall),
      if (current != null)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () {
              store.edit((f) => f.money.setActualCharge(key.card, key.month, null));
              Navigator.pop(ctx, false);
            },
            child: const Text('חזור לסכום של האפליקציה'),
          ),
        ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton(
          onPressed: () {
            Navigator.pop(ctx, false);
            openDest(context, Dest.card);
          },
          child: const Text('פתח את מסך ״אשראי״'),
        ),
      ),
    ]),
    onSave: () => store.edit((f) => f.money.setActualCharge(key.card, key.month, amount > 0 ? amount : null)),
  );
}

/// Without a checking account: the recorded transactions only.
class _Planned extends StatelessWidget {
  const _Planned();

  @override
  Widget build(BuildContext context) {
    final money = context.store.money;
    final planned = money.transactions.where((t) => t.isPlanned).toList()..sort((a, b) => a.date.compareTo(b.date));
    if (planned.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return SectionCard(title: 'מתוכנן — קניות ותנועות עתידיות (לחיצה לעריכה)', children: [
      for (final t in planned)
        ListTile(
          leading: const Icon(Icons.event_note),
          title: Text(t.title.isEmpty ? t.kind.title : t.title),
          subtitle: Text([
            Fmt.date(t.date),
            if (t.paidByCard) 'באשראי${t.cardInstallments > 1 ? ' · ${t.cardInstallments} תשלומים' : ''}',
          ].join(' · ')),
          trailing: Text(Fmt.money(t.amount),
              textDirection: TextDirection.rtl,
              style: TextStyle(
                  fontFeatures: tabular,
                  color: t.kind == TransactionKind.income ? Colors.green.shade700 : theme.colorScheme.onSurface)),
          onTap: () => editTransaction(context, t),
        ),
    ]);
  }
}

class _LegacyTransactions extends StatelessWidget {
  const _LegacyTransactions();

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(
      builder: (context, store) {
        final money = store.money;
        final list = money.transactions..sort((a, b) => b.date.compareTo(a.date));
        final planned = list.where((t) => t.isPlanned).toList().reversed.toList();
        final past = list.where((t) => !t.isPlanned).toList();
        final cards = CardData(money);
        final open = openReceivables(money);
        Widget tile(MoneyTransaction t) {
          final theme = Theme.of(context);
          final color = switch (t.kind) {
            TransactionKind.income => Colors.green.shade700,
            TransactionKind.expense => theme.colorScheme.error,
            TransactionKind.transfer => theme.colorScheme.primary,
          };
          final where = t.kind == TransactionKind.transfer
              ? '${money.account(t.accountID)?.name ?? '?'} ← ${money.account(t.toAccountID)?.name ?? '?'}'
              : (t.paidByCard
                    ? 'באשראי${t.cardInstallments > 1 ? ' · ${t.cardInstallments} תשלומים' : ''}'
                    : money.account(t.accountID)?.name ?? '');
          final debt = t.kind == TransactionKind.income
              ? cards.receivables.where((r) => r.incomeIDs.contains(t.id)).firstOrNull
              : null;
          final costTitle = ReceivableActions.sharedCostTitle(store.dashboard, t.id);
          final shared = ReceivableActions(store.dashboard).sharedCosts;
          final canLink = t.kind == TransactionKind.income &&
              t.salaryKey == null &&
              debt == null &&
              costTitle == null &&
              (open.isNotEmpty || shared.isNotEmpty);
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.12),
              child: Icon(switch (t.kind) {
                TransactionKind.income => Icons.south_west,
                TransactionKind.expense => Icons.north_east,
                TransactionKind.transfer => Icons.swap_horiz,
              }, color: color),
            ),
            title: Text(t.title.isEmpty ? t.kind.title : t.title),
            subtitle: Text(
              '${Fmt.date(t.date)}${where.isEmpty ? '' : ' · $where'}${debt == null ? '' : ' · ↩︎ החזר חוב של ${debt.person}'}'
              '${costTitle == null ? '' : ' · 👥 השתתפות ב$costTitle'}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (canLink)
                  PopupMenuButton<String>(
                    tooltip: 'החזר חוב או השתתפות בחיוב משותף',
                    icon: const Icon(Icons.assignment_return_outlined, size: 20),
                    onSelected: (id) => store.edit((f) => id.startsWith('cost:')
                        ? ReceivableActions(f).linkIncomeToSharedCost(t.id, id.substring(5))
                        : ReceivableActions(f).linkIncome(t.id, id)),
                    itemBuilder: (_) => [
                      if (open.isNotEmpty) ...[
                        const PopupMenuItem(enabled: false, height: 32, child: Text('זה תשלום על חוב של…')),
                        for (final r in open)
                          PopupMenuItem(
                            value: r.id,
                            child: Text('${r.person} — נשאר ${Fmt.money(cards.outstanding(r, money.transactions))}'),
                          ),
                      ],
                      if (shared.isNotEmpty) ...[
                        const PopupMenuItem(enabled: false, height: 32, child: Text('השתתפות בחיוב משותף')),
                        for (final c in shared) PopupMenuItem(value: 'cost:${c.id}', child: Text('${c.name} — ${c.sharedWith}')),
                      ],
                    ],
                  ),
                Text(
                  (t.kind == TransactionKind.expense ? '−' : '') + Fmt.money(t.amount),
                  textDirection: TextDirection.rtl,
                  style: theme.textTheme.titleMedium?.copyWith(color: color),
                ),
              ],
            ),
            onTap: () => editTransaction(context, t),
          );
        }

        return PageList(
          children: [
            const _QuickEntry(),
            if (list.isEmpty)
              const SectionCard(
                title: 'תנועות',
                children: [
                  EmptyHint('כאן רושמים הכנסות והוצאות גדולות או חריגות, והעברות בין חשבונות. תאריך עתידי = מתוכנן.'),
                ],
              ),
            if (planned.isNotEmpty) SectionCard(title: 'מתוכננות', children: [for (final t in planned) tile(t)]),
            if (past.isNotEmpty) SectionCard(title: 'שבוצעו', children: [for (final t in past) tile(t)]),
          ],
        );
      },
    );
  }
}

/// [kind]: for a new transaction, what it starts as (a transfer goes to the first account that isn't the checking).
Future<void> editTransaction(BuildContext context, MoneyTransaction? existing, {TransactionKind kind = TransactionKind.expense}) async {
  final store = context.store;
  if (existing == null && store.money.checking == null) store.edit((f) => f.money.ensureChecking());
  final accounts = store.money.accounts;
  final draft = MoneyTransaction(existing != null
      ? deepCopy(existing.json) as Json
      : MoneyTransaction.create(kind: kind, accountID: store.money.checking?.id));
  if (existing == null && kind == TransactionKind.transfer) {
    draft.toAccountID = accounts.where((a) => a.kind != AccountKind.checking).firstOrNull?.id;
  }
  // What this income pays back: "none", a debt's id, or "cost:<expense id>".
  final cards = CardData(store.money);
  final debts = openReceivables(store.money, including: draft.id);
  final shared = ReceivableActions(store.dashboard).sharedCosts;
  var debtChoice = 'none';
  final linkedDebt = debts.where((r) => r.incomeIDs.contains(draft.id)).firstOrNull;
  if (linkedDebt != null) debtChoice = linkedDebt.id;
  final linkedCost = store.money.sharedCost(draft.id);
  if (linkedCost != null && shared.any((c) => c.id == linkedCost)) debtChoice = 'cost:$linkedCost';
  await showEditor(
    context,
    title: existing == null ? 'תנועה חדשה' : 'עריכת תנועה',
    builder: (ctx, setState) {
      final isTransfer = draft.kind == TransactionKind.transfer;
      final isCard = draft.kind == TransactionKind.expense && draft.paidByCard;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SegmentedButton<TransactionKind>(
          segments: [for (final k in TransactionKind.values) ButtonSegment(value: k, label: Text(k.title))],
          selected: {draft.kind},
          onSelectionChanged: (s) => setState(() {
            draft.kind = s.first;
            if (s.first != TransactionKind.transfer) draft.toAccountID = null;
          }),
        ),
        gap,
        TextInput(label: 'תיאור', initial: draft.title, autofocus: existing == null, onChanged: (v) => draft.title = v),
        gap,
        NumberField(label: 'סכום', suffix: '₪', value: draft.amount, onChanged: (v) => draft.amount = v),
        gap,
        DateField(label: 'תאריך (עתידי = מתוכנן)', value: draft.date, onChanged: (v) => setState(() => draft.date = v!)),
        if (draft.kind == TransactionKind.expense)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('שולם בכרטיס אשראי'),
            subtitle: const Text('יורד מהבנק רק בחיוב הכרטיס'),
            value: draft.paidByCard,
            onChanged: (v) => setState(() => draft.paidByCard = v),
          ),
        if (isCard)
          NumberField(
            label: 'מספר תשלומים',
            value: draft.cardInstallments.toDouble(),
            onChanged: (v) => draft.cardInstallments = v.round().clamp(1, 36),
          )
        else ...[
          gap,
          DropdownButtonFormField<String?>(
            initialValue: accounts.any((a) => a.id == draft.accountID) ? draft.accountID : null,
            decoration: InputDecoration(labelText: isTransfer ? 'מחשבון' : 'חשבון', border: const OutlineInputBorder()),
            items: [
              const DropdownMenuItem(value: null, child: Text('ללא')),
              for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.name)),
            ],
            onChanged: (v) => draft.accountID = v,
          ),
        ],
        if (isTransfer) ...[
          gap,
          DropdownButtonFormField<String?>(
            initialValue: accounts.any((a) => a.id == draft.toAccountID) ? draft.toAccountID : null,
            decoration: const InputDecoration(labelText: 'לחשבון', border: OutlineInputBorder()),
            items: [
              const DropdownMenuItem(value: null, child: Text('ללא')),
              for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.name)),
            ],
            onChanged: (v) => draft.toAccountID = v,
          ),
        ],
        gap,
        TextInput(label: 'הערה', initial: draft.note, onChanged: (v) => draft.note = v),
        // "החזר חוב": an income that pays back a debt or is participation in a shared fixed expense — not income.
        if (draft.kind == TransactionKind.income && draft.salaryKey == null && (debts.isNotEmpty || shared.isNotEmpty)) ...[
          gap,
          DropdownButtonFormField<String>(
            initialValue: debtChoice,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'החזר חוב',
              border: const OutlineInputBorder(),
              helperMaxLines: 3,
              helperText: debtChoice == 'none'
                  ? 'אם זה מישהו שמחזיר לך כסף ששילמת בשבילו — שייך לחוב או לחיוב משותף, וזה לא ייספר כהכנסה (גם לא במעשרות).'
                  : debtChoice.startsWith('cost:')
                      ? 'נרשם כהשתתפות בחיוב המשותף — יורד מההוצאה הקבועה, ולא נספר כהכנסה בסיכום ובמעשרות.'
                      : 'נרשם כתשלום על החוב ב״חייבים לי״ — לא נספר כהכנסה בסיכום ובמעשרות.',
            ),
            items: [
              const DropdownMenuItem(value: 'none', child: Text('לא — הכנסה רגילה')),
              for (final r in debts)
                DropdownMenuItem(
                    value: r.id,
                    child: Text('${r.person.isEmpty ? 'חבר' : r.person} — נשאר ${Fmt.money(cards.outstanding(r, store.money.transactions))}')),
              for (final c in shared)
                DropdownMenuItem(value: 'cost:${c.id}', child: Text('השתתפות ב${c.name} — ${c.sharedWith}')),
            ],
            onChanged: (v) => setState(() => debtChoice = v ?? 'none'),
          ),
        ],
      ]);
    },
    onSave: () => store.edit((f) {
      if (draft.title.trim().isEmpty) draft.title = draft.kind.title;
      f.money.upsertTransaction(draft.json);
      // The debt / shared-expense link (save in TransactionEditor.swift).
      final actions = ReceivableActions(f);
      final currentDebt = CardData(f.money).receivables.where((r) => r.incomeIDs.contains(draft.id)).firstOrNull?.id;
      final currentCost = f.money.sharedCost(draft.id);
      final isIncome = draft.kind == TransactionKind.income && draft.salaryKey == null;
      if (!isIncome || debtChoice == 'none') {
        if (currentDebt != null) actions.linkIncome(draft.id, null);
        if (currentCost != null) actions.linkIncomeToSharedCost(draft.id, null);
      } else if (debtChoice.startsWith('cost:')) {
        final id = debtChoice.substring(5);
        if (id != currentCost) actions.linkIncomeToSharedCost(draft.id, id);
      } else if (debtChoice != currentDebt) {
        actions.linkIncome(draft.id, debtChoice);
      }
    }),
    onDelete: existing == null ? null : () => store.edit((f) => f.money.removeTransaction(existing.id)),
  );
}
