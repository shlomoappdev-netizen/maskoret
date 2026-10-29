import 'package:flutter/material.dart';

import '../data/card.dart';
import '../data/max_import.dart';
import 'budget_screens.dart';
import 'card_screen.dart';
import 'forecast_screen.dart';
import 'common.dart';
import 'households_screen.dart';
import 'money_screens.dart';
import 'summary_screen.dart';
import 'support_screen.dart';
import 'updates_screen.dart';
import '../data/fmt.dart';
import '../data/models.dart';
import '../data/money_calc.dart';
import '../data/month_picture.dart';
import '../update/updater.dart';

/// Every screen of the app, grouped like the Mac sidebar (SidebarItem in MaskoretApp.swift).
enum Dest {
  summary('סיכום', Icons.pie_chart_outline),
  incomes('הכנסות', Icons.payments_outlined),
  deductions('ניכויים', Icons.account_balance_outlined),
  expenses('הוצאות קבועות', Icons.shopping_cart_outlined),
  accounts('חשבונות וחיסכון', Icons.savings_outlined),
  card('כרטיס אשראי', Icons.credit_card),
  transactions('תנועות', Icons.swap_horiz),
  forecast('תחזית', Icons.show_chart),
  account('חשבון ומשק בית', Icons.account_circle_outlined, ownScaffold: true),
  support('תמיכה ודיווח תקלות', Icons.support_agent, ownScaffold: true),
  versions('גרסאות קודמות', Icons.history, ownScaffold: true),
  updates('עדכונים', Icons.system_update_alt, ownScaffold: true);

  const Dest(this.title, this.icon, {this.ownScaffold = false});
  final String title;
  final IconData icon;

  /// Screens with their own app bar (the others get the household's).
  final bool ownScaffold;

  /// A shorter name for the phone's bottom tabs.
  String get tabTitle => switch (this) { accounts => 'חשבונות', card => 'אשראי', _ => title };

  Widget get page => switch (this) {
        summary => const SummaryScreen(),
        incomes => const IncomesScreen(),
        deductions => const DeductionsScreen(),
        expenses => const ExpensesScreen(),
        accounts => const AccountsScreen(),
        card => const CardScreen(),
        transactions => const TransactionsScreen(),
        forecast => const ForecastScreen(),
        account => const HouseholdsScreen(),
        support => const SupportScreen(),
        versions => const VersionsScreen(),
        updates => const UpdatesScreen(),
      };

  /// The sidebar sections (החודש / הכסף שלי / מעקב / הגדרות).
  static List<(String, List<Dest>)> sections() => [
        ('החודש', [summary, incomes, deductions, expenses]),
        ('הכסף שלי', [accounts, card, transactions, forecast]),
        ('הגדרות', [account, support, versions, if (Updater.supported) updates]),
      ];

  /// The phone's bottom tabs; everything else is under "עוד" (like PhoneRoot.swift).
  static const tabs = [summary, transactions, card, accounts];
}

/// Navigation: on wide screens (Windows) a sidebar with sections and the month's numbers at the bottom;
/// on phones bottom tabs + "עוד".
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  Dest current = Dest.summary;

  /// Phone: the "עוד" tab is selected.
  bool more = false;
  bool _askedLocalChoice = false;

  @override
  Widget build(BuildContext context) {
    final scope = context.scope;
    final wide = isWide(context);
    return ListenableBuilder(
      listenable: Listenable.merge([scope.store, scope.account, scope.sync, scope.updater, scope.support]),
      builder: (context, _) {
        _maybeAskLocalChoice(context);
        final appBar = AppBar(
          title: _Title(),
          actions: [
            _MemberPicker(),
            _SyncIcon(),
            const SupportIconButton(),
          ],
        );
        Widget content(Dest d) => d.page;
        if (wide) {
          return Scaffold(
            appBar: appBar,
            body: Row(children: [
              SizedBox(
                width: 250,
                child: Sidebar(selected: current, onSelect: (d) => setState(() => current = d)),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(children: [
                  if (scope.updater.available) const UpdateBanner(),
                  Expanded(child: content(current)),
                ]),
              ),
            ]),
          );
        }
        final tabIndex = more ? Dest.tabs.length : Dest.tabs.indexOf(current).clamp(0, Dest.tabs.length - 1);
        return Scaffold(
          appBar: appBar,
          body: Column(children: [
            if (scope.updater.available) const UpdateBanner(),
            Expanded(child: more ? const MoreScreen() : content(Dest.tabs[tabIndex])),
          ]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tabIndex,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            onDestinationSelected: (i) => setState(() {
              more = i == Dest.tabs.length;
              if (!more) current = Dest.tabs[i];
            }),
            destinations: [
              for (final d in Dest.tabs)
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: d == Dest.card && CardData(scope.store.money).importDue(),
                    label: const Text('!'),
                    child: Icon(d.icon),
                  ),
                  label: d.tabTitle,
                ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: scope.sync.lastError != null || scope.support.unread > 0,
                  label: Text(scope.sync.lastError != null ? '!' : '${scope.support.unread}'),
                  child: const Icon(Icons.more_horiz),
                ),
                label: 'עוד',
              ),
            ],
          ),
        );
      },
    );
  }

  /// First sign-in with data already on this device: upload it, or use the household from the server?
  void _maybeAskLocalChoice(BuildContext context) {
    final sync = context.scope.sync;
    if (!sync.pendingLocalChoice || _askedLocalChoice) return;
    _askedLocalChoice = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final upload = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('יש נתונים במכשיר הזה'),
          content: const Text('לחשבון שלך כבר יש משק בית בשרת. מה לעשות עם הנתונים שבמכשיר?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('להעלות כמשק בית חדש')),
            FilledButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('להשתמש בנתונים מהשרת')),
          ],
        ),
      );
      await sync.resolveLocalChoice(uploadAsNew: upload ?? false);
      _askedLocalChoice = false;
    });
  }
}

class _Title extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scope = context.scope;
    final h = scope.account.activeHousehold;
    final member = scope.store.activeMember;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(h?.name ?? 'מחשבון שכר', overflow: TextOverflow.ellipsis),
      if (scope.store.members.length > 1 && member != null)
        Text(member.title, style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}

/// Which family member's payslip is being edited (only when the household has several).
class _MemberPicker extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final store = context.store;
    if (store.members.length < 2) return const SizedBox.shrink();
    return PopupMenuButton<String>(
      tooltip: 'בן משפחה',
      icon: const Icon(Icons.people_outline),
      onSelected: (id) => store.activeMemberId = id,
      itemBuilder: (_) => [
        for (final m in store.members)
          CheckedPopupMenuItem(value: m.id, checked: m.id == store.activeMemberId, child: Text(m.title)),
      ],
    );
  }
}

class _SyncIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scope = context.scope;
    final sync = scope.sync;
    if (!scope.account.isSignedIn) {
      return IconButton(
        tooltip: 'לא מחובר — הנתונים רק במכשיר הזה',
        icon: const Icon(Icons.cloud_off_outlined),
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HouseholdsScreen())),
      );
    }
    final theme = Theme.of(context);
    final Widget icon;
    if (sync.isSyncing) {
      icon = const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
    } else if (sync.lastError != null) {
      icon = Icon(Icons.sync_problem, color: theme.colorScheme.error);
    } else if (sync.hasUnsyncedChanges) {
      icon = const Icon(Icons.cloud_upload_outlined);
    } else {
      icon = const Icon(Icons.cloud_done_outlined);
    }
    return IconButton(
      tooltip: sync.lastError ?? (sync.status.isEmpty ? 'מסונכרן' : sync.status),
      icon: icon,
      onPressed: () {
        sync.sync();
        showMessage(context, sync.lastError ?? (sync.status.isEmpty ? 'מסנכרן…' : sync.status));
      },
    );
  }
}

/// "עו״ש עכשיו" and "נשאר בסוף החודש" — the numbers at the bottom of the Mac sidebar.
class MonthNumbers extends StatelessWidget {
  const MonthNumbers({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final theme = Theme.of(context);
    final money = store.money;
    final checking = MoneyCalc(money.primeRate).total(money, {AccountKind.checking});
    final now = DateTime.now();
    final remaining = MonthPicture.of(store.file, now.year, now.month).remaining;
    Widget number(String label, double value, {Color? color}) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            Text(Fmt.money(value),
                textDirection: TextDirection.rtl,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: color)),
          ],
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Row(children: [
        Expanded(child: number('עו״ש עכשיו', checking)),
        Expanded(
          child: number('נשאר בסוף החודש', remaining,
              color: remaining >= 0 ? Colors.green.shade700 : theme.colorScheme.error),
        ),
      ]),
    );
  }
}

Widget? _badgeFor(BuildContext context, Dest d) {
  final scope = context.scope;
  if (d == Dest.support && scope.support.unread > 0) return Badge(label: Text('${scope.support.unread}'));
  if (d == Dest.account && scope.sync.lastError != null) return const Badge(label: Text('!'));
  if (d == Dest.updates && scope.updater.available) return const Badge(label: Text('חדש'));
  if (d == Dest.card && CardData(scope.store.money).importDue()) return const Badge(label: Text('ייבוא'));
  return null;
}

/// The wide-screen sidebar: sections, and the month's numbers at the bottom.
class Sidebar extends StatelessWidget {
  const Sidebar({super.key, required this.selected, required this.onSelect});
  final Dest selected;
  final ValueChanged<Dest> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
          for (final (title, items) in Dest.sections()) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(title, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
            ),
            for (final d in items)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: ListTile(
                  dense: true,
                  selected: d == selected,
                  selectedTileColor: theme.colorScheme.secondaryContainer,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  leading: Icon(d.icon, size: 20),
                  title: Text(d.title),
                  trailing: _badgeFor(context, d),
                  onTap: () => onSelect(d),
                ),
              ),
          ],
        ]),
      ),
      const Divider(height: 1),
      const MonthNumbers(),
    ]);
  }
}

/// Phone: every screen that isn't a bottom tab, grouped like the Mac sidebar (MoreView in PhoneRoot.swift).
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      const MonthNumbers(),
      const Divider(height: 1),
      for (final (title, items) in Dest.sections())
        if (items.any((d) => !Dest.tabs.contains(d)))
          SectionCard(title: title, children: [
            for (final d in items.where((d) => !Dest.tabs.contains(d)))
              ListTile(
                leading: Icon(d.icon),
                title: Text(d.title),
                trailing: _badgeFor(context, d) ?? const Icon(Icons.chevron_left),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => d.ownScaffold ? d.page : Scaffold(appBar: AppBar(title: Text(d.title)), body: d.page),
                  ),
                ),
              ),
          ]),
    ].map((w) => w is SectionCard ? Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: w) : w).toList());
  }
}
