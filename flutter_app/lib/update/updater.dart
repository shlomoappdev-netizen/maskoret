import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';


/// A published version: the shared manifest of every platform (written when a release is published to
/// github.com/shlomoappdev-netizen/maskoret-releases). `build` is one counter for all the apps (version.json).
/// Each platform goes out as soon as its own build is ready, so its file carries its own version and build; the
/// top-level ones are the oldest of them (for copies that don't read the per-platform ones).
class Release {
  Release(Map<String, dynamic> j)
      : _version = j['version'] as String? ?? '',
        _build = (j['build'] as num?)?.toInt() ?? 0,
        date = j['date'] as String?,
        notes = ((j['notes'] as List?) ?? const []).whereType<String>().toList(),
        platforms = ((j['platforms'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k as String, v is Map ? ReleaseFile(v.cast<String, dynamic>()) : null))
          ..removeWhere((k, v) => v == null);

  final String _version;
  final int _build;
  String get version => forThisDevice?.version ?? _version;
  int get build => forThisDevice?.build ?? _build;
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
        size = (j['size'] as num?)?.toInt(),
        version = j['version'] as String?,
        build = (j['build'] as num?)?.toInt();
  final String url;
  final String? sha256;
  final int? size;
  /// This platform's own version (missing in manifests from before platforms were published separately).
  final String? version;
  final int? build;
}

/// verifying: checking the downloaded file is exactly the published one (sha256; takes a few seconds on a phone).
enum UpdatePhase { idle, checking, downloading, verifying, installing, failed }

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
  Timer? _timer;

  /// Android: the user was sent to allow installs from this app; back in the app, the install goes on by itself.
  bool _waitingForPermission = false;
  /// A download broke in the middle — it goes on by itself when the user is back in the app.
  bool _resumeDownload = false;

  Updater() {
    if (Platform.isAndroid) _channel.setMethodCallHandler(_onPlatformCall);
  }

  /// The build the user answered "אחר כך" for — not offered again until the next launch.
  int? _postponedBuild;
  bool _prompting = false;

  /// Only where updates are published (not on the iPhone/Mac, and not in tests).
  static bool get supported => Platform.isAndroid || Platform.isWindows;

  bool get available => latest != null && latest!.build > currentBuild && latest!.forThisDevice != null;
  /// A newer version the user wasn't asked about yet (since this launch).
  bool get shouldPrompt => available && !busy && !_prompting && latest!.build != _postponedBuild;

  void promptShown() => _prompting = true;

  /// "אחר כך": closes the window; the same version isn't offered again until the next launch.
  void postpone() {
    _prompting = false;
    _postponedBuild = latest?.build;
  }

  /// Checks at launch, then every 3 hours while the app is open (and on return to it — see main.dart).
  void startAutoCheck() {
    check(force: true);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(hours: 3), (_) => check(force: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  bool get busy =>
      phase == UpdatePhase.checking ||
      phase == UpdatePhase.downloading ||
      phase == UpdatePhase.verifying ||
      phase == UpdatePhase.installing;

  void _verifying() {
    phase = UpdatePhase.verifying;
    notifyListeners();
  }

  /// Back in the app (see main.dart): if the user just allowed installs from this app, install what was downloaded.
  Future<void> resumed() async {
    // A download that broke while the app was in the background goes on from where it stopped.
    if (_resumeDownload && !busy) {
      _resumeDownload = false;
      await install();
      return;
    }
    if (!_waitingForPermission || busy) return;
    final allowed = await _channel.invokeMethod<bool>('canInstall') ?? false;
    if (allowed) {
      await install();
    } else {
      // Back without allowing it: the next "עדכן" asks again (the file stays, no new download).
      _waitingForPermission = false;
      error = 'ההתקנה לא אושרה. לחץ "עדכן" כדי לנסות שוב — הקובץ כבר ירד.';
      notifyListeners();
    }
  }

  /// The system installer's answer (Android, PackageInstaller): only failures matter — on success the app restarts.
  Future<dynamic> _onPlatformCall(MethodCall call) async {
    if (call.method != 'installResult') return null;
    final args = (call.arguments as Map).cast<String, dynamic>();
    final status = args['status'] as String? ?? 'failure';
    if (status == 'success') return null;
    phase = UpdatePhase.failed;
    error = installError(status);
    notifyListeners();
    return null;
  }

  /// What went wrong, in Hebrew, by the installer's status.
  static String installError(String status) => switch (status) {
        'aborted' => 'ההתקנה בוטלה. אפשר ללחוץ "עדכן" שוב — הקובץ כבר ירד.',
        'conflict' || 'invalid' =>
          'ההתקנה לא הושלמה — ייתכן שהגרסה המותקנת נחתמה אחרת. הסר את האפליקציה והתקן מהאתר (הנתונים בשרת לא נמחקים).',
        'incompatible' => 'הגרסה הזו לא מתאימה למכשיר.',
        'storage' => 'אין מספיק מקום במכשיר להתקנה.',
        'blocked' => 'ההתקנה נחסמה במכשיר. נסה להתקין מהאתר.',
        _ => 'ההתקנה לא הושלמה. נסה שוב, או התקן מהאתר.',
      };

  /// Where a downloaded update waits until it's installed: one file per build, in the app's cache.
  static Future<File> _updateFile(int build) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
    await dir.create(recursive: true);
    // Older downloads aren't needed any more (this build's file and its partial download stay).
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.uri.pathSegments.last.startsWith('maskoret-$build.')) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
    return File('${dir.path}/maskoret-$build.${Platform.isWindows ? 'exe' : 'apk'}');
  }

  /// The file is exactly the published one.
  static Future<bool> _matches(File file, String? sha256) async {
    if (sha256 == null) return true;
    final digest = await Sha256().hash(await file.readAsBytes());
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join() == sha256;
  }

  /// Checks for a newer version (quietly; at launch, every 3 hours, on return to the app, and from the updates screen).
  Future<void> check({bool force = false}) async {
    // An install waiting for the permission goes on when the user is back (resumed), not through a new check.
    if (!supported || busy || _waitingForPermission) return;
    if (!force && lastCheck != null && DateTime.now().difference(lastCheck!) < const Duration(minutes: 10)) return;
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

  /// Downloads the new version (unless it already did) and installs it.
  Future<void> install() async {
    final target = latest?.forThisDevice;
    final build = latest?.build;
    if (target == null || build == null || busy) return;
    _waitingForPermission = false;
    _resumeDownload = false;
    phase = UpdatePhase.downloading;
    progress = 0;
    error = null;
    notifyListeners();
    try {
      final file = await _updateFile(build);
      // Downloaded before (e.g. before the user allowed installs from this app): used as is, if it's intact.
      final downloaded = await file.exists();
      if (downloaded) _verifying();
      if (!(downloaded && await _matches(file, target.sha256))) {
        phase = UpdatePhase.downloading;
        notifyListeners();
        await _download(target.url, file);
        _verifying();
        if (!await _matches(file, target.sha256)) {
          try {
            await file.delete();
          } catch (_) {}
          throw const _Corrupt();
        }
      }
      progress = 1;
      phase = UpdatePhase.installing;
      notifyListeners();
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod<String>('installApk', {'path': file.path});
        phase = UpdatePhase.idle;
        // "permission": the user was sent to allow installs from this app — back in the app it goes on by itself.
        if (result == 'permission') {
          _waitingForPermission = true;
          error = 'אשר "התקנה מהאפליקציה הזו" במסך שנפתח וחזור לאפליקציה — ההתקנה תמשיך לבד.';
        }
      } else {
        await _installWindows(file);
      }
    } catch (e) {
      phase = UpdatePhase.failed;
      // A broken connection (e.g. the app went to the background): continue on return, keeping what arrived.
      if (e is IOException || e is TimeoutException) _resumeDownload = true;
      error = e is _Corrupt
          ? 'הקובץ שהורד פגום. נסה שוב.'
          : (e is PlatformException && e.code == 'install' ? installError('failure') : 'העדכון נכשל. נסה שוב בעוד רגע.');
    }
    notifyListeners();
  }

  /// Downloads into `<file>.part` and renames it when complete. A part left by an interrupted download (the
  /// connection broke, the app was closed) is continued with an HTTP Range request instead of starting over.
  Future<void> _download(String url, File file) async {
    final part = File('${file.path}.part');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      var have = await part.exists() ? await part.length() : 0;
      final request = await client.getUrl(Uri.parse(url));
      if (have > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      final response = await request.close();
      if (response.statusCode == 416) {
        // The part is already complete (or doesn't fit the file any more): check it as is.
        await response.drain<void>();
        await part.rename(file.path);
        return;
      }
      if (response.statusCode == 200) {
        have = 0; // The server sent the whole file.
      } else if (response.statusCode != 206) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final total = response.contentLength > 0 ? have + response.contentLength : 0;
      var received = have;
      final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
      try {
        // A connection that stalls (e.g. cut off while the app was in the background) fails instead of hanging.
        await for (final chunk in response.timeout(const Duration(seconds: 30))) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            progress = received / total;
            notifyListeners();
          }
        }
      } finally {
        await sink.close();
      }
      await part.rename(file.path);
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
