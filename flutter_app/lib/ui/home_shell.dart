import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/card.dart';
import '../data/max_import.dart';
import 'admin_screen.dart';
import 'budget_screens.dart';
import 'card_screen.dart';
import 'family_screen.dart';
import 'forecast_screen.dart';
import 'history_screen.dart';
import 'maaser_screen.dart';
import 'receivables_screen.dart';
import 'common.dart';
import 'households_screen.dart';
import 'insights_screen.dart';
import 'money_screens.dart';
import 'summary_screen.dart';
import 'support_screen.dart';
import 'tax_settings_screen.dart';
import 'theme.dart';
import 'tracked_screen.dart';
import 'trends_screen.dart';
import 'updates_screen.dart';
import '../data/fmt.dart';
import '../data/models.dart';
import '../data/money_calc.dart';
import '../data/month_picture.dart';
import '../state/store.dart';
import '../support/support.dart';
import '../update/updater.dart';

/// Every screen of the app, grouped like the Mac sidebar (SidebarItem in MaskoretApp.swift).
enum Dest {
  summary('בית', Icons.home_outlined),
  money('הכסף שלי', Icons.account_balance_wallet_outlined),
  budget('תקציב', Icons.list_alt),
  incomes('הכנסות', Icons.payments_outlined),
  deductions('ניכויים', Icons.account_balance_outlined),
  expenses('הוצאות קבועות', Icons.shopping_cart_outlined),
  accounts('חיסכון', Icons.savings_outlined),
  card('אשראי', Icons.credit_card),
  transactions('עו״ש', Icons.swap_horiz),
  forecast('תחזית', Icons.show_chart),
  history('חודשים', Icons.calendar_month),
  maaser('מעשרות', Icons.volunteer_activism_outlined),
  owed('חייבים לי', Icons.assignment_return_outlined),
  tracked('מעקב רכישות', Icons.shopping_bag_outlined),
  trends('מגמות', Icons.sell_outlined),
  insights('תובנות AI', Icons.auto_awesome_outlined),
  family('בני משפחה', Icons.groups_outlined),
  tax('נתוני מס', Icons.percent),
  account('חשבון ומשק בית', Icons.account_circle_outlined, ownScaffold: true),
  support('תמיכה ודיווח תקלות', Icons.support_agent, ownScaffold: true),
  versions('גרסאות קודמות', Icons.history, ownScaffold: true),
  adminAnnouncements('הודעות למשתמשים', Icons.campaign_outlined, ownScaffold: true),
  updates('עדכונים', Icons.system_update_alt, ownScaffold: true);

  const Dest(this.title, this.icon, {this.ownScaffold = false});
  final String title;
  final IconData icon;

  /// Screens with their own app bar (the others get the household's).
  final bool ownScaffold;

  /// The screens grouped under "הכסף שלי" and "תקציב", as tabs inside them (moneyTabs / budgetTabs in MaskoretApp.swift).
  static const moneyTabs = [transactions, card, accounts];
  static const budgetTabs = [incomes, deductions, expenses, tracked];

  /// The menu item that shows this screen.
  Dest get home => moneyTabs.contains(this) ? money : (budgetTabs.contains(this) ? budget : this);

  /// One name for every screen, in the menu, the tabs and the titles (4.15.0).
  String get tabTitle => title;

  /// One line at the top of the screen: what's here and what you do with it (SidebarItem.intro in MaskoretApp.swift).
  /// Null where the title says it all.
  String? get intro => switch (this) {
        summary => 'התמונה של החודש: כמה נכנס, כמה כבר יצא, כמה צפוי להישאר ומה מחכה לטיפול.',
        transactions => 'כמו דף הבנק: כל מה שנכנס ויוצא מהעו״ש, עם היתרה אחרי כל שורה. משכורת, הוצאות קבועות וחיובי אשראי נכנסים לבד.',
        card => 'העסקאות בכרטיסי האשראי. כאן מייבאים את קובץ הפירוט מ-Max או מ-CAL ומשייכים עסקאות למגמות.',
        accounts => 'כמה כסף יש לך עכשיו ואיפה: עו״ש, חסכונות, פיקדונות והשקעות.',
        incomes => 'המשכורת וההכנסות הנוספות. מכאן מחושב הנטו הצפוי בכל חודש.',
        deductions => 'מה שיורד מהמשכורת לפני שהיא מגיעה לבנק, מעבר למס ולביטוח הלאומי.',
        expenses => 'הוצאות שחוזרות כל חודש, כמו שכירות, חשמל ומנויים. הן יורדות מהעו״ש לבד בתאריך שלהן.',
        tracked => 'רכישות שחוזרות מדי פעם ולא כל חודש, כדי לדעת כמה הן עולות בממוצע.',
        forecast => 'לאן הכסף שלך הולך בחודשים הקרובים, לפי ההכנסות וההוצאות.',
        history => 'כל חודש שנשמר: הנטו שנכנס בפועל מול ההערכה. מכאן מתקנים או מוחקים חודש.',
        maaser => 'כמה צריך לתת לפי מה שנכנס, כמה כבר נתת וכמה נשאר.',
        owed => 'כסף שאחרים חייבים לך, ומה כבר הוחזר.',
        trends => 'תגיות לדברים שאין להם קטגוריה, כמו דייטים, מתנות ויציאות, כדי לראות כמה באמת הולך עליהם.',
        insights => 'שאלות ותובנות על הכסף שלך, בעזרת מודל AI.',
        _ => null,
      };

  /// Other words people use for what's on this screen, for the screen search (SidebarItem.keywords).
  List<String> get keywords => switch (this) {
        summary => const ['סיכום', 'ראשי', 'נשאר', 'עוגה', 'לאן הולך הנטו', 'שמור חודש', 'תלוש', 'תלוש שכר'],
        transactions => const ['תנועות', 'בנק', 'יתרה', 'דף חשבון', 'חשבון עובר ושב'],
        card => const ['כרטיס אשראי', 'מקס', 'Max', 'כאל', 'CAL', 'ייבוא', 'פירוט עסקאות', 'חיוב'],
        accounts => const ['חסכונות', 'חשבונות', 'פיקדון', 'השקעות', 'קופת גמל', 'קרן השתלמות'],
        incomes => const ['משכורת', 'שכר', 'ברוטו', 'נטו', 'הכנסה'],
        deductions => const ['ניכוי', 'פנסיה', 'קרן השתלמות', 'קופת חולים'],
        expenses => const ['קבועות', 'הוצאות', 'שכירות', 'חשמל', 'מנויים', 'הוראת קבע'],
        tracked => const ['רכישות', 'דלק', 'ביגוד', 'קניות'],
        forecast => const ['עתיד', 'חודשים הבאים', 'צפי'],
        history => const ['היסטוריה', 'חודשים קודמים', 'מחיקת חודש', 'תלוש'],
        maaser => const ['מעשר', 'צדקה', 'תרומות', 'חומש'],
        owed => const ['חובות', 'הלוואה', 'החזר', 'חייבים'],
        trends => const ['תגיות', 'קטגוריות', 'דייטים', 'מתנות'],
        insights => const ['AI', 'בינה מלאכותית', 'שאלות', 'Claude', 'LM Studio'],
        family => const ['משפחה', 'בן זוג', 'בת זוג', 'בני בית'],
        tax => const ['מס', 'מס הכנסה', 'נקודות זיכוי', 'ביטוח לאומי', 'מדרגות'],
        account => const ['חשבון', 'משק בית', 'שיתוף', 'התחברות', 'Google', 'סנכרון', 'יציאה', 'מחיקת חשבון'],
        support => const ['עזרה', 'תקלה', 'באג', 'פנייה', 'צור קשר'],
        adminAnnouncements => const ['מנויים', 'משתמשים', 'הודעות לכולם', 'ניהול'],
        versions => const ['גיבוי', 'שחזור', 'גרסה קודמת'],
        updates => const ['עדכון', 'גרסה', 'הורדה', 'מה חדש'],
        _ => const [],
      };

  /// The screens a search can open, in the order of the menu.
  static List<Dest> searchable({bool admin = false}) => [
        summary, ...moneyTabs, ...budgetTabs,
        forecast, history, maaser, owed, trends, insights, family, tax, account, support,
        if (admin) adminAnnouncements, versions, if (Updater.supported) updates,
      ];

  /// Where the screen sits, for the search results ("הכסף שלי ← עו״ש").
  String get path => home == this ? title : '${home.title} ← $title';

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [title, home.title, intro ?? '', ...keywords].any((f) => f.toLowerCase().contains(q));
  }

  /// The screen with its explanation line on top (hidden for good once closed).
  Widget get screen => intro == null
      ? page
      : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ScreenIntro(dest: this),
          Expanded(child: page),
        ]);

  Widget get page => switch (this) {
        summary => const SummaryScreen(),
        money => const GroupScreen(tabs: moneyTabs),
        budget => const GroupScreen(tabs: budgetTabs),
        incomes => const IncomesScreen(),
        deductions => const DeductionsScreen(),
        expenses => const ExpensesScreen(),
        accounts => const AccountsScreen(),
        card => const CardScreen(),
        transactions => const TransactionsScreen(),
        forecast => const ForecastScreen(),
        history => const HistoryScreen(),
        maaser => const MaaserScreen(),
        owed => const ReceivablesScreen(),
        tracked => const TrackedScreen(),
        trends => const TrendsScreen(),
        insights => const InsightsScreen(),
        family => const FamilyScreen(),
        tax => const TaxSettingsScreen(),
        account => const HouseholdsScreen(),
        support => const SupportScreen(),
        versions => const VersionsScreen(),
        adminAnnouncements => const AdminAnnouncementsScreen(),
        updates => const UpdatesScreen(),
      };

  /// The sidebar sections, like the Mac: בית, הכסף שלי, תקציב, then תכנון ותובנות and הגדרות.
  /// [admin]: "הודעות למשתמשים" shows only for an admin (rpc am_i_admin).
  static List<(String, List<Dest>)> sections({bool admin = false}) => [
        ('', [summary, money, budget]),
        ('תכנון ותובנות', [forecast, history, maaser, owed, trends, insights]),
        ('הגדרות', [
          family, tax, account, support, if (admin) adminAnnouncements, versions, if (Updater.supported) updates,
        ]),
      ];

  /// The phone's bottom tabs; everything else is under "עוד" (like PhoneRoot.swift).
  static const tabs = [summary, money, budget];
}

/// The open tab in each group, and a screen another screen asked to open (moneyTab / budgetTab / show /
/// openScreen in Store.swift).
class Nav extends ChangeNotifier {
  Dest moneyTab = Dest.transactions;
  Dest budgetTab = Dest.incomes;

  /// Asked for by another screen; the shell opens it (its group and tab) and clears it.
  Dest? opening;

  Dest tabOf(List<Dest> tabs) => identical(tabs, Dest.moneyTabs) ? moneyTab : budgetTab;

  /// Selects the tab a screen lives in (when it's inside a group).
  void show(Dest d) {
    if (Dest.moneyTabs.contains(d)) moneyTab = d;
    if (Dest.budgetTabs.contains(d)) budgetTab = d;
    notifyListeners();
  }

  void open(Dest d) {
    opening = d;
    show(d);
  }
}

final nav = Nav();

/// Which screens' explanation lines the user closed, on this device ("hiddenScreenIntros", like the Mac).
class ScreenIntros extends ChangeNotifier {
  static const key = 'hiddenScreenIntros';
  SharedPreferences? _prefs;

  void attach(SharedPreferences prefs) => _prefs ??= prefs;

  Set<String> get hidden => {...?_prefs?.getString(key)?.split(',').where((s) => s.isNotEmpty)};
  bool isHidden(Dest d) => hidden.contains(d.name);

  void hide(Dest d) {
    _prefs?.setString(key, {...hidden, d.name}.join(','));
    notifyListeners();
  }

  void showAll() {
    _prefs?.remove(key);
    notifyListeners();
  }
}

final screenIntros = ScreenIntros();

/// "What's on this screen" in one line, with an ✕ that hides it for good (ScreenIntro in Components.swift).
class ScreenIntro extends StatelessWidget {
  const ScreenIntro({super.key, required this.dest});
  final Dest dest;

  @override
  Widget build(BuildContext context) {
    screenIntros.attach(context.scope.prefs);
    return ListenableBuilder(
      listenable: screenIntros,
      builder: (context, _) {
        final intro = dest.intro;
        if (intro == null || screenIntros.isHidden(dest)) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1060),
              child: Container(
                padding: const EdgeInsetsDirectional.fromSTEB(10, 8, 4, 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(Icons.info_outline, size: 18, color: theme.colorScheme.primary),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(intro,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ),
                  IconButton(
                    tooltip: 'הסתר את ההסבר',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    icon: Icon(Icons.close, color: theme.colorScheme.onSurfaceVariant),
                    onPressed: () => screenIntros.hide(dest),
                  ),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The screens whose name, place, explanation or common words match the query (ScreenSearchResults).
class ScreenSearchResults extends StatelessWidget {
  const ScreenSearchResults({super.key, required this.query, required this.onOpen});
  final String query;
  final ValueChanged<Dest> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final results = Dest.searchable(admin: context.scope.support.isAdmin).where((d) => d.matches(query)).toList();
    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('לא נמצא מסך כזה. נסה מילה אחרת, למשל ״משכורת״, ״אשראי״ או ״מעשר״.',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (final d in results)
        ListTile(
          leading: Icon(d.icon, color: theme.colorScheme.primary),
          title: Text(d.path),
          subtitle: d.intro == null ? null : Text(d.intro!, maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: () => onOpen(d),
        ),
    ]);
  }
}

/// Ctrl+K on Windows (⌘K on the Mac): type what you're looking for and jump to its screen.
Future<void> showScreenSearch(BuildContext context) async {
  final picked = await showDialog<Dest>(
    context: context,
    builder: (ctx) {
      var query = '';
      return StatefulBuilder(
        builder: (ctx, setState) => Dialog(
          child: SizedBox(
            width: 520,
            height: 440,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'איזה מסך לפתוח? למשל ״משכורת״, ״אשראי״, ״מעשר״',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => query = v),
                  onSubmitted: (_) {
                    final first = Dest.searchable(admin: ctx.scope.support.isAdmin).where((d) => d.matches(query)).firstOrNull;
                    if (first != null) Navigator.pop(ctx, first);
                  },
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  child: ScreenSearchResults(query: query, onOpen: (d) => Navigator.pop(ctx, d)),
                ),
              ),
            ]),
          ),
        ),
      );
    },
  );
  if (picked != null && context.mounted) openDest(context, picked);
}

/// A few related screens behind one menu item, with tabs on top (GroupScreen in MaskoretApp.swift).
class GroupScreen extends StatelessWidget {
  const GroupScreen({super.key, required this.tabs});
  final List<Dest> tabs;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: nav,
      builder: (context, _) {
        final selected = nav.tabOf(tabs);
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<Dest>(
                  showSelectedIcon: false,
                  segments: [
                    for (final d in tabs)
                      ButtonSegment(
                        value: d,
                        label: d == Dest.card && CardData(context.store.money).importDue()
                            ? Badge(label: const Text('!'), child: Text(d.tabTitle))
                            : FittedBox(fit: BoxFit.scaleDown, child: Text(d.tabTitle, maxLines: 1)),
                      ),
                  ],
                  selected: {selected},
                  onSelectionChanged: (v) => nav.show(v.first),
                ),
              ),
            ),
          ),
          Expanded(child: KeyedSubtree(key: ValueKey(selected), child: selected.screen)),
        ]);
      },
    );
  }
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
      listenable: Listenable.merge([scope.store, scope.account, scope.sync, scope.updater, scope.support, nav]),
      builder: (context, _) {
        _maybeAskLocalChoice(context);
        // Another screen asked to open one (a line in the checking statement, "מה מחכה לך"…): its group and tab.
        final opening = nav.opening;
        if (opening != null) {
          nav.opening = null;
          if (wide || Dest.tabs.contains(opening.home)) {
            current = opening.home;
            more = false;
          } else {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) Navigator.push(context, glassRoute((_) => _pageWithBar(opening)));
            });
          }
        }
        // Signed out, or not an admin any more: leave the admin screen.
        if (current == Dest.adminAnnouncements && !scope.support.isAdmin) current = Dest.summary;
        final appBar = AppBar(
          title: _Title(),
          actions: [
            _MemberPicker(),
            _SyncIcon(),
            const SupportIconButton(),
          ],
        );
        Widget content(Dest d) => d.screen;
        if (wide) {
          return CallbackShortcuts(
            bindings: {const SingleActivator(LogicalKeyboardKey.keyK, control: true): () => showScreenSearch(context)},
            child: Focus(
              autofocus: true,
              child: Scaffold(
            appBar: appBar,
            body: Row(children: [
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 0, 12),
                child: SizedBox(
                  width: 250,
                  child: Glass(
                    radius: 20,
                    child: Sidebar(selected: current, onSelect: (d) => setState(() => current = d)),
                  ),
                ),
              ),
              Expanded(
                child: Column(children: [
                  if (scope.updater.available) const UpdateBanner(),
                  Expanded(child: content(current)),
                ]),
              ),
            ]),
              ),
            ),
          );
        }
        final tabIndex = more ? Dest.tabs.length : Dest.tabs.indexOf(current).clamp(0, Dest.tabs.length - 1);
        return Scaffold(
          appBar: appBar,
          body: Column(children: [
            if (scope.updater.available) const UpdateBanner(),
            Expanded(child: more ? const MoreScreen() : content(Dest.tabs[tabIndex])),
          ]),
          extendBody: true,
          bottomNavigationBar: Glass(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            child: NavigationBar(
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
                    isLabelVisible: d == Dest.money && CardData(scope.store.money).importDue(),
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
      onSelected: (id) => id == '' 
          ? Navigator.push(context, glassRoute((_) => Scaffold(appBar: AppBar(title: const Text('בני משפחה')), body: const FamilyScreen())))
          : store.setEditing(id),
      itemBuilder: (_) => [
        for (final m in store.members)
          CheckedPopupMenuItem(value: m.id, checked: m.id == store.activeMemberId, child: Text(m.title)),
        const PopupMenuDivider(),
        const PopupMenuItem(value: '', child: Text('ניהול בני משפחה…')),
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
        onPressed: () => Navigator.push(context, glassRoute((_) => const HouseholdsScreen())),
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

/// "עו״ש עכשיו" and "נשאר מההכנסה האחרונה" — the numbers at the bottom of the Mac sidebar.
class MonthNumbers extends StatelessWidget {
  const MonthNumbers({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        // "כולל הערכת הוצאות באשראי" on the home screen changes these numbers too.
        listenable: MonthPicture.hideCardEstimate,
        builder: (context, _) => StoreBuilder(builder: _numbers),
      );

  Widget _numbers(BuildContext context, AppStore store) {
    final theme = Theme.of(context);
    final d = store.dashboard;
    final money = d.money;
    final checking = MoneyCalc(money.primeRate).total(money, {AccountKind.checking}, budget: d.budget, history: d.history);
    final pic = MonthPicture.current(d);
    Widget number(String label, double value, {Color? color}) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(Fmt.money(value),
                  textDirection: TextDirection.rtl,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: color, fontFeatures: tabular)),
            ),
          ],
        );
    Color tone(double v) => v >= 0 ? AppColors.positive(context) : AppColors.negative(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        number('עו״ש עכשיו', checking),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: number('נשאר בפועל', pic.remainingActual, color: tone(pic.remainingActual))),
          const SizedBox(width: 8),
          Expanded(child: number('צפוי להישאר', pic.remaining, color: tone(pic.remaining))),
        ]),
      ]),
    );
  }
}

Widget? _badgeFor(BuildContext context, Dest d) {
  final scope = context.scope;
  if (d == Dest.support && scope.support.unread > 0) return Badge(label: Text('${scope.support.unread}'));
  if (d == Dest.account && scope.sync.lastError != null) return const Badge(label: Text('!'));
  if (d == Dest.updates && scope.updater.available) return const Badge(label: Text('חדש'));
  if (d == Dest.money && CardData(scope.store.money).importDue()) return const Badge(label: Text('ייבוא'));
  return null;
}

/// "מחשבון שכר · גרסה 4.10.0 (46)" — the installed version, small and grey, at the bottom of the menu.
/// Diagnostics.init() runs before the app starts, so the number is already there.
class AppVersionLabel extends StatelessWidget {
  const AppVersionLabel({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text('מחשבון שכר · גרסה ${Diagnostics.appVersion}',
        textAlign: TextAlign.center,
        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant));
  }
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
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => showScreenSearch(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              Icon(Icons.search, size: 18, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(child: Text('חיפוש מסך', style: TextStyle(color: theme.colorScheme.onSurfaceVariant))),
              Text('Ctrl+K', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ]),
          ),
        ),
      ),
      Expanded(
        child: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
          for (final (title, items) in Dest.sections(admin: context.scope.support.isAdmin)) ...[
            if (title.isNotEmpty)
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
                  selectedColor: theme.colorScheme.primary,
                  selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  leading: Icon(d.icon, size: 20),
                  title: Text(d.title),
                  trailing: _badgeFor(context, d),
                  onTap: () => onSelect(d),
                ),
              ),
          ],
        ]),
      ),
      Divider(height: 1, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08)),
      const MonthNumbers(),
      const Padding(padding: EdgeInsets.only(bottom: 10), child: AppVersionLabel()),
    ]);
  }
}

Widget _pageWithBar(Dest d) => d.ownScaffold ? d.screen : Scaffold(appBar: AppBar(title: Text(d.title)), body: d.screen);

/// Opens one of the app's screens from another (a line in the checking statement, "מה מחכה לך"): back to the main
/// screen, then its group and tab in the menu (store.openScreen in Swift).
void openDest(BuildContext context, Dest d) {
  Navigator.of(context).popUntil((r) => r.isFirst);
  nav.open(d);
}

/// Phone: every screen that isn't a bottom tab, grouped like the Mac sidebar (MoreView in PhoneRoot.swift).
class MoreScreen extends StatefulWidget {
  const MoreScreen({super.key});

  @override
  State<MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends State<MoreScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final support = context.scope.support;
    return ListenableBuilder(listenable: support, builder: (context, _) => _list(context, support.isAdmin));
  }

  Widget _list(BuildContext context, bool admin) {
    final query = _search.text.trim();
    return ListView(padding: const EdgeInsets.only(bottom: 110), children: [
      // The screen search (the iPhone's search field in "עוד").
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: TextField(
          controller: _search,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search),
            hintText: 'חיפוש מסך — משכורת, אשראי, מעשר…',
            border: const OutlineInputBorder(),
            suffixIcon: query.isEmpty
                ? null
                : IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_search.clear)),
          ),
          onChanged: (_) => setState(() {}),
        ),
      ),
      if (query.isNotEmpty)
        SectionCard(title: 'מסכים', children: [
          ScreenSearchResults(
            query: query,
            onOpen: (d) {
              setState(_search.clear);
              FocusScope.of(context).unfocus();
              openDest(context, d);
            },
          ),
        ])
      else ...[
      const MonthNumbers(),
      const Divider(height: 1),
      for (final (title, items) in Dest.sections(admin: admin))
        if (items.any((d) => !Dest.tabs.contains(d)))
          SectionCard(title: title, children: [
            for (final d in items.where((d) => !Dest.tabs.contains(d)))
              ListTile(
                leading: Icon(d.icon),
                title: Text(d.title),
                trailing: _badgeFor(context, d) ?? const Icon(Icons.chevron_left),
                onTap: () => Navigator.push(
                  context,
                  glassRoute((_) => _pageWithBar(d)),
                ),
              ),
          ]),
      const Padding(padding: EdgeInsets.only(top: 4), child: AppVersionLabel()),
      ],
    ].map((w) => w is SectionCard ? Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: w) : w).toList());
  }
}
