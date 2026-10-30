import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// One version in the published changelog.json (newest first).
class ChangelogEntry {
  ChangelogEntry(Map<String, dynamic> j)
      : version = j['version'] as String? ?? '',
        build = (j['build'] as num?)?.toInt() ?? 0,
        date = j['date'] as String?,
        notes = ((j['notes'] as List?) ?? const []).whereType<String>().toList();

  final String version;
  final int build;
  final String? date;
  final List<String> notes;
}

/// "מה חדש" after an update: on the first launch of a newer build, the changelog of every version since the last
/// one the user saw. A first install shows nothing; without a network (or before changelog.json is published) it
/// tries again on the next launch.
class WhatsNew {
  static const url = String.fromEnvironment('CHANGELOG_URL',
      defaultValue: 'https://shlomoappdev-netizen.github.io/maskoret-releases/changelog.json');
  static const seenKey = 'whatsNewSeenBuild';

  /// The versions newer than [seen], up to and including [current], newest first.
  static List<ChangelogEntry> between(List<ChangelogEntry> all, int seen, int current) =>
      all.where((e) => e.build > seen && e.build <= current && e.notes.isNotEmpty).toList()
        ..sort((a, b) => b.build.compareTo(a.build));

  /// What to show now, or null. [fetch] returns the file's text, or null when it isn't there.
  static Future<List<ChangelogEntry>?> pending(SharedPreferences prefs, int current,
      {Future<String?> Function(Uri url)? fetch}) async {
    if (current <= 0) return null;
    final seen = prefs.getInt(seenKey);
    if (seen == null) {
      await prefs.setInt(seenKey, current);
      return null;
    }
    if (current <= seen) return null;
    try {
      final text = await (fetch ?? _get)(Uri.parse('$url?t=${DateTime.now().millisecondsSinceEpoch}'));
      if (text == null) return null;
      final all = [
        for (final e in jsonDecode(text) as List)
          if (e is Map) ChangelogEntry(e.cast<String, dynamic>())
      ];
      final entries = between(all, seen, current);
      if (entries.isEmpty) await markSeen(prefs, current);
      return entries.isEmpty ? null : entries;
    } catch (_) {
      return null;
    }
  }

  static Future<void> markSeen(SharedPreferences prefs, int build) => prefs.setInt(seenKey, build);

  static Future<String?> _get(Uri url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final response = await (await client.getUrl(url)).close();
      if (response.statusCode != 200) return null;
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close();
    }
  }
}
