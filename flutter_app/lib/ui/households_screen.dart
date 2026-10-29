import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/fmt.dart';
import '../sync/account.dart';
import 'auth_screen.dart';
import 'common.dart';

/// Households and the user's account — like FamilyView.swift / the account part of AuthView.swift.
class HouseholdsScreen extends StatelessWidget {
  const HouseholdsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = context.scope;
    return Scaffold(
      appBar: AppBar(title: const Text('משקי בית וחשבון')),
      body: ListenableBuilder(
        listenable: Listenable.merge([scope.account, scope.sync]),
        builder: (context, _) {
          final account = scope.account;
          final sync = scope.sync;
          final theme = Theme.of(context);
          if (!account.isSignedIn) {
            return PageList(children: [
              SectionCard(title: 'לא מחובר', subtitle: 'הנתונים נשמרים רק במכשיר הזה', children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton(
                    onPressed: () => Navigator.push(
                        context, MaterialPageRoute(builder: (_) => AuthScreen(onDone: () => Navigator.pop(context)))),
                    child: const Text('התחברות או הרשמה'),
                  ),
                ),
              ]),
            ]);
          }
          return PageList(children: [
            SectionCard(title: 'הסנכרון', children: [
              ListTile(
                leading: Icon(sync.lastError != null ? Icons.cloud_off : Icons.cloud_done_outlined,
                    color: sync.lastError != null ? theme.colorScheme.error : theme.colorScheme.primary),
                title: Text(sync.lastError ?? (sync.status.isEmpty ? 'מסונכרן' : sync.status)),
                subtitle: sync.lastSync == null ? null : Text('סנכרון אחרון: ${Fmt.date(sync.lastSync!)} ${_time(sync.lastSync!)}'),
                trailing: IconButton(tooltip: 'סנכרן עכשיו', icon: const Icon(Icons.sync), onPressed: sync.sync),
              ),
            ]),
            SectionCard(
              title: 'משקי הבית שלי',
              subtitle: 'כל משק בית הוא סט נתונים מלא, משותף לכל החברים בו',
              children: [
                for (final h in account.households)
                  ListTile(
                    leading: Icon(h.id == account.activeHouseholdId ? Icons.radio_button_checked : Icons.radio_button_off,
                        color: theme.colorScheme.primary),
                    title: Text(h.name),
                    subtitle: Text('${h.isOwner ? 'בעלים' : 'חבר'} · ${h.memberCount} ${h.memberCount == 1 ? 'משתמש' : 'משתמשים'}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.more_vert),
                      tooltip: 'ניהול',
                      onPressed: () => Navigator.push(
                          context, MaterialPageRoute(builder: (_) => HouseholdDetail(householdId: h.id))),
                    ),
                    onTap: h.id == account.activeHouseholdId ? null : () => sync.switchTo(h.id),
                  ),
                OverflowBar(alignment: MainAxisAlignment.start, spacing: 8, children: [
                  TextButton.icon(
                    icon: const Icon(Icons.add_home_outlined),
                    label: const Text('משק בית חדש'),
                    onPressed: () => _create(context),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.group_add_outlined),
                    label: const Text('הצטרפות עם קוד'),
                    onPressed: () => _join(context),
                  ),
                ]),
              ],
            ),
            SectionCard(title: 'החשבון שלי', children: [
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(account.displayName.isEmpty ? 'ללא שם' : account.displayName),
                subtitle: Text(account.email ?? '', textDirection: TextDirection.ltr, textAlign: TextAlign.right),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => _rename(context),
              ),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('התנתקות'),
                onTap: () => _signOut(context),
              ),
              ListTile(
                leading: Icon(Icons.delete_forever_outlined, color: theme.colorScheme.error),
                title: Text('מחיקת החשבון', style: TextStyle(color: theme.colorScheme.error)),
                subtitle: const Text('משקי בית שרק אתה חבר בהם יימחקו; משותפים יעברו לחבר הוותיק ביותר'),
                onTap: () async {
                  if (await confirm(context, 'למחוק את החשבון?', 'אי אפשר לבטל את זה.', ok: 'מחיקה') && context.mounted) {
                    if (await run(context, account.deleteAccount)) await sync.signedOut(clearDevice: false);
                  }
                },
              ),
            ]),
          ]);
        },
      ),
    );
  }

  static String _time(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  Future<String?> _ask(BuildContext context, String title, String label, {String initial = '', String ok = 'אישור'}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ביטול')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(ok)),
        ],
      ),
    );
  }

  Future<void> _create(BuildContext context) async {
    final name = await _ask(context, 'משק בית חדש', 'שם', ok: 'יצירה');
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    await context.scope.sync.createHousehold(name.trim());
    if (context.mounted && context.scope.sync.lastError != null) showMessage(context, context.scope.sync.lastError!);
  }

  Future<void> _join(BuildContext context) async {
    final code = await _ask(context, 'הצטרפות למשק בית', 'קוד ההזמנה', ok: 'הצטרפות');
    if (code == null || code.trim().isEmpty || !context.mounted) return;
    final scope = context.scope;
    await run(context, () async {
      final id = await scope.account.acceptInvite(code);
      await scope.sync.switchTo(id);
      if (context.mounted) showMessage(context, 'הצטרפת למשק הבית');
    });
  }

  Future<void> _rename(BuildContext context) async {
    final account = context.scope.account;
    final name = await _ask(context, 'השם שלך', 'שם', initial: account.displayName);
    if (name == null || !context.mounted) return;
    await run(context, () => account.updateDisplayName(name));
  }

  Future<void> _signOut(BuildContext context) async {
    final scope = context.scope;
    final clear = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('התנתקות'),
        content: const Text('הנתונים שמורים בשרת. להשאיר עותק שלהם במכשיר הזה?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ביטול')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('למחוק מהמכשיר')),
          FilledButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('להשאיר')),
        ],
      ),
    );
    if (clear == null) return;
    await scope.sync.signedOut(clearDevice: clear);
    await scope.account.signOut();
    if (context.mounted) Navigator.pop(context);
  }
}

class HouseholdDetail extends StatefulWidget {
  const HouseholdDetail({super.key, required this.householdId});
  final String householdId;

  @override
  State<HouseholdDetail> createState() => _HouseholdDetailState();
}

class _HouseholdDetailState extends State<HouseholdDetail> {
  List<HouseholdMember>? members;
  HouseholdInvite? invite;
  String? error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final list = await context.scope.account.members(widget.householdId);
      if (mounted) setState(() => members = list);
    } catch (e) {
      if (mounted) setState(() => error = UserAccount.describe(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = context.scope;
    return ListenableBuilder(
      listenable: scope.account,
      builder: (context, _) {
        final h = scope.account.households.where((x) => x.id == widget.householdId).firstOrNull;
        if (h == null) return const Scaffold(body: Center(child: Text('משק הבית כבר לא זמין')));
        final theme = Theme.of(context);
        final me = scope.account.userId;
        return Scaffold(
          appBar: AppBar(title: Text(h.name)),
          body: PageList(children: [
            SectionCard(title: 'חברים', children: [
              if (error != null) EmptyHint(error!),
              if (members == null && error == null) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
              for (final m in members ?? <HouseholdMember>[])
                ListTile(
                  leading: Icon(m.isOwner ? Icons.star_outline : Icons.person_outline),
                  title: Text(m.title + (m.userId == me ? ' (אני)' : '')),
                  subtitle: Text(m.isOwner ? 'בעלים' : (m.email ?? 'חבר')),
                  trailing: h.isOwner && m.userId != me
                      ? IconButton(
                          tooltip: 'הסרה',
                          icon: const Icon(Icons.person_remove_outlined),
                          onPressed: () async {
                            if (await confirm(context, 'להסיר את ${m.title}?', 'הוא לא יוכל לראות יותר את משק הבית.',
                                    ok: 'הסרה') &&
                                context.mounted) {
                              if (await run(context, () => scope.account.removeMember(m.userId, h.id))) _load();
                            }
                          },
                        )
                      : null,
                ),
            ]),
            SectionCard(
              title: 'הזמנה',
              subtitle: 'שלח את הקוד למי שתרצה לצרף. הוא נכנס ב״הצטרפות עם קוד״.',
              children: [
                if (invite != null)
                  ListTile(
                    title: SelectableText(invite!.code,
                        textDirection: TextDirection.ltr,
                        style: theme.textTheme.headlineSmall?.copyWith(letterSpacing: 4, fontWeight: FontWeight.w700)),
                    subtitle: invite!.expiresAt == null ? null : Text('בתוקף עד ${Fmt.date(invite!.expiresAt!)}'),
                    trailing: IconButton(
                      tooltip: 'העתקה',
                      icon: const Icon(Icons.copy),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: invite!.code));
                        showMessage(context, 'הקוד הועתק');
                      },
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.vpn_key_outlined),
                    label: Text(invite == null ? 'יצירת קוד הזמנה' : 'קוד חדש'),
                    onPressed: () => run(context, () async {
                      final i = await scope.account.createInvite(h.id);
                      if (mounted) setState(() => invite = i);
                    }),
                  ),
                ),
              ],
            ),
            SectionCard(title: 'ניהול', children: [
              if (h.isOwner)
                ListTile(
                  leading: const Icon(Icons.drive_file_rename_outline),
                  title: const Text('שינוי שם'),
                  onTap: () async {
                    final c = TextEditingController(text: h.name);
                    final name = await showDialog<String>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('שם משק הבית'),
                        content: TextField(controller: c, autofocus: true),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ביטול')),
                          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('שמירה')),
                        ],
                      ),
                    );
                    if (name != null && name.trim().isNotEmpty && context.mounted) {
                      await run(context, () => scope.account.rename(h.id, name.trim()));
                    }
                  },
                ),
              if (!h.isOwner)
                ListTile(
                  leading: Icon(Icons.exit_to_app, color: theme.colorScheme.error),
                  title: Text('עזיבת משק הבית', style: TextStyle(color: theme.colorScheme.error)),
                  onTap: () async {
                    if (await confirm(context, 'לעזוב את ${h.name}?', 'לא תוכל לראות אותו יותר, אלא אם יזמינו אותך שוב.',
                            ok: 'עזיבה') &&
                        context.mounted) {
                      if (await run(context, () => scope.account.leave(h.id))) {
                        await scope.sync.accountChanged();
                        if (context.mounted) Navigator.pop(context);
                      }
                    }
                  },
                ),
              if (h.isOwner)
                ListTile(
                  leading: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                  title: Text('מחיקת משק הבית', style: TextStyle(color: theme.colorScheme.error)),
                  subtitle: const Text('הנתונים יימחקו מהשרת לכל החברים'),
                  onTap: () async {
                    if (await confirm(context, 'למחוק את ${h.name}?', 'כל הנתונים שלו יימחקו מהשרת לכל החברים. אי אפשר לבטל.',
                            ok: 'מחיקה') &&
                        context.mounted) {
                      if (await run(context, () => scope.account.delete(h.id))) {
                        await scope.sync.accountChanged();
                        if (context.mounted) Navigator.pop(context);
                      }
                    }
                  },
                ),
            ]),
          ]),
        );
      },
    );
  }
}
