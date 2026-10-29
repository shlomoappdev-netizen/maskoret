import 'dart:convert';
import 'dart:io';

/// A short technical log of what the app did (sync, errors), kept in a file so it survives a crash.
/// It's sent only when the user attaches it to a support message, and never contains financial data.
/// Port of `AppLog` in Support.swift. Kept outside the encrypted data folder, so signing out doesn't erase it.
class AppLog {
  static const _maxBytes = 250000;
  static File? _file;

  static Future<void> init(Directory folder) async {
    folder.createSync(recursive: true);
    _file = File('${folder.path}/maskoret-log.txt');
  }

  static void add(String category, String message) {
    final f = _file;
    if (f == null) return;
    final stamp = DateTime.now().toIso8601String().split('.').first;
    try {
      f.writeAsStringSync('$stamp [$category] ${message.replaceAll('\n', ' ')}\n', mode: FileMode.append, flush: false);
    } catch (_) {}
  }

  /// The newest part of the log (trims the file when it grew too big).
  static String recent() {
    final f = _file;
    if (f == null || !f.existsSync()) return '';
    try {
      final data = f.readAsBytesSync();
      final tail = data.length > _maxBytes ? data.sublist(data.length - _maxBytes) : data;
      if (data.length > _maxBytes * 2) f.writeAsBytesSync(tail);
      return utf8.decode(tail, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }
}
