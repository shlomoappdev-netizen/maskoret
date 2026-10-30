import 'package:flutter/material.dart';

import '../data/fmt.dart';
import '../data/json.dart';
import '../data/models.dart';
import '../data/money_calc.dart';
import 'common.dart';

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
            AmountRow('עו״ש', calc.total(money, {AccountKind.checking})),
            AmountRow('חסכונות ופיקדונות', calc.total(money, {AccountKind.savings, AccountKind.deposit})),
            AmountRow('פנסיה', calc.total(money, {AccountKind.pension})),
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
                      trailing: Text(Fmt.money(calc.value(a, now, tx)), textDirection: TextDirection.rtl,
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
      final related = money.transactions.where((t) => t.accountID == a.id || t.toAccountID == a.id).toList()
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
            AmountRow(a.kind.title, calc.value(a, now, money.transactions), bold: true),
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
    return StoreBuilder(builder: (context, store) {
      final money = store.money;
      final list = money.transactions..sort((a, b) => b.date.compareTo(a.date));
      final planned = list.where((t) => t.isPlanned).toList().reversed.toList();
      final past = list.where((t) => !t.isPlanned).toList();
      Widget tile(MoneyTransaction t) {
        final theme = Theme.of(context);
        final color = switch (t.kind) {
          TransactionKind.income => Colors.green.shade700,
          TransactionKind.expense => theme.colorScheme.error,
          TransactionKind.transfer => theme.colorScheme.primary,
        };
        final where = t.kind == TransactionKind.transfer
            ? '${money.account(t.accountID)?.name ?? '?'} ← ${money.account(t.toAccountID)?.name ?? '?'}'
            : (t.paidByCard ? 'באשראי${t.cardInstallments > 1 ? ' · ${t.cardInstallments} תשלומים' : ''}' : money.account(t.accountID)?.name ?? '');
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.12),
            child: Icon(
                switch (t.kind) {
                  TransactionKind.income => Icons.south_west,
                  TransactionKind.expense => Icons.north_east,
                  TransactionKind.transfer => Icons.swap_horiz,
                },
                color: color),
          ),
          title: Text(t.title.isEmpty ? t.kind.title : t.title),
          subtitle: Text('${Fmt.date(t.date)}${where.isEmpty ? '' : ' · $where'}'),
          trailing: Text((t.kind == TransactionKind.expense ? '−' : '') + Fmt.money(t.amount),
              textDirection: TextDirection.rtl, style: theme.textTheme.titleMedium?.copyWith(color: color)),
          onTap: () => editTransaction(context, t),
        );
      }

      return Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          heroTag: 'add-tx',
          icon: const Icon(Icons.add),
          label: const Text('תנועה'),
          onPressed: () => editTransaction(context, null),
        ),
        body: PageList(children: [
          if (list.isEmpty)
            const SectionCard(title: 'תנועות', children: [
              EmptyHint('כאן רושמים הכנסות והוצאות גדולות או חריגות, והעברות בין חשבונות. תאריך עתידי = מתוכנן.'),
            ]),
          if (planned.isNotEmpty) SectionCard(title: 'מתוכננות', children: [for (final t in planned) tile(t)]),
          if (past.isNotEmpty) SectionCard(title: 'שבוצעו', children: [for (final t in past) tile(t)]),
        ]),
      );
    });
  }
}

Future<void> editTransaction(BuildContext context, MoneyTransaction? existing) async {
  final store = context.store;
  if (existing == null && store.money.checking == null) store.edit((f) => f.money.ensureChecking());
  final accounts = store.money.accounts;
  final draft = MoneyTransaction(existing != null
      ? deepCopy(existing.json) as Json
      : MoneyTransaction.create(accountID: store.money.checking?.id));
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
      ]);
    },
    onSave: () => store.edit((f) {
      if (draft.title.trim().isEmpty) draft.title = draft.kind.title;
      f.money.upsertTransaction(draft.json);
    }),
    onDelete: existing == null ? null : () => store.edit((f) => f.money.removeTransaction(existing.id)),
  );
}
