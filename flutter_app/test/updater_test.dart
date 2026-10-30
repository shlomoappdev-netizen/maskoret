import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/support/announcements.dart';
import 'package:maskoret/update/updater.dart';
import 'package:maskoret/update/whats_new.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('reads the shared release manifest (maskoret-releases/latest.json)', () {
    final r = Release(jsonDecode('''
{"version":"4.1.4","build":34,"date":"2026-10-29","notes":["א","ב"],
 "platforms":{
   "android":{"url":"https://github.com/x/releases/download/v4.1.4/maskoret-android.apk","sha256":"D9E9","size":58615641},
   "windows":{"url":"https://github.com/x/releases/download/v4.1.4/maskoret-windows.zip","sha256":"7af5","size":13711154},
   "mac":{"url":"https://github.com/x/releases/download/v4.1.4/maskoret-mac.dmg"}}}
''') as Map<String, dynamic>);
    expect(r.version, '4.1.4');
    expect(r.build, 34);
    expect(r.notes, ['א', 'ב']);
    expect(r.platforms.keys, containsAll(['android', 'windows', 'mac']));
    expect(r.platforms['android']!.sha256, 'd9e9');
    expect(r.platforms['windows']!.size, 13711154);
  });

  test('a manifest without this platform offers nothing', () {
    final r = Release({'version': '5', 'build': 99, 'platforms': {'mac': {'url': 'x'}}});
    expect(r.platforms['android'], isNull);
    expect(r.platforms['windows'], isNull);
  });

  test('"later" hides the same version until the next launch, a newer one is offered again', () {
    final u = Updater()..currentBuild = 36;
    u.latest = Release({'version': '4.3.0', 'build': 37, 'platforms': {'android': {'url': 'x'}, 'windows_setup': {'url': 'y'}}});
    expect(u.shouldPrompt, isTrue);
    u.promptShown();
    expect(u.shouldPrompt, isFalse, reason: 'already on screen');
    u.postpone();
    expect(u.shouldPrompt, isFalse);
    u.latest = Release({'version': '4.3.1', 'build': 38, 'platforms': {'android': {'url': 'x'}, 'windows_setup': {'url': 'y'}}});
    expect(u.shouldPrompt, isTrue);
    expect((Updater()..currentBuild = 36..latest = u.latest).shouldPrompt, isTrue, reason: 'a new launch asks again');
  });

  group('what\'s new', () {
    const changelog = '''[
      {"version":"4.3.0","build":38,"date":"2026-11-10","notes":["ג"]},
      {"version":"4.2.0","build":36,"date":"2026-10-30","notes":["א","ב"]},
      {"version":"4.1.5","build":35,"date":"2026-10-29","notes":["ישן"]}]''';

    test('a first install shows nothing and remembers the build', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var fetched = false;
      expect(await WhatsNew.pending(prefs, 36, fetch: (_) async => (fetched = true, changelog).$2), isNull);
      expect(fetched, isFalse);
      expect(prefs.getInt(WhatsNew.seenKey), 36);
    });

    test('after an update: every version since the last one seen, newest first', () async {
      SharedPreferences.setMockInitialValues({WhatsNew.seenKey: 35});
      final prefs = await SharedPreferences.getInstance();
      final entries = await WhatsNew.pending(prefs, 38, fetch: (_) async => changelog);
      expect(entries!.map((e) => e.version), ['4.3.0', '4.2.0']);
      expect(entries[1].notes, ['א', 'ב']);
      expect(prefs.getInt(WhatsNew.seenKey), 35, reason: 'marked only when the window is closed');
      await WhatsNew.markSeen(prefs, 38);
      expect(await WhatsNew.pending(prefs, 38, fetch: (_) async => changelog), isNull);
    });

    test('no network or no changelog yet: quietly, and again next launch', () async {
      SharedPreferences.setMockInitialValues({WhatsNew.seenKey: 35});
      final prefs = await SharedPreferences.getInstance();
      expect(await WhatsNew.pending(prefs, 36, fetch: (_) async => null), isNull);
      expect(await WhatsNew.pending(prefs, 36, fetch: (_) async => throw Exception('offline')), isNull);
      expect(prefs.getInt(WhatsNew.seenKey), 35);
      expect((await WhatsNew.pending(prefs, 36, fetch: (_) async => changelog))!.single.version, '4.2.0');
    });
  });

  test('announcements: the newest live one that wasn\'t closed', () {
    final now = DateTime.utc(2026, 10, 30, 12);
    final all = [
      Announcement({'id': 1, 'title': 'ישנה', 'active': true}),
      Announcement({'id': 2, 'title': 'פגה', 'active': true, 'expires_at': '2026-10-29T00:00:00Z'}),
      Announcement({'id': 3, 'title': 'הופסקה', 'active': false}),
      Announcement({'id': 4, 'title': 'עד מחר', 'active': true, 'expires_at': '2026-10-31T00:00:00+00:00'}),
    ];
    expect(Announcements.pick(all, {}, now)!.id, 4);
    expect(Announcements.pick(all, {4}, now)!.id, 1);
    expect(Announcements.pick(all, {4, 1}, now), isNull);
  });
}
