import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_log.dart';

/// A message from the admin to every user (public.announcements).
class Announcement {
  Announcement(Map<String, dynamic> j)
      : id = (j['id'] as num).toInt(),
        title = j['title'] as String? ?? '',
        body = j['body'] as String? ?? '',
        active = j['active'] as bool? ?? true,
        expiresAt = DateTime.tryParse(j['expires_at'] as String? ?? '');

  final int id;
  final String title;
  final String body;
  final bool active;
  final DateTime? expiresAt;

  bool liveAt(DateTime now) => active && (expiresAt == null || expiresAt!.isAfter(now));
}

/// The admin's announcements: the newest active one the user didn't close shows at the top of the summary.
/// Closing is remembered on this device; a new one arrives right away over Realtime. Readable without an account.
class Announcements extends ChangeNotifier {
  Announcements(this.prefs, {this.client});

  final SharedPreferences prefs;
  final SupabaseClient? client;
  static const dismissedKey = 'dismissedAnnouncements';

  List<Announcement> all = [];
  RealtimeChannel? _channel;

  Set<int> get dismissed => {for (final s in prefs.getStringList(dismissedKey) ?? const <String>[]) ?int.tryParse(s)};

  /// The card to show, or null.
  Announcement? get current => pick(all, dismissed, DateTime.now());

  static Announcement? pick(List<Announcement> all, Set<int> dismissed, DateTime now) {
    final live = all.where((a) => a.liveAt(now) && !dismissed.contains(a.id)).toList()
      ..sort((a, b) => b.id.compareTo(a.id));
    return live.firstOrNull;
  }

  Future<void> start() async {
    final c = client;
    if (c == null) return;
    await refresh();
    _channel ??= c
        .channel('announcements')
        .onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'announcements', callback: (_) => refresh())
        .subscribe();
  }

  Future<void> refresh() async {
    final c = client;
    if (c == null) return;
    try {
      final rows = await c
          .from('announcements')
          .select('id,title,body,active,expires_at')
          .order('id', ascending: false)
          .limit(20);
      all = [for (final r in rows) Announcement(r)];
      notifyListeners();
    } catch (e) {
      AppLog.add('announcements', 'טעינת הודעות נכשלה: $e');
    }
  }

  Future<void> dismiss(int id) async {
    final ids = dismissed..add(id);
    await prefs.setStringList(dismissedKey, [for (final i in ids) '$i']);
    notifyListeners();
  }

  /// Demo mode: one sample message, nothing from the server.
  void showSample() {
    all = [
      Announcement({
        'id': -1,
        'title': 'גרסה 4.2.0 בדרך',
        'body': 'בגרסה הקרובה: עיצוב חדש, תחזית, מסך חודשים וכרטיס אשראי. תודה שאתם איתנו!',
      })
    ];
    notifyListeners();
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    super.dispose();
  }
}
