import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../sync/account.dart';

/// A published version (releases/latest.json, written by the GitHub workflow).
class Release {
  Release(Map<String, dynamic> j)
      : version = j['version'] as String? ?? '',
        build = (j['build'] as num?)?.toInt() ?? 0,
        date = j['date'] as String?,
        notes = ((j['notes'] as List?) ?? const []).whereType<String>().toList(),
        android = ((j['android'] as Map?) ?? const {}).cast<String, dynamic>().map((k, v) => MapEntry(k, v as String)),
        windows = j['windows'] as String?;

  final String version;
  final int build;
  final String? date;
  final List<String> notes;

  /// Processor type (arm64-v8a, armeabi-v7a, x86_64) → APK address.
  final Map<String, String> android;
  final String? windows;
}

enum UpdatePhase { idle, checking, downloading, installing, failed }

/// Updates for Android and Windows: the app checks releases/latest.json on the server and, when there's a
/// newer build, downloads and installs it (Android: the system installer; Windows: replaces its own files
/// and reopens). The iPhone gets its versions from Xcode; the Mac has its own updater.
class Updater extends ChangeNotifier {
  /// Overridable only for testing the update flow against a local server (--dart-define=UPDATE_URL=…).
  static const latestUrl = String.fromEnvironment('UPDATE_URL',
      defaultValue: '${SupabaseConfig.url}/storage/v1/object/public/releases/latest.json');
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

  bool get available => latest != null && latest!.build > currentBuild && _downloadUrl(latest!) != null;
  bool get busy => phase == UpdatePhase.checking || phase == UpdatePhase.downloading || phase == UpdatePhase.installing;

  String? _abiUrl;

  String? _downloadUrl(Release r) => Platform.isWindows ? r.windows : _abiUrl;

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
        final release = Release(jsonDecode(await response.transform(utf8.decoder).join()) as Map<String, dynamic>);
        if (Platform.isAndroid) {
          final abis = (await DeviceInfoPlugin().androidInfo).supportedAbis;
          _abiUrl = abis.map((a) => release.android[a]).whereType<String>().firstOrNull;
        }
        latest = release;
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
    final release = latest;
    final url = release == null ? null : _downloadUrl(release);
    if (url == null || busy) return;
    phase = UpdatePhase.downloading;
    progress = 0;
    error = null;
    notifyListeners();
    try {
      final dir = await Directory.systemTemp.createTemp('maskoret-update');
      final file = File('${dir.path}/${Platform.isWindows ? 'maskoret-windows.zip' : 'maskoret.apk'}');
      await _download(url, file);
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
      error = e is FileSystemException && Platform.isWindows
          ? 'אין הרשאה לעדכן את התיקייה של האפליקציה. העבר אותה לתיקייה שלך (למשל ‎C:\\מחשבון שכר‎) ונסה שוב.'
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

  /// Windows: a small PowerShell script waits for the app to close, unpacks the new files over the app's
  /// folder and opens it again. The folder must be writable (not Program Files).
  Future<void> _installWindows(File zip) async {
    final exe = Platform.resolvedExecutable;
    final folder = File(exe).parent.path;
    // Writing a test file fails early (with a clear message) when the folder isn't writable.
    final probe = File('$folder\\.update-test');
    probe.writeAsStringSync('ok');
    probe.deleteSync();
    final script = File('${zip.parent.path}\\update.ps1');
    String q(String s) => "'${s.replaceAll("'", "''")}'";
    // With a BOM, so Windows PowerShell reads Hebrew folder names correctly.
    script.writeAsStringSync('\uFEFF' '''
\$ErrorActionPreference = 'Stop'
Wait-Process -Id $pid -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Expand-Archive -LiteralPath ${q(zip.path)} -DestinationPath ${q(folder)} -Force
Start-Process -FilePath ${q(exe)}
''', encoding: utf8);
    await Process.start(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', script.path],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }
}
