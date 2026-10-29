import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../sync/account.dart';
import '../sync/server_sync.dart';
import 'app_log.dart';

/// Support threads, the subscriber number and the device report — port of Support.swift (user side only).

class SupportThread {
  SupportThread(Map<String, dynamic> j)
      : id = (j['id'] as String).toLowerCase(),
        subject = j['subject'] as String? ?? '',
        category = j['category'] as String? ?? 'other',
        status = j['status'] as String? ?? 'open',
        createdAt = DateTime.tryParse(j['created_at'] as String? ?? '')?.toLocal(),
        lastMessageAt = DateTime.tryParse(j['last_message_at'] as String? ?? '')?.toLocal(),
        userUnread = (j['user_unread'] as num?)?.toInt() ?? 0;

  final String id;
  final String subject;
  final String category;
  final String status;
  final DateTime? createdAt;
  final DateTime? lastMessageAt;
  final int userUnread;

  bool get isOpen => status == 'open';

  static const categories = {
    'bug': 'תקלה',
    'question': 'שאלה',
    'idea': 'רעיון לשיפור',
    'other': 'אחר',
  };

  static String titleOf(String category) => categories[category] ?? category;
}

class SupportMessage {
  SupportMessage(Map<String, dynamic> j)
      : id = (j['id'] as num).toInt(),
        fromAdmin = j['from_admin'] == true,
        body = j['body'] as String? ?? '',
        log = j['log'] as String?,
        createdAt = DateTime.tryParse(j['created_at'] as String? ?? '')?.toLocal();

  final int id;
  final bool fromAdmin;
  final String body;
  final String? log;
  final DateTime? createdAt;
}

/// What a support message tells about the device (always sent) and the full report (only when logs are attached).
class Diagnostics {
  static String appVersion = '?';

  static Future<void> init() async {
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = '${info.version} (${info.buildNumber})';
    } catch (_) {}
  }

  static String get platform =>
      '${Platform.isWindows ? 'Windows' : Platform.isAndroid ? 'Android' : Platform.operatingSystem} ${Platform.operatingSystemVersion}';

  static Map<String, dynamic> appInfo({required String device, int? memberNo}) => {
        'version': appVersion,
        'platform': platform,
        'device': device,
        if (memberNo != null) 'member_no': memberNo,
      };

  static String report({required UserAccount account, required ServerSync sync, required String device, int? memberNo}) {
    final last = sync.lastSync;
    return [
      'גרסה: $appVersion',
      'מערכת: $platform',
      'מכשיר: $device',
      'מספר מנוי: ${memberNo ?? '—'}',
      'חשבון: ${account.userId ?? '—'}',
      'משק בית פעיל: ${account.activeHouseholdId ?? '—'}',
      'משקי בית: ${account.households.map((h) => '${h.name} [${h.role}] rev ${h.revision}').join(' | ')}',
      'סנכרון אחרון: ${last?.toIso8601String() ?? '—'}',
      'שגיאת סנכרון: ${sync.lastError ?? 'אין'}',
      '',
      '— יומן —',
      AppLog.recent(),
    ].join('\n');
  }
}

/// The signed-in user's support threads, the unread badge and the subscriber number.
class SupportCenter extends ChangeNotifier {
  SupportCenter({required this.deviceName});

  final String deviceName;
  SupabaseClient get _c => Supabase.instance.client;

  List<SupportThread> threads = [];
  int unread = 0;
  int? memberNo;
  bool loaded = false;

  String? _listeningAs;
  RealtimeChannel? _channel;

  /// Called whenever the signed-in user changes (null after sign-out).
  Future<void> start(String? userId) async {
    if (_listeningAs == userId) return;
    await stop();
    threads = [];
    unread = 0;
    memberNo = null;
    loaded = false;
    notifyListeners();
    if (userId == null) return;
    _listeningAs = userId;
    await refresh();
    try {
      final p = await _c.rpc('my_profile');
      if (p is Map && p['member_no'] is num) memberNo = (p['member_no'] as num).toInt();
      notifyListeners();
    } catch (e) {
      AppLog.add('support', 'my_profile נכשל: $e');
    }
    // Row-level security sends each user only their own threads.
    _channel = _c.channel('support-$userId')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'support_threads',
        callback: (_) => refresh(),
      )
      ..subscribe();
  }

  Future<void> stop() async {
    final ch = _channel;
    _channel = null;
    _listeningAs = null;
    if (ch != null) {
      try {
        await _c.removeChannel(ch);
      } catch (_) {}
    }
  }

  Future<void> refresh() async {
    final me = _listeningAs;
    if (me == null) return;
    try {
      final rows = await _c
          .from('support_threads')
          .select()
          .eq('user_id', me)
          .order('last_message_at', ascending: false);
      threads = rows.map(SupportThread.new).toList();
      unread = threads.fold(0, (s, t) => s + t.userUnread);
      loaded = true;
      notifyListeners();
    } catch (e) {
      AppLog.add('support', 'טעינת הפניות נכשלה: $e');
    }
  }

  Future<String> openThread({required String subject, required String category, required String body, String? log}) async {
    final id = await _c.rpc('support_open_thread', params: {
      'p_subject': subject,
      'p_category': category,
      'p_body': body,
      'p_log': log,
      'p_app_info': Diagnostics.appInfo(device: deviceName, memberNo: memberNo),
    });
    AppLog.add('support', 'נפתחה פנייה $id');
    await refresh();
    return (id as String).toLowerCase();
  }

  Future<void> send(String thread, String body, String? log) =>
      _c.rpc('support_send', params: {'p_thread': thread, 'p_body': body, 'p_log': log});

  Future<void> markRead(String thread) async {
    try {
      await _c.rpc('support_mark_read', params: {'p_thread': thread});
    } catch (_) {}
  }

  Future<void> setStatus(String thread, {required bool open}) =>
      _c.rpc('support_set_status', params: {'p_thread': thread, 'p_status': open ? 'open' : 'closed'});

  Future<List<SupportMessage>> messages(String thread) async {
    final rows = await _c.from('support_messages').select().eq('thread_id', thread).order('id');
    return rows.map(SupportMessage.new).toList();
  }

  Future<SupportThread> thread(String id) async =>
      SupportThread(await _c.from('support_threads').select().eq('id', id).single());

  /// New messages in one thread, live. Returns how to stop.
  Future<void> Function() listenToThread(String thread, void Function() onMessage) {
    final ch = _c.channel('support-thread-$thread')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'support_messages',
        filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'thread_id', value: thread),
        callback: (_) => onMessage(),
      )
      ..subscribe();
    return () async {
      try {
        await _c.removeChannel(ch);
      } catch (_) {}
    };
  }
}
