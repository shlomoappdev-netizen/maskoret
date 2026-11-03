import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/fmt.dart';
import '../sync/account.dart';
import 'common.dart';

/// One row of public.announcements as the admin sees it (ended ones too).
class AdminAnnouncement {
  AdminAnnouncement(Map<String, dynamic> j)
      : id = (j['id'] as num).toInt(),
        title = j['title'] as String? ?? '',
        body = j['body'] as String? ?? '',
        active = j['active'] as bool? ?? true,
        createdAt = DateTime.tryParse(j['created_at'] as String? ?? '')?.toLocal(),
        expiresAt = DateTime.tryParse(j['expires_at'] as String? ?? '')?.toLocal();

  final int id;
  final String title;
  final String body;
  final bool active;
  final DateTime? createdAt;
  final DateTime? expiresAt;

  bool get isLive => active && (expiresAt == null || expiresAt!.isAfter(DateTime.now()));
}

/// A message for every user, at the top of their summary until they close it (AdminAnnouncementsView in AdminView.swift).
class AdminAnnouncementsScreen extends StatefulWidget {
  const AdminAnnouncementsScreen({super.key});

  @override
  State<AdminAnnouncementsScreen> createState() => _AdminAnnouncementsScreenState();
}

class _AdminAnnouncementsScreenState extends State<AdminAnnouncementsScreen> {
  static const _durations = [(0, 'עד שאפסיק'), (3, '3 ימים'), (7, 'שבוע'), (30, 'חודש')];

  final _title = TextEditingController();
  final _text = TextEditingController();
  int _days = 0;
  List<AdminAnnouncement> _list = [];
  bool _loaded = false;
  bool _sending = false;
  String? _error;

  SupabaseClient get _c => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _title.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await _c.from('announcements').select().order('id', ascending: false).limit(50);
      if (!mounted) return;
      setState(() {
        _list = [for (final r in rows) AdminAnnouncement(r)];
        _loaded = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = UserAccount.describe(e));
    }
  }

  /// Runs a server call, then reloads the list and the banner.
  Future<void> _run(Future<void> Function() action) async {
    final banner = context.scope.announcements;
    setState(() => _sending = true);
    try {
      await action();
      _error = null;
      await _load();
      await banner.refresh();
    } catch (e) {
      _error = UserAccount.describe(e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _post() async {
    final title = _title.text.trim(), body = _text.text.trim();
    if (title.isEmpty) return;
    if (!await confirm(context, 'שליחה לכל המשתמשים', 'ההודעה ״$title״ תופיע מיד לכל המשתמשים.', ok: 'שליחה', danger: false)) {
      return;
    }
    await _run(() async {
      await _c.rpc('admin_post_announcement', params: {'p_title': title, 'p_body': body, 'p_days': _days == 0 ? null : _days});
      _title.clear();
      _text.clear();
    });
  }

  Future<void> _end(AdminAnnouncement a) async {
    if (!await confirm(context, 'להפסיק להציג את ״${a.title}״?', 'ההודעה תיעלם אצל כל המשתמשים.', ok: 'הפסק להציג')) return;
    await _run(() => _c.rpc('admin_end_announcement', params: {'p_id': a.id}));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: const Text('הודעות למשתמשים')),
      body: PageList(children: [
        SectionCard(title: 'הודעה חדשה', children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                controller: _title,
                maxLength: 120,
                decoration: const InputDecoration(labelText: 'כותרת'),
              ),
              gap,
              TextField(
                controller: _text,
                maxLength: 2000,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(labelText: 'טקסט (לא חובה)', alignLabelWithHint: true),
              ),
              gap,
              Text('להציג', style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              SegmentedButton<int>(
                showSelectedIcon: false,
                segments: [for (final (d, t) in _durations) ButtonSegment(value: d, label: Text(t))],
                selected: {_days},
                onSelectionChanged: (v) => setState(() => _days = v.first),
              ),
              if (_error != null) ...[
                gap,
                Text(_error!, style: theme.textTheme.bodyMedium?.copyWith(color: Colors.orange.shade800)),
              ],
              gap,
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.icon(
                  icon: const Icon(Icons.campaign),
                  label: const Text('שליחה לכל המשתמשים'),
                  onPressed: _title.text.trim().isEmpty || _sending ? null : _post,
                ),
              ),
              gap,
              Text(
                  'ההודעה תופיע מיד לכל המשתמשים (גם בלי חשבון) בראש מסך ״בית״, עם איקס לסגירה. '
                  'מי שסגר אותה לא יראה אותה שוב באותו מכשיר.',
                  style: muted),
            ]),
          ),
        ]),
        SectionCard(title: 'הודעות', children: [
          if (!_loaded && _error == null) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
          if (_loaded && _list.isEmpty) const EmptyHint('עוד לא נשלחו הודעות.'),
          for (final a in _list)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(a.title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
                  _Badge(live: a.isLive),
                ]),
                if (a.body.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(a.body, style: muted)),
                Row(children: [
                  Expanded(
                    child: Text(
                        [if (a.createdAt != null) Fmt.date(a.createdAt!), if (a.expiresAt != null) 'עד ${Fmt.date(a.expiresAt!)}']
                            .join(' · '),
                        style: muted),
                  ),
                  if (a.isLive)
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                      onPressed: _sending ? null : () => _end(a),
                      child: const Text('הפסק להציג'),
                    ),
                ]),
              ]),
            ),
        ]),
      ]),
    );
  }
}

/// "מוצגת" (green) or "הסתיימה" (grey).
class _Badge extends StatelessWidget {
  const _Badge({required this.live});
  final bool live;

  @override
  Widget build(BuildContext context) {
    final color = live ? Colors.green : Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(20)),
      child: Text(live ? 'מוצגת' : 'הסתיימה',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600, color: color)),
    );
  }
}
