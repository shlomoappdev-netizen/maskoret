import 'package:flutter/material.dart';

import 'budget_screens.dart';
import 'common.dart';
import 'households_screen.dart';
import 'money_screens.dart';
import 'summary_screen.dart';
import 'support_screen.dart';
import 'updates_screen.dart';

class _Dest {
  const _Dest(this.label, this.icon, this.selectedIcon, this.page);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget page;
}

const _dests = [
  _Dest('סיכום', Icons.dashboard_outlined, Icons.dashboard, SummaryScreen()),
  _Dest('הכנסות', Icons.payments_outlined, Icons.payments, IncomesScreen()),
  _Dest('ניכויים', Icons.receipt_long_outlined, Icons.receipt_long, DeductionsScreen()),
  _Dest('הוצאות', Icons.shopping_bag_outlined, Icons.shopping_bag, ExpensesScreen()),
  _Dest('תנועות', Icons.swap_vert, Icons.swap_vert_circle, TransactionsScreen()),
  _Dest('חשבונות', Icons.account_balance_outlined, Icons.account_balance, AccountsScreen()),
];

/// Navigation: a bottom bar on phones (5 items + "more"), a side rail on desktop.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int index = 0;
  bool _askedLocalChoice = false;

  @override
  Widget build(BuildContext context) {
    final scope = context.scope;
    final wide = isWide(context);
    return ListenableBuilder(
      listenable: Listenable.merge([scope.store, scope.account, scope.sync, scope.updater]),
      builder: (context, _) {
        _maybeAskLocalChoice(context);
        final page = Column(children: [
          if (scope.updater.available) const UpdateBanner(),
          Expanded(child: _dests[index].page),
        ]);
        final appBar = AppBar(
          title: _Title(),
          actions: [
            _MemberPicker(),
            _SyncIcon(),
            const SupportIconButton(),
            IconButton(
              tooltip: 'משקי בית וחשבון',
              icon: const Icon(Icons.home_work_outlined),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HouseholdsScreen())),
            ),
          ],
        );
        if (wide) {
          return Scaffold(
            appBar: appBar,
            body: Row(children: [
              NavigationRail(
                extended: MediaQuery.sizeOf(context).width >= 1100,
                labelType: MediaQuery.sizeOf(context).width >= 1100 ? NavigationRailLabelType.none : NavigationRailLabelType.all,
                selectedIndex: index,
                onDestinationSelected: (i) => setState(() => index = i),
                destinations: [
                  for (final d in _dests)
                    NavigationRailDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selectedIcon), label: Text(d.label)),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: page),
            ]),
          );
        }
        return Scaffold(
          appBar: appBar,
          body: page,
          bottomNavigationBar: NavigationBar(
            selectedIndex: index,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            onDestinationSelected: (i) => setState(() => index = i),
            destinations: [
              for (final d in _dests)
                NavigationDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selectedIcon), label: d.label),
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
