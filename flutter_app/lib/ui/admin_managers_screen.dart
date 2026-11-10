import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../sync/account.dart';
import 'common.dart';

/// An admin tool another admin may be given (AdminPermission in AdminView.swift; keys of private.admins.permissions).
enum AdminPermission {
  users('users', 'מנויים ומשתמשים', 'חיפוש מנויים, כרטיס מנוי, חסימה, ניתוק, מחיקה ומשקי בית'),
  support('support', 'פניות תמיכה', 'כל הפניות, מענה, הצעות של Claude ושאלות אליו'),
  devTasks('dev_tasks', 'משימות פיתוח', 'משימות הפיתוח והשיחה עם Claude בתוכה'),
  announcements('announcements', 'הודעה לכולם', 'שליחת הודעה לכל המשתמשים והפסקת הצגתה');

  const AdminPermission(this.key, this.title, this.detail);
  final String key;
  final String title;
  final String detail;
}

/// One admin, as the main admin sees it (rpc admin_list_admins).
class AdminManager {
  AdminManager(Map<String, dynamic> j)
      : userId = j['user_id'] as String,
        email = j['email'] as String? ?? '',
        displayName = j['display_name'] as String? ?? '',
        owner = j['owner'] == true,
        permissions = {for (final p in (j['permissions'] as List? ?? const [])) '$p'};

  final String userId;
  final String email;
  final String displayName;
  final bool owner;
  final Set<String> permissions;

  String get name => displayName.isNotEmpty ? displayName : (email.isNotEmpty ? email : userId);
}

/// "מנהלים והרשאות": the main admin appoints admins and picks the tools each may use (AdminManagersView in
/// AdminView.swift). The server checks every call again, and nobody can change the main admin.
class AdminManagersScreen extends StatefulWidget {
  const AdminManagersScreen({super.key});

  @override
  State<AdminManagersScreen> createState() => _AdminManagersScreenState();
}

class _AdminManagersScreenState extends State<AdminManagersScreen> {
  final _email = TextEditingController();
  Set<String> _newPermissions = {AdminPermission.support.key};
  List<AdminManager> _admins = [];
  bool _loaded = false;
  bool _busy = false;
  String? _error;

  SupabaseClient get _c => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _email.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await _c.rpc('admin_list_admins');
      if (!mounted) return;
      setState(() {
        _admins = [for (final r in (rows as List? ?? const [])) AdminManager(Map<String, dynamic>.from(r as Map))];
        _loaded = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = UserAccount.describe(e));
    }
  }

  static String _describe(Object e) {
    final text = '$e';
    if (text.contains('no such user')) return 'לא נמצא חשבון עם האימייל הזה.';
    if (text.contains('owner')) return 'אי אפשר לשנות את ההרשאות של המנהל הראשי.';
    return UserAccount.describe(e);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      _error = null;
    } catch (e) {
      _error = _describe(e);
    }
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  List<String> _sorted(Set<String> s) => s.toList()..sort();

  Future<void> _add() async {
    final email = _email.text.trim();
    if (email.isEmpty) return;
    final perms = _sorted(_newPermissions);
    await _run(() async {
      await _c.rpc('admin_add_admin_by_email', params: {'p_email': email, 'p_permissions': perms});
      _email.clear();
    });
  }

  Future<void> _set(AdminManager a, AdminPermission p, bool on) async {
    final perms = {...a.permissions};
    on ? perms.add(p.key) : perms.remove(p.key);
    await _run(() => _c.rpc('admin_set_admin', params: {'target': a.userId, 'p_permissions': _sorted(perms)}));
  }

  Future<void> _remove(AdminManager a) async {
    if (!await confirm(context, 'להסיר את ${a.name} מהמנהלים?', 'החשבון לא יראה יותר את מסכי הניהול.', ok: 'הסרה')) return;
    await _run(() => _c.rpc('admin_remove_admin', params: {'target': a.userId}));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: const Text('מנהלים והרשאות')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: PageList(children: [
          SectionCard(title: 'מנהל חדש', children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(labelText: 'אימייל של החשבון'),
              ),
            ),
            for (final p in AdminPermission.values)
              CheckboxListTile(
                value: _newPermissions.contains(p.key),
                title: Text(p.title),
                subtitle: Text(p.detail),
                onChanged: (v) => setState(() {
                  _newPermissions = {..._newPermissions};
                  v == true ? _newPermissions.add(p.key) : _newPermissions.remove(p.key);
                }),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (_error != null) ...[
                  Text(_error!, style: theme.textTheme.bodyMedium?.copyWith(color: Colors.orange.shade800)),
                  gap,
                ],
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('הוספת מנהל'),
                    onPressed: _email.text.trim().isEmpty || _busy ? null : _add,
                  ),
                ),
                gap,
                Text(
                    'החשבון צריך להיות רשום באפליקציה עם אימייל מאומת. כל מנהל רואה רק את מסכי הניהול שסימנת לו, '
                    'והשרת בודק את ההרשאה בכל פעולה. רק המנהל הראשי ממנה מנהלים ומשנה הרשאות.',
                    style: muted),
              ]),
            ),
          ]),
          SectionCard(title: '${_admins.length} מנהלים', children: [
            if (!_loaded && _error == null) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
            for (final a in _admins) ...[
              ListTile(
                title: Text(a.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: a.displayName.isNotEmpty && a.email.isNotEmpty
                    ? Text(a.email, textDirection: TextDirection.ltr, textAlign: TextAlign.start)
                    : null,
                trailing: a.owner
                    ? Chip(label: const Text('מנהל ראשי'), visualDensity: VisualDensity.compact)
                    : TextButton(
                        style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                        onPressed: _busy ? null : () => _remove(a),
                        child: const Text('הסרה'),
                      ),
              ),
              if (a.owner)
                Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 10), child: Text('כל ההרשאות, תמיד.', style: muted))
              else
                for (final p in AdminPermission.values)
                  SwitchListTile(
                    dense: true,
                    title: Text(p.title),
                    value: a.permissions.contains(p.key),
                    onChanged: _busy ? null : (v) => _set(a, p, v),
                  ),
              const Divider(height: 1),
            ],
          ]),
        ]),
      ),
    );
  }
}
