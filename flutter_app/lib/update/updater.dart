import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';


/// A published version: the shared manifest of every platform (written when a release is published to
/// github.com/shlomoappdev-netizen/maskoret-releases). `build` is one counter for all the apps (version.json).
class Release {
  Release(Map<String, dynamic> j)
      : version = j['version'] as String? ?? '',
        build = (j['build'] as num?)?.toInt() ?? 0,
        date = j['date'] as String?,
        notes = ((j['notes'] as List?) ?? const []).whereType<String>().toList(),
        platforms = ((j['platforms'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k as String, v is Map ? ReleaseFile(v.cast<String, dynamic>()) : null))
          ..removeWhere((k, v) => v == null);

  final String version;
  final int build;
  final String? date;
  final List<String> notes;
  final Map<String, ReleaseFile?> platforms;

  /// Windows installs with the setup; "windows" (a ZIP) is only for copies of 4.1.x, which update by unpacking it.
  ReleaseFile? get forThisDevice => platforms[Platform.isWindows ? 'windows_setup' : 'android'];
}

class ReleaseFile {
  ReleaseFile(Map<String, dynamic> j)
      : url = j['url'] as String? ?? '',
        sha256 = (j['sha256'] as String?)?.toLowerCase(),
        size = (j['size'] as num?)?.toInt();
  final String url;
  final String? sha256;
  final int? size;
}

enum UpdatePhase { idle, checking, downloading, installing, failed }

/// Updates for Android and Windows: the app checks releases/latest.json on the server and, when there's a
/// newer build, downloads and installs it (Android: the system installer; Windows: the setup, run silently,
/// which reopens the app). The iPhone gets its versions from Xcode; the Mac has its own updater.
class Updater extends ChangeNotifier {
  /// Overridable only for testing the update flow against a local server (--dart-define=UPDATE_URL=…).
  static const latestUrl = String.fromEnvironment('UPDATE_URL',
      defaultValue: 'https://shlomoappdev-netizen.github.io/maskoret-releases/latest.json');
  static const _channel = MethodChannel('maskoret/update');

  String currentVersion = '';
  int currentBuild = 0;
  Release? latest;
  UpdatePhase phase = UpdatePhase.idle;
  double progress = 0;
  String? error;
  DateTime? lastCheck;

  /// Only where updates are published (not on the iPhone/Mac, and not in tests).
  static bool get supported => Platform.isAndroid || Platform.isWindows;

  bool get available => latest != null && latest!.build > currentBuild && latest!.forThisDevice != null;
  bool get busy => phase == UpdatePhase.checking || phase == UpdatePhase.downloading || phase == UpdatePhase.installing;

  /// Checks for a newer version (quietly; at launch, on return to the app, and from the updates screen).
  Future<void> check({bool force = false}) async {
    if (!supported || busy) return;
    if (!force && lastCheck != null && DateTime.now().difference(lastCheck!) < const Duration(hours: 1)) return;
    phase = UpdatePhase.checking;
    error = null;
    notifyListeners();
    try {
      if (currentBuild == 0) {
        final info = await PackageInfo.fromPlatform();
        currentVersion = info.version;
        currentBuild = int.tryParse(info.buildNumber) ?? 0;
      }
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      final request = await client.getUrl(Uri.parse('$latestUrl?t=${DateTime.now().millisecondsSinceEpoch}'));
      final response = await request.close();
      if (response.statusCode == 200) {
        latest = Release(jsonDecode(await response.transform(utf8.decoder).join()) as Map<String, dynamic>);
      } else if (response.statusCode != 400 && response.statusCode != 404) {
        // 400/404: nothing published yet.
        throw HttpException('HTTP ${response.statusCode}');
      }
      client.close();
      lastCheck = DateTime.now();
      phase = UpdatePhase.idle;
    } catch (e) {
      phase = UpdatePhase.failed;
      error = 'לא ניתן לבדוק עדכונים כרגע.';
    }
    notifyListeners();
  }

  /// Downloads the new version and installs it.
  Future<void> install() async {
    final target = latest?.forThisDevice;
    if (target == null || busy) return;
    phase = UpdatePhase.downloading;
    progress = 0;
    error = null;
    notifyListeners();
    try {
      final dir = await Directory.systemTemp.createTemp('maskoret-update');
      final file = File('${dir.path}/${Platform.isWindows ? 'maskoret-windows-setup.exe' : 'maskoret.apk'}');
      await _download(target.url, file);
      // The file must be exactly the published one.
      if (target.sha256 != null) {
        final digest = await Sha256().hash(await file.readAsBytes());
        final hex = digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        if (hex != target.sha256) throw const _Corrupt();
      }
      phase = UpdatePhase.installing;
      notifyListeners();
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod<String>('installApk', {'path': file.path});
        // "permission": the user was sent to allow installs from this app — they tap "עדכן" again after.
        if (result == 'permission') {
          phase = UpdatePhase.idle;
          error = 'אשר "התקנה מהאפליקציה הזו" במסך שנפתח, וחזור ללחוץ "עדכן".';
        } else {
          phase = UpdatePhase.idle;
        }
      } else {
        await _installWindows(file);
      }
    } catch (e) {
      phase = UpdatePhase.failed;
      error = e is _Corrupt
          ? 'הקובץ שהורד פגום. נסה שוב.'
          : 'העדכון נכשל. נסה שוב בעוד רגע.';
    }
    notifyListeners();
  }

  Future<void> _download(String url, File file) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final response = await (await client.getUrl(Uri.parse(url))).close();
      if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}');
      final total = response.contentLength;
      var received = 0;
      final sink = file.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          progress = received / total;
          notifyListeners();
        }
      }
      await sink.close();
    } finally {
      client.close();
    }
  }

  /// Windows: runs the downloaded installer silently and closes; the installer replaces the app (closing it if
  /// needed) and opens the new version. A copy that was unpacked from a ZIP (4.1.x) moves to the installed one.
  Future<void> _installWindows(File setup) async {
    await Process.start(
      setup.path,
      ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }
}

class _Corrupt implements Exception {
  const _Corrupt();
}
