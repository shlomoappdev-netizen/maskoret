import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/update/updater.dart';

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
}
