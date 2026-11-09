import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'segments.dart';

/// The AI's analysis after a card import, as a system notification (Android and Windows; Notifier.swift on the Mac).
class AINotifier {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static int _next = 1;

  static bool get supported => Platform.isAndroid || Platform.isWindows;

  static Future<void> _init() async {
    if (_ready || !supported) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        windows: WindowsInitializationSettings(
          appName: 'מחשבון שכר',
          appUserModelId: 'ShlomoDavid.Maskoret',
          guid: 'c2e85cbb-676d-4eb2-9fca-598a0844edd9',
        ),
      ),
    );
    _ready = true;
  }

  /// Android 13 and later ask the user once; elsewhere nothing to ask.
  static Future<void> requestPermission() async {
    if (!supported) return;
    try {
      await _init();
      await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
    } catch (_) {}
  }

  static Future<void> post(String title, String body) async {
    if (!supported) return;
    try {
      await _init();
      await _plugin.show(
        id: _next++,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails('ai-analysis', 'ניתוח AI',
              channelDescription: 'ניתוח המצב אחרי ייבוא פירוט אשראי',
              importance: Importance.high,
              priority: Priority.high,
              styleInformation: BigTextStyleInformation(body)),
          windows: const WindowsNotificationDetails(),
        ),
      );
    } catch (_) {}
  }

  /// The answer's first line without markdown — the summary the model was asked to start with.
  static String headline(String answer) {
    final text = [for (final s in InsightParser.parse(answer)) if (s is TextSegment) s.text].join('\n');
    final first = text
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'^[\s#*_`>\-•]+|[\s*_`]+$'), ''))
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    final line = first.isEmpty ? 'הניתוח מוכן' : first;
    return '${line.length > 180 ? '${line.substring(0, 177)}…' : line}\nהפרטים בתובנות AI.';
  }
}
