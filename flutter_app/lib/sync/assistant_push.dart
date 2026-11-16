import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/assistant_tips.dart';
import '../data/month_picture.dart';
import '../insights/ai_notifier.dart';
import '../state/store.dart';
import '../support/app_log.dart';

/// The assistant's notifications to the household's phones (AssistantPush.swift on the Mac and the iPhone).
///
/// Every device, after it saves a change to the server, looks at the most important tip of the local rules
/// (`AssistantTips`); a new one that matters is handed to the server's `assistant-push` function, which sends it to
/// the household members' Android phones — each alert once, at most one notification a day per user, and never to
/// the phone that found it (its own screens already show the tip). Android phones register their Firebase token
/// while signed in.
class AssistantPush {
  AssistantPush(this.store, this.prefs);

  final AppStore store;
  final SharedPreferences prefs;

  static const _channel = MethodChannel('maskoret/push');

  /// Only alerts about the budget go out as notifications (severity 2 and up); housekeeping tips stay on the screens.
  static const minSeverity = 2;

  /// The tip worth a notification now, if any. Pure, for the tests.
  static AssistantTip? alert(AppStore store, {DateTime? now}) {
    final tip = AssistantTips.top(
        store.dashboard.money, MonthPicture.currentFull(store.dashboard), store.money.assistant.dismissedTips,
        now: now);
    return tip != null && tip.severity >= minSeverity ? tip : null;
  }

  String? get _token => prefs.getString('pushToken');

  /// Signed in on an Android phone: its Firebase token is saved in the account.
  Future<void> register() async {
    if (!Platform.isAndroid) return;
    try {
      final token = await _channel.invokeMethod<String>('token');
      if (token == null || token.isEmpty) return;
      await AINotifier.requestPermission();
      await Supabase.instance.client.rpc('push_token_save', params: {'p_token': token, 'p_platform': 'android'});
      await prefs.setString('pushToken', token);
    } catch (e) {
      AppLog.add('push', 'רישום להתראות נכשל: $e');
    }
  }

  /// Signing out: this phone stops getting the account's notifications.
  Future<void> unregister() async {
    final token = _token;
    if (token == null) return;
    try {
      await Supabase.instance.client.rpc('push_token_delete', params: {'p_token': token});
    } catch (_) {}
    await prefs.remove('pushToken');
  }

  /// After a save to the server: a new alert goes to the household's phones.
  Future<void> announce(String householdId) async {
    try {
      final tip = alert(store);
      if (tip == null) return;
      final sent = prefs.getStringList('pushAnnounced') ?? [];
      if (sent.contains(tip.id)) return;
      await Supabase.instance.client.functions.invoke('assistant-push', body: {
        'household_id': householdId,
        'alert_id': tip.id,
        'title': tip.title,
        'body': tip.text,
        'exclude_token': _token ?? '',
      });
      sent.add(tip.id);
      await prefs.setStringList('pushAnnounced', sent.length > 60 ? sent.sublist(sent.length - 60) : sent);
    } catch (e) {
      AppLog.add('push', 'שליחת התראה נכשלה: $e');
    }
  }
}
